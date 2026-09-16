"""MLX acoustic flow matching (NAR) for Apple Silicon.

The AR prefix prefill stays in PyTorch (``CachedNAR``); its per-layer K/V cache
and the NAR-path weights are converted to MLX once, and the 2 x steps velocity
evaluations of the midpoint solver run in MLX with the fused, non-materializing
``mx.fast.scaled_dot_product_attention``. Numerics follow the PyTorch path
(bf16 activations, fp32 RMSNorm statistics, bf16 rotary tables).
"""
from __future__ import annotations
import math
import time
import numpy as np
import torch

try:
    import mlx.core as mx
except ImportError:  # pragma: no cover
    mx = None


def available():
    return mx is not None and torch.backends.mps.is_available()


def _to_mx(t):
    t = t.detach()
    if t.dtype == torch.bfloat16:
        return mx.view(mx.array(t.contiguous().view(torch.int16).cpu().numpy()), mx.bfloat16)
    return mx.array(t.float().cpu().numpy())


class MLXWeights:
    """NAR-path weights of a YuE2ForCausalLM as MLX arrays (converted once)."""

    def __init__(self, model):
        cfg = model.config
        self.eps, self.theta, self.shift = cfg.rms_norm_eps, cfg.rope_theta, cfg.timestep_shift
        self.H, self.KV, self.HD, self.D = cfg.num_attention_heads, cfg.num_key_value_heads, cfg.head_dim, cfg.hidden_size
        self.max_frames = cfg.max_latent_frames
        self.dtype = mx.bfloat16 if next(model.parameters()).dtype == torch.bfloat16 else mx.float32
        self.vae2llm = (_to_mx(model.vae2llm.weight), _to_mx(model.vae2llm.bias))
        self.llm2vae = (_to_mx(model.llm2vae.weight), _to_mx(model.llm2vae.bias))
        mlp = model.time_embedder.mlp
        self.time = (_to_mx(mlp[0].weight), _to_mx(mlp[0].bias), _to_mx(mlp[2].weight), _to_mx(mlp[2].bias))
        self.freq_size = model.time_embedder.frequency_embedding_size
        self.pe = _to_mx(model.latent_pos_embed.pe)
        self.final_norm = _to_mx(model.model.norm.weight)
        from .lean import nar_layer_state
        self.layers = []
        for i in range(len(model.model.layers)):
            # From the module when loaded, else read from the checkpoint (lean model).
            layer = {name: _to_mx(t) for name, t in nar_layer_state(model, i).items()}
            mx.eval(*layer.values())
            self.layers.append(layer)
        mx.eval(self.pe, self.final_norm)

    def bytes(self):
        return sum(w.nbytes for l in self.layers for w in l.values()) + self.pe.nbytes


def _linear(x, w, b=None):
    y = mx.matmul(x, w.T)
    return y if b is None else y + b


def _rms(x, w, eps):
    return mx.fast.rms_norm(x, w, eps)


