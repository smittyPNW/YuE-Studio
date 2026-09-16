"""How many large-bucket layer programs can be resident before evaluation fails?"""
import glob, json, subprocess, time, numpy as np
from yue2.ane import runtime
dirs = sorted(glob.glob(str(runtime.CACHE / "*" / "S6144_P8192" / "layer*")))
meta = json.load(open(dirs[0] + "/meta.json")); S, P, K, D, KV, HD = meta["S"], meta["P"], meta["K"], meta["D"], meta["KV"], meta["HD"]
surf = {"x": runtime.Surface(S * D * 2), "pk": runtime.Surface(KV * P * HD * 2), "pv": runtime.Surface(KV * P * HD * 2),
        "cos": runtime.Surface(S * HD), "sin": runtime.Surface(S * HD), "bias": runtime.Surface(K * 2)}
out = runtime.Surface(S * D * 2)
surf["x"].write(np.random.default_rng(0).standard_normal((1, 1, S, D)).astype(np.float16) * 0.5)
for k in ("pk", "pv"): surf[k].write(np.zeros((1, KV, P, HD), dtype=np.float16))
surf["cos"].write(np.ones((1, 1, S, HD // 2), dtype=np.float16)); surf["sin"].write(np.zeros((1, 1, S, HD // 2), dtype=np.float16))
surf["bias"].write(np.zeros((1, 1, 1, K), dtype=np.float16))
def gpu_mem():
    o = subprocess.run("ioreg -r -d 1 -c IOAccelerator | grep -o '\"In use system memory\"=[0-9]*' | grep -o '[0-9]*$'", shell=True, capture_output=True, text=True).stdout.strip()
    return round(int(o or 0) / 2**30, 2)
programs = []
for i, d in enumerate(dirs):
    programs.append(runtime.Program(d))
    try:
        t0 = time.perf_counter(); programs[-1](surf, [out]); ms = 1000 * (time.perf_counter() - t0)
        t0 = time.perf_counter(); programs[0](surf, [out]); ms0 = 1000 * (time.perf_counter() - t0)
        print(json.dumps({"resident": i + 1, "eval_new_ms": round(ms), "eval_first_ms": round(ms0), "accel_mem_GB": gpu_mem()}), flush=True)
    except Exception as e:
        print(json.dumps({"resident": i + 1, "eval": "FAILED", "error": str(e)[-100:], "accel_mem_GB": gpu_mem()}), flush=True)
        break
for p in programs: p.free()
