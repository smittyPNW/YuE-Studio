"""Same generated layer program through Core ML (public API): compile cache, placement, and per-call time."""
import json, shutil, tempfile, time, warnings, numpy as np, torch
warnings.filterwarnings("ignore")
import coremltools as ct
from coremltools.converters.mil import Builder as mb
from yue2 import YuE2Pipeline
from yue2.nar import CachedNAR, song_chunks
from yue2.ane import runtime
from yue2.ane import mil as milgen
from yue2.pipeline import SymbolicPlan
L = 18
d = "outputs/midnight-line/midnight_line_1"
pipe = YuE2Pipeline.from_pretrained("m-a-p/YuE2-3B", device="mps", progress=False)
model = pipe._load_model(for_nar=True); cfg = model.config
plan = SymbolicPlan.load(d); tokens = np.load(f"{d}/semantic.npy").tolist()
chunk = song_chunks(plan.prefix, tokens, plan.request.seed)[0]
engine = CachedNAR(model, chunk)
captured = {}
model.model.layers[L].nar_input_layernorm.register_forward_hook(lambda m, inp, out: captured.__setitem__("x", inp[0].detach()))
with torch.inference_mode():
    engine.velocity(chunk.noise.to(device=pipe.device, dtype=torch.bfloat16), -20.0)
S_real, P_real = engine.nar_length, engine.ar_length
S, P = runtime.bucket(S_real, runtime.S_STEP), runtime.bucket(P_real, runtime.P_STEP); K = S + P
D, KV, HD = cfg.hidden_size, cfg.num_key_value_heads, cfg.head_dim
# Build the mlpackage (monkeypatch the generator to keep the package instead of extracting MIL).
kept = {}
orig_compile = ct.models.utils.compile_model
def keep(pkg): kept["pkg"] = pkg; return orig_compile(pkg)
ct.models.utils.compile_model = keep
orig_rmtree = shutil.rmtree
shutil.rmtree = lambda p, **k: None if kept.get("pkg", "").startswith(str(p)) else orig_rmtree(p, **k)
out = tempfile.mkdtemp()
milgen.build_layer_program(milgen.layer_arrays(model.model.layers[L], cfg), out, S=S, P=P, D=D, H=cfg.num_attention_heads, KV=KV, HD=HD, eps=cfg.rms_norm_eps)
shutil.rmtree = orig_rmtree
pkg = kept["pkg"]
print(json.dumps({"mlpackage": pkg, "S": S, "P": P}), flush=True)
def inputs():
    x = np.zeros((1, 1, S, D), dtype=np.float16); x[0, 0, :S_real] = captured["x"][0].float().cpu().numpy().astype(np.float16)
    k, v = engine.cache[L]
    pk = np.zeros((1, KV, P, HD), dtype=np.float16); pk[0, :, :P_real] = k.float().cpu().numpy().transpose(1, 0, 2)
    pv = np.zeros((1, KV, P, HD), dtype=np.float16); pv[0, :, :P_real] = v.float().cpu().numpy().transpose(1, 0, 2)
    pos = np.arange(P_real, P_real + S, dtype=np.float32); inv = 1.0 / (cfg.rope_theta ** (np.arange(0, HD, 2, dtype=np.float32) / HD)); ang = pos[:, None] * inv[None]
    bias = np.zeros((1, 1, 1, K), dtype=np.float16); bias[..., P_real:P] = milgen.NEG; bias[..., P + S_real:] = milgen.NEG
    return {"x": x, "pk": pk, "pv": pv, "cos": np.cos(ang).reshape(1, 1, S, HD // 2).astype(np.float16), "sin": np.sin(ang).reshape(1, 1, S, HD // 2).astype(np.float16), "bias": bias}
feed = inputs()
for attempt in ("first_load", "second_load"):
    t0 = time.perf_counter()
    m = ct.models.MLModel(pkg, compute_units=ct.ComputeUnit.CPU_AND_NE)
    load_s = time.perf_counter() - t0
    t0 = time.perf_counter(); o = np.asarray(m.predict(feed)["h"], dtype=np.float32); first_ms = 1000 * (time.perf_counter() - t0)
    t0 = time.perf_counter()
    for _ in range(3): o = np.asarray(m.predict(feed)["h"], dtype=np.float32)
    ms = 1000 * (time.perf_counter() - t0) / 3
    print(json.dumps({attempt: {"load_s": round(load_s, 1), "first_predict_ms": round(first_ms), "predict_ms": round(ms), "finite": bool(np.isfinite(o).all()), "out_max": round(float(np.abs(o).max()), 1)}}), flush=True)
    del m
try:
    compiled = ct.models.utils.compile_model(pkg)
    plan_ = ct.models.compute_plan.MLComputePlan.load_from_path(compiled, compute_units=ct.ComputeUnit.CPU_AND_NE)
    prog = plan_.model_structure.program
    counts = {}
    for op in prog.functions["main"].block.operations:
        usage = plan_.get_compute_device_usage_for_mlprogram_operation(op)
        dev = type(usage.preferred_compute_device).__name__ if usage else "none"
        counts[dev] = counts.get(dev, 0) + 1
    print(json.dumps({"placement": counts}), flush=True)
except Exception as e:
    print(json.dumps({"placement_error": str(e)[:160]}), flush=True)