class MLXVelocity:
    """MLX counterpart of ``CachedNAR.velocity``/``solve`` for one chunk."""

    def __init__(self, engine, weights: MLXWeights):
        self.w = weights
        self.ar_length, self.nar_length = engine.ar_length, engine.nar_length
        w = weights
        # Prefix K/V per layer: [L0, KV, HD] -> [1, KV, L0, HD]
        self.cache = [(mx.transpose(_to_mx(k), (1, 0, 2))[None], mx.transpose(_to_mx(v), (1, 0, 2))[None]) for k, v in engine.cache]
        positions = np.arange(self.ar_length, self.ar_length + self.nar_length, dtype=np.float32)
        inv_freq = 1.0 / (w.theta ** (np.arange(0, w.HD, 2, dtype=np.float32) / w.HD))
        angles = positions[:, None] * inv_freq[None]
        self.cos = mx.array(np.cos(angles)).astype(w.dtype)[:, None, :]   # [T, 1, HD/2], bf16 like torch
        self.sin = mx.array(np.sin(angles)).astype(w.dtype)[:, None, :]
        local = np.minimum(np.arange(self.nar_length), w.max_frames - 1)
        self.pos_emb = w.pe[mx.array(local)]
        mx.eval(self.cos, self.sin, self.pos_emb, *[t for kv in self.cache for t in kv])

    def _rotary(self, x):
        half = x.shape[-1] // 2
        x1, x2 = x[..., :half], x[..., half:]
        return mx.concatenate([x1 * self.cos - x2 * self.sin, x2 * self.cos + x1 * self.sin], axis=-1)

    def _time_embedding(self, raw_t):
        w = self.w
        sig = 1.0 / (1.0 + math.exp(-raw_t))
        shifted = w.shift * sig / (1 + (w.shift - 1) * sig)
        t = mx.array(shifted, dtype=w.dtype).astype(mx.float32)          # torch rounds t to model dtype first
        half = w.freq_size // 2
        freqs = mx.exp(-math.log(10000) * mx.arange(half, dtype=mx.float32) / half)
        args = t * freqs
        emb = mx.concatenate([mx.cos(args), mx.sin(args)]).astype(w.dtype)[None]
        h = _linear(emb, w.time[0], w.time[1])
        h = h * mx.sigmoid(h)
        return _linear(h, w.time[2], w.time[3])                           # [1, D]

    def velocity(self, state, raw_t):
        w = self.w
        T = self.nar_length
        x_nar = mx.pad(state, ((1, 1), (0, 0)))
        x = _linear(x_nar, w.vae2llm[0], w.vae2llm[1]) + self._time_embedding(raw_t) + self.pos_emb
        scale = w.HD ** -0.5
        for layer, (ar_k, ar_v) in zip(w.layers, self.cache):
            h = _rms(x, layer["in_norm"], w.eps)
            q = _rms(_linear(h, layer["q"]).reshape(T, w.H, w.HD), layer["q_norm"], w.eps)
            k = _rms(_linear(h, layer["k"]).reshape(T, w.KV, w.HD), layer["k_norm"], w.eps)
            v = _linear(h, layer["v"]).reshape(T, w.KV, w.HD)
            q, k = self._rotary(q), self._rotary(k)
            qh = mx.transpose(q, (1, 0, 2))[None]                          # [1, H, T, HD]
            kh = mx.concatenate([ar_k, mx.transpose(k, (1, 0, 2))[None]], axis=2)
            vh = mx.concatenate([ar_v, mx.transpose(v, (1, 0, 2))[None]], axis=2)
            a = mx.fast.scaled_dot_product_attention(qh, kh, vh, scale=scale)
            x = x + _linear(mx.transpose(a[0], (1, 0, 2)).reshape(T, w.H * w.HD), layer["o"])
            m = _rms(x, layer["mlp_norm"], w.eps)
            g = _linear(m, layer["gate"])
            x = x + _linear(g * mx.sigmoid(g) * _linear(m, layer["up"]), layer["down"])
        out = _linear(_rms(x, w.final_norm, w.eps), w.llm2vae[0], w.llm2vae[1])
        return out[1:-1]

    def solve(self, noise, steps=32, cancelled=None, on_progress=None):
        state = _to_mx(noise.to(self.w.dtype if self.w.dtype == mx.float32 else torch.bfloat16))
        dt = 1.0 / steps
        for step in range(steps):
            if cancelled is not None and cancelled():
                raise InterruptedError("Cancelled during acoustic flow matching")
            t = 1.0 - step * dt
            raw = float(torch.logit(torch.tensor(t, dtype=torch.float64)).clamp(-20, 20))
            first = self.velocity(state, raw)
            mid = state - first * (dt / 2)
            raw_mid = float(torch.logit(torch.tensor(t - dt / 2, dtype=torch.float64)).clamp(-20, 20))
            state = state - self.velocity(mid, raw_mid) * dt
            mx.eval(state)
            if on_progress is not None:
                on_progress(step + 1, int(steps))
        result = torch.from_numpy(np.array(state.astype(mx.float32)))
        if not torch.isfinite(result).all():
            raise FloatingPointError("Acoustic flow matching produced non-finite latents")
        return result


def weights_for(model):
    cached = getattr(model, "_yue2_mlx_weights", None)
    if cached is None:
        cached = MLXWeights(model)
        model._yue2_mlx_weights = cached
    return cached
