"""Time synthesis of a saved song with the torch and MLX engines; compare latents to the saved reference.
Usage: python tools/bench_nar_engines.py <song dir> [engines=torch,mlx] [steps=32]"""
import json, sys, time, numpy as np
from yue2 import YuE2Pipeline
from yue2.nar import synthesize
from yue2.pipeline import SymbolicPlan
d = sys.argv[1]; engines = (sys.argv[2] if len(sys.argv) > 2 else "torch,mlx").split(","); steps = int(sys.argv[3]) if len(sys.argv) > 3 else 32
pipe = YuE2Pipeline.from_pretrained("m-a-p/YuE2-3B", device="mps", progress=False)
model = pipe._load_model(for_nar=True)
plan = SymbolicPlan.load(d); tokens = np.load(f"{d}/semantic.npy").tolist(); ref = np.load(f"{d}/latent.npy")
print(json.dumps({"song": d, "frames": len(tokens), "prefix": len(plan.prefix), "steps": steps}), flush=True)
for engine in engines:
    t0 = time.perf_counter()
    lat = synthesize(model, plan.prefix, tokens, plan.request.seed, steps=steps, engine=engine).numpy()
    secs = time.perf_counter() - t0
    dd = np.abs(lat - ref)
    print(json.dumps({"engine": engine, "seconds": round(secs), "s_per_audio_s": round(secs / (len(tokens) / 25), 2),
                      "latent_rel_rms_vs_ref": round(float(np.sqrt((dd**2).mean()) / np.sqrt((ref**2).mean())), 4),
                      "corr": round(float(np.corrcoef(lat.ravel(), ref.ravel())[0, 1]), 5)}), flush=True)
