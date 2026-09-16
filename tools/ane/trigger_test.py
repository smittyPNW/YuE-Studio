"""Run layer 18 alone on the ANE with real inputs captured from PyTorch; vary inputs to find the trigger."""
import json, tempfile, numpy as np, torch
from yue2 import YuE2Pipeline
from yue2.nar import CachedNAR, song_chunks
from yue2.ane import runtime
from yue2.ane.mil import build_layer_program, layer_arrays, NEG
from yue2.pipeline import SymbolicPlan
L = 18
d = "outputs/midnight-line/midnight_line_1"
pipe = YuE2Pipeline.from_pretrained("m-a-p/YuE2-3B", device="mps", progress=False)
model = pipe._load_model(for_nar=True); cfg = model.config
plan = SymbolicPlan.load(d); tokens = np.load(f"{d}/semantic.npy").tolist()
chunk = song_chunks(plan.prefix, tokens, plan.request.seed)[0]
engine = CachedNAR(model, chunk)
captured = {}
h = model.model.layers[L].nar_input_layernorm.register_forward_hook(lambda m, inp, out: captured.__setitem__("x", inp[0].detach()))
with torch.inference_mode():
    engine.velocity(chunk.noise.to(device=pipe.device, dtype=torch.bfloat16), -20.0)
x_real = captured["x"][0].float().cpu().numpy()                      # [S_real, D]
S_real, P_real = engine.nar_length, engine.ar_length
S, P = runtime.bucket(S_real, runtime.S_STEP), runtime.bucket(P_real, runtime.P_STEP); K = S + P
D, KV, HD = cfg.hidden_size, cfg.num_key_value_heads, cfg.head_dim
tmp = tempfile.mkdtemp()
meta = build_layer_program(layer_arrays(model.model.layers[L], cfg), tmp, S=S, P=P, D=D, H=cfg.num_attention_heads, KV=KV, HD=HD, eps=cfg.rms_norm_eps)
prog = runtime.Program(tmp)
print(json.dumps({"layer": L, "S": S, "P": P, "ops": meta["mil_ops"], "compile_s": round(prog.compile_seconds, 1)}), flush=True)
k, v = engine.cache[L]
def kv_arr(t, zero=False):
    a = np.zeros((1, KV, P, HD), dtype=np.float16)
    if not zero: a[0, :, :P_real] = t.float().cpu().numpy().transpose(1, 0, 2)
    return a
positions = np.arange(P_real, P_real + S, dtype=np.float32)
inv = 1.0 / (cfg.rope_theta ** (np.arange(0, HD, 2, dtype=np.float32) / HD)); ang = positions[:, None] * inv[None]
def bias_arr(masked=True):
    b = np.zeros((1, 1, 1, K), dtype=np.float16)
    if masked: b[..., P_real:P] = NEG; b[..., P + S_real:] = NEG
    return b
def x_arr(pad="zero"):
    a = np.zeros((S, D), dtype=np.float16); a[:S_real] = x_real.astype(np.float16)
    if pad == "random": a[S_real:] = (np.random.default_rng(0).standard_normal((S - S_real, D)) * 0.5).astype(np.float16)
    return a
surf = {n: runtime.Surface(b) for n, b in (("x", S * D * 2), ("pk", KV * P * HD * 2), ("pv", KV * P * HD * 2), ("cos", S * HD), ("sin", S * HD), ("bias", K * 2))}
out = runtime.Surface(S * D * 2)
surf["cos"].write(np.cos(ang).reshape(1, 1, S, HD // 2)); surf["sin"].write(np.sin(ang).reshape(1, 1, S, HD // 2))
variants = [("real", dict(x="zero", kv=False, mask=True)), ("bias_unmasked", dict(x="zero", kv=False, mask=False)),
            ("x_pad_random", dict(x="random", kv=False, mask=True)), ("kv_zero", dict(x="zero", kv=True, mask=True))]
for name, cfgv in variants:
    surf["x"].write(x_arr(cfgv["x"])); surf["pk"].write(kv_arr(k, cfgv["kv"])); surf["pv"].write(kv_arr(v, cfgv["kv"])); surf["bias"].write(bias_arr(cfgv["mask"]))
    try:
        prog(surf, [out]); o = out.read((S, D)).astype(np.float32)
        print(json.dumps({"variant": name, "ok": True, "finite": bool(np.isfinite(o).all()), "out_max": round(float(np.abs(o).max()), 1)}), flush=True)
    except Exception as e:
        print(json.dumps({"variant": name, "ok": False, "error": str(e)[-70:]}), flush=True)
