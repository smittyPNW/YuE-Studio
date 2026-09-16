"""Does evaluation fail after a cumulative volume of distinct IOSurfaces has been mapped for the ANE?"""
import glob, json, numpy as np, subprocess
from yue2.ane import runtime
d = sorted(glob.glob(str(runtime.CACHE / "*" / "S6144_P8192" / "layer00")))[0]
meta = json.load(open(d + "/meta.json")); S, P, K, D, KV, HD = meta["S"], meta["P"], meta["K"], meta["D"], meta["KV"], meta["HD"]
prog = runtime.Program(d)
fixed = {"x": runtime.Surface(S * D * 2), "cos": runtime.Surface(S * HD), "sin": runtime.Surface(S * HD), "bias": runtime.Surface(K * 2)}
out = runtime.Surface(S * D * 2)
fixed["x"].write(np.zeros((1, 1, S, D), dtype=np.float16)); fixed["cos"].write(np.ones((1, 1, S, HD // 2), dtype=np.float16))
fixed["sin"].write(np.zeros((1, 1, S, HD // 2), dtype=np.float16)); fixed["bias"].write(np.zeros((1, 1, 1, K), dtype=np.float16))
kv_bytes = KV * P * HD * 2
pool = []
total = 0
for i in range(60):
    pk, pv = runtime.Surface(kv_bytes), runtime.Surface(kv_bytes)
    pk.write(np.zeros((1, KV, P, HD), dtype=np.float16)); pv.write(np.zeros((1, KV, P, HD), dtype=np.float16))
    pool.append((pk, pv)); total += 2 * kv_bytes
    try:
        prog({**fixed, "pk": pk, "pv": pv}, [out])
        if i % 5 == 4: print(json.dumps({"distinct_kv_surfaces": 2 * (i + 1), "mapped_MB": total // 2**20, "ok": True}), flush=True)
    except Exception as e:
        print(json.dumps({"distinct_kv_surfaces": 2 * (i + 1), "mapped_MB": total // 2**20, "ok": False, "error": str(e)[-80:]}), flush=True)
        break
print(json.dumps({"done": True, "surfaces": 2 * len(pool), "mapped_MB": total // 2**20}), flush=True)
