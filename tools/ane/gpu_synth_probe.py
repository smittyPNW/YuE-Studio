"""Same synthetic synthesis layer as ane_synth_probe, on the GPU via PyTorch MPS, for a fair comparison."""
import json, sys, time, torch, torch.nn.functional as F
D, H, HD, FF = 2048, 16, 128, 11008
dev = "mps"
def layer(x, W):
    S = x.shape[2]
    q, k, v = (x @ W[n] for n in "qkv")
    heads = lambda t: t.reshape(1, S, H, HD).transpose(1, 2)
    qt, kt, vt = heads(q), heads(k), heads(v)
    at = F.scaled_dot_product_attention(qt, kt, vt)
    r = x + at.transpose(1, 2).reshape(1, 1, S, D) @ W["o"]
    return r + (F.silu(r @ W["g"]) * (r @ W["u"])) @ W["d"]
def layer_math(x, W):
    S = x.shape[2]
    q, k, v = (x @ W[n] for n in "qkv")
    heads = lambda t: t.reshape(1, S, H, HD).transpose(1, 2)
    qt, kt, vt = heads(q), heads(k), heads(v)
    at = torch.softmax((qt @ kt.transpose(-1, -2)) * HD ** -0.5, -1) @ vt
    r = x + at.transpose(1, 2).reshape(1, 1, S, D) @ W["o"]
    return r + (F.silu(r @ W["g"]) * (r @ W["u"])) @ W["d"]
for S in (1024, 6144):
    W = {n: (torch.randn(D if n != "d" else FF, FF if n in "gu" else D, device=dev) * 0.01).to(torch.bfloat16) for n in "qkvogud"}
    x = (torch.rand(1, 1, S, D, device=dev) - 0.5).to(torch.bfloat16)
    flops = 2.0 * S * D * D * 4 + 2.0 * H * S * S * HD * 2 + 2.0 * S * D * FF * 3
    for name, fn in (("sdpa", layer), ("math", layer_math)):
        with torch.inference_mode():
            for _ in range(2): fn(x, W)
            torch.mps.synchronize(); t = time.perf_counter()
            for _ in range(3): fn(x, W)
            torch.mps.synchronize(); ms = (time.perf_counter() - t) / 3 * 1000
        print(json.dumps({"S": S, "attention": name, "gpu_ms_per_layer": round(ms, 1), "tflops": round(flops / (ms / 1000) / 1e12, 2)}), flush=True)
