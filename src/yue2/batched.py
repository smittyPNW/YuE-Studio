"""Batched eager decoding for the torch backend.

Several independent requests share every weight read per step, which is the
lever on bandwidth-bound devices (Apple MPS, or CUDA without vLLM). Prefixes are
left-padded; padded rows attend only to themselves during prefill so no NaNs
reach the KV cache. Sampling and RNG are per row, so seeded outputs are
independent of batch composition apart from bf16 accumulation-order noise.

Two MPS-specific patches are applied during the decode loop (no-ops elsewhere):
``flat_linears`` reshapes [B, 1, H] inputs to 2D so nn.Linear does not stream
the weight once per row, and a grouped single-query attention path replaces
the per-row ``repeat_interleave`` copies and the slow masked SDPA kernel.
"""
from __future__ import annotations
import time
import types
import torch
import torch.nn.functional as F
from .modeling_yue2 import StaticKVCache
from .protocol import EOD, ABC_END, MUSIC_END, CODEC_OFFSET, CODEC_SIZE, CONTEXT
from .sampling import synchronize

STEP = int(__import__('os').environ.get('YUE2_KV_STEP', 256))   # attended-length granularity (see BucketedKVCache); 1 = exact


class BucketedKVCache(StaticKVCache):
    """StaticKVCache whose views are rounded up to a multiple of ``STEP`` slots.

    On MPS every distinct attended length is a distinct kernel shape, and each
    compiled graph stays cached for the life of the process (about 2 MB per
    step, i.e. gigabytes over a long song). Rounding bounds the shape count to
    max_seq_len / STEP. Slack slots hold zeros and are masked out, so the
    result is unchanged apart from bf16 accumulation order.
    """
    pending = 1     # tokens the next forward appends (set before a prefill)

    def width(self, end):
        return min(self.max_seq_len, -(-end // STEP) * STEP)

    def get_max_cache_shape(self):
        # The model sizes its causal mask on this; slots past the current token stay invisible.
        return self.width(self._seen_tokens + self.pending)

    def update(self, key_states, value_states, layer_idx, cache_kwargs=None):
        k, _ = super().update(key_states, value_states, layer_idx, cache_kwargs)
        width = self.width(k.shape[2])
        return self.key_cache[layer_idx][:, :, :width], self.value_cache[layer_idx][:, :, :width]


# ── MPS patches ─────────────────────────────────────────────────────────────

class flat_linears:
    """Route every nn.Linear in ``model`` through a 2D matmul (pure reshape)."""

    def __init__(self, model):
        self.model, self.patched = model, []

    def __enter__(self):
        def forward(module, x):
            shape = x.shape
            out = F.linear(x.reshape(-1, shape[-1]), module.weight, module.bias)
            return out.reshape(*shape[:-1], out.shape[-1])
        for module in self.model.modules():
            if isinstance(module, torch.nn.Linear) and "forward" not in module.__dict__:
                module.forward = types.MethodType(forward, module)
                self.patched.append(module)
        return self

    def __exit__(self, *exc):
        for module in self.patched:
            del module.__dict__["forward"]
        self.patched = []


def _grouped_decode_attention(query, key, value, attn_mask=None, scale=None):
    """Single-query grouped attention as broadcast matmuls; no K/V head copies.

    query [B, H, 1, D]; key/value [B, Hkv, L, D]; attn_mask broadcastable to
    [B, 1, 1, L] (bool: True = keep) or additive float.
    """
    b, heads, _, dim = query.shape
    kv_heads = key.shape[1]
    q = query.reshape(b, kv_heads, heads // kv_heads, dim)
    scores = torch.matmul(q, key.transpose(-1, -2)).float() * (scale or dim ** -0.5)
    if attn_mask is not None:
        scores = scores.masked_fill(~attn_mask, float("-inf")) if attn_mask.dtype == torch.bool else scores + attn_mask.float()
    weights = scores.softmax(-1).to(value.dtype)
    return torch.matmul(weights, value).reshape(b, heads, 1, dim)


class mps_decode_patches:
    """Make batched single-token decoding scale on MPS; no-op on other devices."""

    def __init__(self, model):
        self.model = model
        self.device = next(model.parameters()).device
        self.linears = flat_linears(model)
        self.original = None

    def __enter__(self):
        if self.device.type != "mps":
            return self
        from . import modeling_yue2
        self.linears.__enter__()
        self.original = modeling_yue2.sdpa

        def sdpa(query, key, value, *, attn_mask=None, is_causal=False):
            if query.shape[2] == 1 and not is_causal and query.device.type == "mps":
                return _grouped_decode_attention(query, key, value, attn_mask)
            return self.original(query, key, value, attn_mask=attn_mask, is_causal=is_causal)
        modeling_yue2.sdpa = sdpa
        return self

    def __exit__(self, *exc):
        if self.original is not None:
            from . import modeling_yue2
            modeling_yue2.sdpa, self.original = self.original, None
            self.linears.__exit__(*exc)


class sliced_lm_head:
    """Compute only the vocabulary rows a phase can sample; exactly lossless.

    The sampler masks everything outside the phase's range to -inf anyway, so
    the output head (184,704 x 2,048, ~756 MB in bf16, read every step) can be
    sliced to a contiguous view: the 32,769 codec rows plus MUSIC_END for the
    song phase, or the text rows up to ABC_END for the score phase. Logits are
    returned at full width with -inf elsewhere, so downstream code is unchanged.
    """

    def __init__(self, model, phase):
        self.head = model.lm_head
        if phase == "abc":
            self.lo, self.hi = 0, ABC_END + 1
        else:
            self.lo, self.hi = MUSIC_END, CODEC_OFFSET + CODEC_SIZE
        assert MUSIC_END + 1 == CODEC_OFFSET, "song-phase rows must be contiguous"

    def __enter__(self):
        head, lo, hi = self.head, self.lo, self.hi
        if "forward" in head.__dict__ or head.bias is not None:
            return self
        vocab = head.weight.shape[0]
        weight = head.weight[lo:hi]

        def forward(module, x):
            shape = x.shape
            out = F.linear(x.reshape(-1, shape[-1]), weight)
            full = torch.full((out.shape[0], vocab), float("-inf"), dtype=out.dtype, device=out.device)
            full[:, lo:hi] = out
            return full.reshape(*shape[:-1], vocab)
        head.forward = types.MethodType(forward, head)
        self.patched = True
        return self

    def __exit__(self, *exc):
        if getattr(self, "patched", False):
            del self.head.__dict__["forward"]
            self.patched = False


# ── Batched sampling ────────────────────────────────────────────────────────

def sample_batched(logits, sampling, histories, step, phase, generators, legacy_off=False):
    """Per-row sampling in one pass over [n, V]. Returns a list of token ids.

    Mirrors ``sampling.distribution`` (vocabulary gate, min_tokens, window
    penalty, temperature, top-k, top-p) but samples from the surviving top-k
    candidates on the CPU, so only [n, top_k] leaves the device.
    """
    n = logits.shape[0]
    scores = logits.clone() if legacy_off else logits.float()
    end = ABC_END if phase == "abc" else MUSIC_END
    gate = torch.full_like(scores[:1], float("-inf"))
    if phase == "abc":
        gate[..., :EOD] = 0
    else:
        gate[..., CODEC_OFFSET:CODEC_OFFSET + CODEC_SIZE] = 0
    gate[..., end] = 0
    scores = scores + gate
    if step < sampling.min_tokens:
        scores[:, end] = -torch.inf
    if sampling.repetition_penalty != 1.0:
        freq = torch.zeros_like(scores)
        for i, history in enumerate(histories):
            recent = history[-sampling.penalty_window:]
            if recent:
                index = torch.as_tensor(recent, dtype=torch.long, device=scores.device)
                freq[i].scatter_add_(-1, index, torch.ones_like(index, dtype=scores.dtype))
        alpha = sampling.repetition_penalty ** freq
        scores = torch.where(scores < 0, scores * alpha, scores / alpha)
    if sampling.temperature == 0:
        return scores.argmax(-1).tolist()
    if sampling.temperature != 1:
        scores = scores / sampling.temperature
    values, indices = scores.topk(min(sampling.top_k, scores.shape[-1]))  # sorted descending
    if sampling.top_p < 1:
        probabilities = values.softmax(-1)
        removed = probabilities.cumsum(-1) - probabilities > sampling.top_p
        removed[..., :3 if legacy_off else 1] = False
        values = values.masked_fill(removed, -torch.inf)
    probabilities, indices = values.softmax(-1).cpu(), indices.cpu()
    return [int(indices[i, torch.multinomial(probabilities[i], 1, generator=generators[i])]) for i in range(n)]


# ── Batched decode ──────────────────────────────────────────────────────────

@torch.inference_mode()
def generate_tokens_batched(model, prefixes, sampling, seeds, phase, *, legacy_off=False,
                            cancelled=None, on_token=None, pad_id=0, lock=None, on_row_done=None):
    """Decode ``len(prefixes)`` sequences in one batch.

    Returns ``(rows, batch_timing)``; ``rows[i] = (tokens, timing, truncated)``
    mirrors ``sampling.generate_tokens`` for request ``i``. ``on_token`` is
    called as ``on_token(row, phase, token)``. ``lock`` (a context manager,
    e.g. ``locks.FairLock``) is held for the prefill and for each decode step so
    other threads can use the same PyTorch device between steps. ``on_row_done``
    is called as ``on_row_done(row, tokens, timing)`` the moment a row emits its
    end token, while the batch continues for the other rows, so a finished
    sequence can move on without waiting for the longest one.
    """
    n = len(prefixes)
    if n < 1 or len(seeds) != n:
        raise ValueError("Provide at least one prefix and one seed per prefix")
    device = next(model.parameters()).device
    if device.type == "cpu" and (torch.cuda.is_available() or torch.backends.mps.is_available()):
        raise RuntimeError("Model is on the CPU (a previous decode parked it there); call pipe._load_model() first")
    dtype = next(model.parameters()).dtype
    config = model.config
    lengths = [len(p) for p in prefixes]
    longest = max(lengths)
    if longest + sampling.max_tokens > CONTEXT:
        raise ValueError("Longest prefix + generation budget exceeds 24576")
    end = ABC_END if phase == "abc" else MUSIC_END

    ids = torch.full((n, longest), pad_id, dtype=torch.long)
    real = torch.zeros((n, longest), dtype=torch.bool)
    for i, prefix in enumerate(prefixes):
        ids[i, longest - len(prefix):] = torch.tensor([int(t) for t in prefix], dtype=torch.long)
        real[i, longest - len(prefix):] = True
    ids, real = ids.to(device), real.to(device)
    positions = (real.long().cumsum(-1) - 1).clamp_(min=0)
    allowed = torch.ones(longest, longest, dtype=torch.bool, device=device).tril_()[None, None] & real[:, None, None, :]
    diagonal = torch.arange(longest, device=device)
    allowed[:, 0, diagonal, diagonal] = True  # padded queries see themselves: finite K/V
    cache = BucketedKVCache(num_layers=config.num_hidden_layers, batch_size=n,
                            num_kv_heads=config.num_key_value_heads,
                            max_seq_len=longest + sampling.max_tokens,
                            head_dim=config.head_dim, dtype=dtype, device=device)
    cache.pending = longest
    allowed = F.pad(allowed, (0, cache.width(longest) - longest), value=False)   # rounded key width, slack hidden

    with sliced_lm_head(model, phase):
        return _run(model, cache, ids, allowed, positions, real, prefixes, lengths, sampling, seeds,
                    phase, end, legacy_off, cancelled, on_token, device, lock, on_row_done)


def _run(model, cache, ids, allowed, positions, real, prefixes, lengths, sampling, seeds,
         phase, end, legacy_off, cancelled, on_token, device, lock=None, on_row_done=None):
    from contextlib import nullcontext
    lock = nullcontext() if lock is None else lock
    n = len(prefixes)
    longest = max(lengths)
    generators = [torch.Generator(device="cpu").manual_seed(int(s)) for s in seeds]
    with lock:
        synchronize(device)
        start = time.perf_counter()
        logits = model(ids, attention_mask=allowed, position_ids=positions, past_key_values=cache,
                       use_cache=True, logits_to_keep=1).logits[:, -1, :]
        synchronize(device)
    prefill_seconds = time.perf_counter() - start
    cache.pending = 1

    histories = [[] for _ in range(n)]
    done, eos, first = [False] * n, [False] * n, [None] * n
    # Padding mask over the whole cache; slots past the current token stay False so the
    # rounded-width slice below needs no per-step padding (which would be a new kernel shape each step).
    mask = torch.zeros((n, cache.max_seq_len), dtype=torch.bool, device=device)
    mask[:, :longest] = real
    lengths_t = torch.tensor(lengths, dtype=torch.long, device=device)
    step_seconds, steps = [], 0
    with mps_decode_patches(model):
        for step in range(sampling.max_tokens):
            if cancelled is not None and cancelled():
                raise InterruptedError(f"Cancelled during batched {phase}")
            with lock:
                tokens = sample_batched(logits, sampling, histories, step, phase, generators, legacy_off)
            for i, token in enumerate(tokens):
                if done[i]:
                    tokens[i] = end
                    continue
                if first[i] is None:
                    first[i] = time.perf_counter() - start
                if on_token is not None:
                    on_token(i, phase, token)
                if token == end:
                    eos[i] = done[i] = True
                    if on_row_done is not None:
                        elapsed = time.perf_counter() - start
                        on_row_done(i, list(histories[i]), {
                            "seconds": elapsed, "prefill_seconds": prefill_seconds, "ttft_seconds": first[i],
                            "output_tokens": len(histories[i]) + 1, "content_tokens": len(histories[i]),
                            "output_tps": (len(histories[i]) + 1) / elapsed, "prefix_tokens": lengths[i], "cfg_branches": 1,
                            "execution": "eager_batched", "batch_size": n, "batch_index": i})
                else:
                    histories[i].append(token)
            steps = step + 1
            if all(done) or step + 1 >= sampling.max_tokens:
                break
            with lock:
                next_ids = torch.tensor(tokens, dtype=torch.long, device=device)[:, None]
                tick = time.perf_counter()
                mask[:, longest + step] = True
                logits = model(next_ids, attention_mask=mask[:, :cache.width(longest + step + 1)],
                               position_ids=(lengths_t + step)[:, None], past_key_values=cache,
                               use_cache=True, logits_to_keep=1).logits[:, -1, :]
                synchronize(device)
                step_seconds.append(time.perf_counter() - tick)
    with lock:
        synchronize(device)
    seconds = time.perf_counter() - start
    rows = []
    for i in range(n):
        count = len(histories[i]) + int(eos[i])
        rows.append((histories[i], {
            "seconds": seconds, "prefill_seconds": prefill_seconds, "ttft_seconds": first[i],
            "output_tokens": count, "content_tokens": len(histories[i]),
            "output_tps": count / seconds, "prefix_tokens": lengths[i], "cfg_branches": 1,
            "execution": "eager_batched", "batch_size": n, "batch_index": i,
        }, not eos[i]))
    total = sum(len(h) + int(e) for h, e in zip(histories, eos))
    batch = {"batch_size": n, "steps": steps, "seconds": seconds, "prefill_seconds": prefill_seconds,
             "mean_step_seconds": sum(step_seconds) / len(step_seconds) if step_seconds else None,
             "total_output_tokens": total, "aggregate_tps": total / seconds}
    return rows, batch
