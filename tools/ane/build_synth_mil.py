"""Emit MIL text + weight blob for a YuE2-synthesis-shaped layer stack.

coremltools is used ONLY as an offline MIL text generator; nothing here touches
the Neural Engine at run time. Real model shapes: hidden 2048, 16 query heads,
8 key-value heads, head dim 128, MLP 6144; frames attend to a cached prefix of
keys plus themselves.

Usage: python build_synth_mil.py <out dir> [--frames N] [--prefix N] [--layers N]
         [--attn full|chunked] [--qblk N] [--kchunk N] [--conv] [--kv 8|16]
"""
import argparse, json, shutil, tempfile
from pathlib import Path
import numpy as np
import coremltools as ct
from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil.mil import types

ap = argparse.ArgumentParser()
ap.add_argument("out"); ap.add_argument("--frames", type=int, default=2048); ap.add_argument("--prefix", type=int, default=2048)
ap.add_argument("--layers", type=int, default=1); ap.add_argument("--attn", default="full", choices=["full", "chunked"])
ap.add_argument("--qblk", type=int, default=128); ap.add_argument("--kchunk", type=int, default=512)
ap.add_argument("--conv", action="store_true"); ap.add_argument("--kv", type=int, default=8); ap.add_argument("--ff", type=int, default=6144)
a = ap.parse_args()
S, P, L, D, H, KV, HD, FF = a.frames, a.prefix, a.layers, 2048, 16, a.kv, 128, a.ff
G = H // KV
K = P + S                      # keys visible to every frame
rng = np.random.default_rng(0)
def w(r, c): return (rng.standard_normal((r, c)) * 0.01).astype(np.float16)
Ws = [dict(q=w(H * HD, D), k=w(KV * HD, D), v=w(KV * HD, D), o=w(D, H * HD), g=w(FF, D), u=w(FF, D), d=w(D, FF),
           pk=(rng.standard_normal((1, KV, P, HD)) * 0.5).astype(np.float16), pv=(rng.standard_normal((1, KV, P, HD)) * 0.5).astype(np.float16))
      for _ in range(L)]

def linear(x, W):
    """x [1,1,S,in] -> [1,1,S,out]; optionally as a 1x1 conv on the channel layout."""
    if not a.conv:
        return mb.matmul(x=x, y=W, transpose_y=True)
    xc = mb.transpose(x=mb.reshape(x=x, shape=[1, S, W.shape[1], 1]), perm=[0, 2, 1, 3])      # [1,in,S,1]
    yc = mb.conv(x=xc, weight=W.reshape(W.shape[0], W.shape[1], 1, 1))                       # [1,out,S,1]
    return mb.reshape(x=mb.transpose(x=yc, perm=[0, 2, 1, 3]), shape=[1, 1, S, W.shape[0]])

def heads(t, n):                     # [1,1,S,n*HD] -> [1,n,S,HD]
    return mb.transpose(x=mb.reshape(x=t, shape=[1, S, n, HD]), perm=[0, 2, 1, 3])

def grouped_q(q):                    # [1,H,S,HD] -> [1,KV,G*S,HD]: query heads of one KV group stacked along the sequence
    return mb.reshape(x=q, shape=[1, KV, G * S, HD])

def full_attention(qg, kk, vv):
    sc = mb.mul(x=mb.matmul(x=qg, y=kk, transpose_y=True), y=np.float16(HD ** -0.5))   # [1,KV,G*S,K]
    return mb.matmul(x=mb.softmax(x=sc, axis=-1), y=vv)                                  # [1,KV,G*S,HD]

