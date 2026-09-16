"""Time one synthesis (NAR) layer at real song sizes with different attention paths on MPS.

Real shapes for a 4-minute song: ~6,000 latent frames attending to ~6,800 cached
prefix keys plus themselves (~12,800 keys), 16 query heads / 8 KV heads, dim 128.
"""
import json, sys, time, torch, torch.nn.functional as F
from yue2 import YuE2Pipeline
from yue2.nar import attention as lib_attention

FRAMES = int(sys.argv[1]) if len(sys.argv) > 1 else 6000
PREFIX = int(sys.argv[2]) if len(sys.argv) > 2 else 6800
pipe = YuE2Pipeline.from_pretrained("m-a-p/YuE2-3B", device="mps", progress=False)
model = pipe._load_model(for_nar=True)
layer = model.model.layers[0]
dev, dt = pipe.device, torch.bfloat16
cfg = model.config
H, KV, HD = cfg.num_attention_heads, cfg.num_key_value_heads, cfg.head_dim

def timed(fn, reps=3):
    with torch.inference_mode():
        fn(); torch.mps.synchronize()
        t = time.perf_counter()
        for _ in range(reps): fn()
        torch.mps.synchronize()
    return (time.perf_counter() - t) / reps * 1000

x = torch.randn(1, FRAMES, cfg.hidden_size, device=dev, dtype=dt) * 0.5
positions = torch.arange(PREFIX, PREFIX + FRAMES, device=dev)[None]
cos, sin = model.model.rotary_emb(positions)
ar_k = torch.randn(PREFIX, KV, HD, device=dev, dtype=dt)
ar_v = torch.randn(PREFIX, KV, HD, device=dev, dtype=dt)
with torch.inference_mode():
    q, k, v = layer.nar_self_attn.project_qkv(layer.nar_input_layernorm(x), cos, sin)
    k_all, v_all = torch.cat((ar_k, k[0])), torch.cat((ar_v, v[0]))
    q0 = q[0]
L = k_all.shape[0]
flops_attn = 2.0 * H * FRAMES * L * HD * 2
flops_dense = 2.0 * FRAMES * (cfg.hidden_size * (H + 2 * KV) * HD + H * HD * cfg.hidden_size + 3 * cfg.hidden_size * cfg.intermediate_size)
print(json.dumps({"frames": FRAMES, "keys": L, "attn_gflop": round(flops_attn / 1e9), "dense_gflop": round(flops_dense / 1e9)}))

# Dense part of the layer (projections + MLP), no attention.
def dense():
    qq, kk, vv = layer.nar_self_attn.project_qkv(layer.nar_input_layernorm(x), cos, sin)
    h = layer.nar_self_attn.o_proj(qq.flatten(2))
    return h + layer.nar_mlp(layer.nar_pre_mlp_layernorm(x + h))
ms = timed(dense)
print(json.dumps({"variant": "dense_only", "ms": round(ms), "tflops": round(flops_dense / (ms / 1000) / 1e12, 2)}))

# Library attention with different query block sizes.
for block in (256, 1024, 4096, FRAMES):
    try:
        ms = timed(lambda: lib_attention(q0, k_all, v_all, query_chunk_size=block))
        print(json.dumps({"variant": f"sdpa_block_{block}", "ms": round(ms), "tflops": round(flops_attn / (ms / 1000) / 1e12, 2)}), flush=True)
    except Exception as e:
        print(json.dumps({"variant": f"sdpa_block_{block}", "error": str(e)[:120]}), flush=True)

# Hand-rolled: bf16 matmuls, grouped heads via broadcasting (no K/V copies), query blocks, full softmax per block.
def manual(block):
    qh = q0.transpose(0, 1).reshape(KV, H // KV, FRAMES, HD)           # [KV, g, S, D]
    kh = k_all.transpose(0, 1)[:, None]                                 # [KV, 1, L, D]
    vh = v_all.transpose(0, 1)[:, None]
    outs = []
    for s in range(0, FRAMES, block):
        sc = torch.matmul(qh[:, :, s:s + block], kh.transpose(-1, -2)) * HD ** -0.5
        p = torch.softmax(sc.float(), -1).to(dt)
        outs.append(torch.matmul(p, vh))
    return torch.cat(outs, 2).reshape(H, FRAMES, HD).transpose(0, 1)
for block in (512, 1024, 2048):
    ms = timed(lambda: manual(block))
    print(json.dumps({"variant": f"manual_bf16_block_{block}", "ms": round(ms), "tflops": round(flops_attn / (ms / 1000) / 1e12, 2)}), flush=True)

# Hand-rolled with bf16 softmax (no fp32 upcast) to see the cast cost.
def manual_bf16_softmax(block):
    qh = q0.transpose(0, 1).reshape(KV, H // KV, FRAMES, HD)
    kh = k_all.transpose(0, 1)[:, None]; vh = v_all.transpose(0, 1)[:, None]
    outs = []
    for s in range(0, FRAMES, block):
        sc = torch.matmul(qh[:, :, s:s + block], kh.transpose(-1, -2)) * HD ** -0.5
        outs.append(torch.matmul(torch.softmax(sc, -1), vh))
    return torch.cat(outs, 2).reshape(H, FRAMES, HD).transpose(0, 1)
ms = timed(lambda: manual_bf16_softmax(1024))
print(json.dumps({"variant": "manual_bf16softmax_block_1024", "ms": round(ms), "tflops": round(flops_attn / (ms / 1000) / 1e12, 2)}), flush=True)

# Correctness of the manual path against the library path.
with torch.inference_mode():
    ref = lib_attention(q0, k_all, v_all, query_chunk_size=256).float()
    got = manual(1024).float()
print(json.dumps({"manual_vs_library_max_abs_diff": round(float((ref - got).abs().max()), 4), "ref_scale": round(float(ref.abs().max()), 3)}))
