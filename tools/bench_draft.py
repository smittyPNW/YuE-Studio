"""Draft-quality experiment: same tokens synthesized with fewer midpoint steps (MLX) vs the 32-step reference."""
import dataclasses, json, sys, time
import numpy as np, torch
from pathlib import Path
from yue2.pipeline import YuE2Pipeline
from yue2.batched import generate_tokens_batched
from yue2.nar import synthesize
from yue2.protocol import CODEC_OFFSET, token_prefixes

out = Path(sys.argv[1] if len(sys.argv) > 1 else "outputs/draft-test"); out.mkdir(parents=True, exist_ok=True)
max_tokens = int(sys.argv[2]) if len(sys.argv) > 2 else 500
pipe = YuE2Pipeline.from_pretrained("m-a-p/YuE2-3B", device="mps", progress=False, lean=True)
model = pipe._load_model()
req = pipe._request(style="English, warm piano pop, expressive female voice, acoustic piano, light drums, 88 BPM",
                    lyrics="[Verse]\nNeon fades along the lane\nFootsteps keep the time of rain\n\n[Chorus]\nLet the day come into view\nEvery road begins with you",
                    cot="full", seed=831001, id="draft")
prefix = token_prefixes(req, pipe.tokenizer)
rows, _ = generate_tokens_batched(model, [prefix], pipe.generation_config.abc, [831001], "abc")
plan_ids = rows[0][0]; full_prefix = token_prefixes(req, pipe.tokenizer, plan_ids)
rows, _ = generate_tokens_batched(model, [full_prefix], dataclasses.replace(pipe.generation_config.semantic, max_tokens=max_tokens), [831001], "semantic")
codec = [int(x) - CODEC_OFFSET for x in rows[0][0]]
print(f"{len(codec)} tokens ({len(codec)/25:.0f} s)", flush=True)
model = pipe._load_model(for_nar=True)
results = {}
for steps in (32, 8, 12, 16):
    t0 = time.perf_counter()
    lat = synthesize(model, full_prefix, codec, 831001, steps=steps, engine="mlx").numpy()
    seconds = time.perf_counter() - t0
    audio = pipe.decode(lat)
    import soundfile as sf
    sf.write(out / f"steps{steps}.flac", audio, 48000, subtype="PCM_24")
    results[steps] = (lat, seconds)
    ref = results[32][0]
    corr = float(np.corrcoef(lat.ravel(), ref.ravel())[0, 1])
    rel = float(np.sqrt(((lat - ref) ** 2).mean()) / np.sqrt((ref ** 2).mean()))
    print(f"steps {steps:2d}: {seconds:6.1f} s, corr vs 32 {corr:.4f}, rel rms err {rel:.3f}", flush=True)
json.dump({k: v[1] for k, v in results.items()}, open(out / "timing.json", "w"))