def chunked_attention(qg, kk, vv):
    """Online softmax over key chunks; each tile [1,KV,G*qblk,kchunk] stays small."""
    outs = []
    scale = np.float16(HD ** -0.5)
    for s in range(0, S, a.qblk):
        rows = []
        for gi in range(G):          # gather this block's rows for every group: rows gi*S+s .. gi*S+s+qblk
            rows.append(mb.slice_by_index(x=qg, begin=[0, 0, gi * S + s, 0], end=[1, KV, gi * S + s + a.qblk, HD]))
        qb = mb.concat(values=rows, axis=2) if G > 1 else rows[0]                          # [1,KV,G*qblk,HD]
        m = l = acc = None
        for c in range(0, K, a.kchunk):
            kc = mb.slice_by_index(x=kk, begin=[0, 0, c, 0], end=[1, KV, min(c + a.kchunk, K), HD])
            vc = mb.slice_by_index(x=vv, begin=[0, 0, c, 0], end=[1, KV, min(c + a.kchunk, K), HD])
            sc = mb.mul(x=mb.matmul(x=qb, y=kc, transpose_y=True), y=scale)                 # [1,KV,G*qblk,chunk]
            mc = mb.reduce_max(x=sc, axes=[-1], keep_dims=True)
            if m is None:
                m = mc
                p = mb.exp(x=mb.sub(x=sc, y=m))
                l = mb.reduce_sum(x=p, axes=[-1], keep_dims=True)
                acc = mb.matmul(x=p, y=vc)
            else:
                m_new = mb.maximum(x=m, y=mc)
                alpha = mb.exp(x=mb.sub(x=m, y=m_new))
                p = mb.exp(x=mb.sub(x=sc, y=m_new))
                l = mb.add(x=mb.mul(x=l, y=alpha), y=mb.reduce_sum(x=p, axes=[-1], keep_dims=True))
                acc = mb.add(x=mb.mul(x=acc, y=alpha), y=mb.matmul(x=p, y=vc))
                m = m_new
        outs.append(mb.real_div(x=acc, y=l))                                                 # [1,KV,G*qblk,HD]
    # reassemble [1,KV,G*S,HD] in group-major order
    per_group = [[] for _ in range(G)]
    for o in outs:
        for gi in range(G):
            per_group[gi].append(mb.slice_by_index(x=o, begin=[0, 0, gi * a.qblk, 0], end=[1, KV, (gi + 1) * a.qblk, HD]))
    return mb.concat(values=[mb.concat(values=pg, axis=2) if len(pg) > 1 else pg[0] for pg in per_group], axis=2) if G > 1 else mb.concat(values=outs, axis=2)

@mb.program(input_specs=[mb.TensorSpec(shape=(1, 1, S, D), dtype=types.fp16)], opset_version=ct.target.macOS15)
def prog(x):
    h = x
    for W in Ws:
        q, k, v = linear(h, W["q"]), linear(h, W["k"]), linear(h, W["v"])
        qg = grouped_q(heads(q, H))
        kk = mb.concat(values=[W["pk"], heads(k, KV)], axis=2)                                # [1,KV,K,HD]
        vv = mb.concat(values=[W["pv"], heads(v, KV)], axis=2)
        att = full_attention(qg, kk, vv) if a.attn == "full" else chunked_attention(qg, kk, vv)
        af = mb.reshape(x=mb.transpose(x=mb.reshape(x=att, shape=[1, H, S, HD]), perm=[0, 2, 1, 3]), shape=[1, 1, S, H * HD])
        r = mb.add(x=h, y=linear(af, W["o"]))
        hp = mb.mul(x=mb.silu(x=linear(r, W["g"])), y=linear(r, W["u"]))
        h = mb.add(x=r, y=linear(hp, W["d"]))
    return mb.identity(x=h, name="out")

model = ct.convert(prog, convert_to="mlprogram", compute_precision=ct.precision.FLOAT16,
                   minimum_deployment_target=ct.target.macOS15,
                   outputs=[ct.TensorType(name="out", dtype=np.float16)], skip_model_load=True)
tmp = Path(tempfile.mkdtemp()); pkg = tmp / "m.mlpackage"; model.save(str(pkg))
compiled = Path(ct.models.utils.compile_model(str(pkg)))
out = Path(a.out)
if out.exists(): shutil.rmtree(out)
out.mkdir(parents=True); (out / "weights").mkdir()
shutil.copy(compiled / "model.mil", out / "model.mil"); shutil.copy(compiled / "weights" / "weight.bin", out / "weights" / "weight.bin")
shutil.rmtree(tmp, ignore_errors=True)
flops = L * (2.0 * S * D * (H + 2 * KV) * HD + 2.0 * S * H * HD * D + 2.0 * H * S * K * HD * 2 + 2.0 * S * D * FF * 3)
mil = (out / "model.mil").read_text()
meta = {"frames": S, "prefix": P, "keys": K, "layers": L, "attn": a.attn, "qblk": a.qblk, "kchunk": a.kchunk, "conv": a.conv, "kv": KV, "ff": FF,
        "gflop_per_pass": round(flops / 1e9), "mil_ops": mil.count(")[name = string("), "mil_KB": len(mil) // 1024,
        "weights_MB": (out / "weights/weight.bin").stat().st_size // 2**20}
(out / "meta.json").write_text(json.dumps(meta))
print(json.dumps(meta))
