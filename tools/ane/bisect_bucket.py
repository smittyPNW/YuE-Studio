"""Find which bucket dimension breaks ANE evaluation: build layer 0 at several (S, P), run with zeros."""
import json, sys, tempfile, time, numpy as np, torch
from yue2 import YuE2Pipeline
from yue2.ane import runtime
from yue2.ane.mil import build_layer_program, layer_arrays
pipe = YuE2Pipeline.from_pretrained("m-a-p/YuE2-3B", device="mps", progress=False)
model = pipe._load_model(for_nar=True); cfg = model.config
W = layer_arrays(model.model.layers[0], cfg)
for S, P in [(2048, 2048), (2048, 8192), (6144, 2048), (4096, 4096), (6144, 8192)]:
    d = tempfile.mkdtemp()
    t0 = time.perf_counter()
    meta = build_layer_program(W, d, S=S, P=P, D=cfg.hidden_size, H=cfg.num_attention_heads, KV=cfg.num_key_value_heads, HD=cfg.head_dim, eps=cfg.rms_norm_eps)
    gen = time.perf_counter() - t0
    try:
        prog = runtime.Program(d)
    except Exception as e:
        print(json.dumps({"S": S, "P": P, "ops": meta["mil_ops"], "compile": "FAILED", "error": str(e)[:160]}), flush=True); continue
    K = S + P; D, KV, HD = cfg.hidden_size, cfg.num_key_value_heads, cfg.head_dim
    surf = {"x": runtime.Surface(S * D * 2), "pk": runtime.Surface(KV * P * HD * 2), "pv": runtime.Surface(KV * P * HD * 2),
            "cos": runtime.Surface(S * HD), "sin": runtime.Surface(S * HD), "bias": runtime.Surface(K * 2)}
    out = runtime.Surface(S * D * 2)
    surf["x"].write(np.random.default_rng(0).standard_normal((1, 1, S, D)).astype(np.float16) * 0.5)
    for k in ("pk", "pv"): surf[k].write(np.zeros((1, KV, P, HD), dtype=np.float16))
    surf["cos"].write(np.ones((1, 1, S, HD // 2), dtype=np.float16)); surf["sin"].write(np.zeros((1, 1, S, HD // 2), dtype=np.float16))
    surf["bias"].write(np.zeros((1, 1, 1, K), dtype=np.float16))
    try:
        t0 = time.perf_counter(); prog(surf, [out]); ms = 1000 * (time.perf_counter() - t0)
        o = out.read((S, D)).astype(np.float32)
        print(json.dumps({"S": S, "P": P, "ops": meta["mil_ops"], "gen_s": round(gen), "compile_s": round(prog.compile_seconds, 1), "eval_ms": round(ms), "finite": bool(np.isfinite(o).all()), "out_max": round(float(np.abs(o).max()), 2)}), flush=True)
    except Exception as e:
        print(json.dumps({"S": S, "P": P, "ops": meta["mil_ops"], "compile_s": round(prog.compile_seconds, 1), "eval": "FAILED", "error": str(e)[-120:]}), flush=True)
    prog.free(); [s.free() for s in surf.values()]; out.free()
