"""Reproduce the long-bucket failure with real data; report the failing layer and input sanity."""
import json, os, sys, time, numpy as np, torch
from yue2 import YuE2Pipeline
from yue2.nar import CachedNAR, song_chunks
from yue2.ane import runtime
from yue2.pipeline import SymbolicPlan
d = "outputs/midnight-line/midnight_line_1"
pipe = YuE2Pipeline.from_pretrained("m-a-p/YuE2-3B", device="mps", progress=False)
model = pipe._load_model(for_nar=True)
plan = SymbolicPlan.load(d); tokens = np.load(f"{d}/semantic.npy").tolist()
chunk = song_chunks(plan.prefix, tokens, plan.request.seed)[0]
engine = CachedNAR(model, chunk)
k0, v0 = engine.cache[0]
print(json.dumps({"layers": runtime.LAYER_LIMIT or 28, "prefix_k_finite": bool(torch.isfinite(k0).all()), "prefix_k_max": round(float(k0.float().abs().max()), 2),
                  "prefix_v_max": round(float(v0.float().abs().max()), 2), "noise_max": round(float(chunk.noise.abs().max()), 2)}), flush=True)
if os.environ.get("DIAG_OFFLOAD"):
    model.to("cpu"); torch.mps.empty_cache()
    print(json.dumps({"torch_model_offloaded_to_cpu": True}), flush=True)
t0 = time.perf_counter()
solver = runtime.ANEVelocity(engine, model)
print(json.dumps({"prepare_s": round(time.perf_counter() - t0), "S": solver.S, "P": solver.P, "K": solver.K}), flush=True)
try:
    v = solver.velocity(chunk.noise.float(), -20.0)
    print(json.dumps({"velocity_ok": True, "finite": bool(torch.isfinite(v).all()), "max": round(float(v.abs().max()), 3), "layers_ms": round(1000 * solver.layer_seconds[-1])}), flush=True)
except Exception as e:
    x_in = solver.x[solver.current_layer % 2].read((solver.S, solver.D)).astype(np.float32)
    print(json.dumps({"velocity_ok": False, "failed_layer": solver.current_layer, "x_in_finite": bool(np.isfinite(x_in).all()), "x_in_max": round(float(np.abs(x_in).max()), 2), "error": str(e)[-90:]}), flush=True)
solver.close()
