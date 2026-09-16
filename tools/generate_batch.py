#!/usr/bin/env python3
"""Generate N variations of one request in a single batched run.

    python tools/generate_batch.py --request requests/song.json --batch 2 \
        --max-tokens 6500 --output outputs/song

Seeds are request.seed + i. Planning and song tokens run as one batch (see
yue2.batched); synthesis and decoding run per song. --max-tokens caps the song
token budget (~25 tokens per second of audio) so a runaway song cannot stall
the whole batch.
"""
import argparse
import dataclasses
import json
import sys
import time
from pathlib import Path


def log(**fields):
    print(json.dumps(fields), flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--request", required=True, type=Path)
    ap.add_argument("--batch", type=int, default=2)
    ap.add_argument("--max-tokens", type=int, default=9000, help="song token cap; ~25 tokens per second of audio")
    ap.add_argument("--output", required=True, type=Path)
    ap.add_argument("--device", default="auto")
    args = ap.parse_args()
    if args.output.exists():
        ap.error("Choose a fresh output directory")
    from yue2 import YuE2Pipeline
    from yue2.batched import generate_tokens_batched
    from yue2.nar import synthesize
    from yue2.pipeline import SemanticResult, SongResult, SymbolicPlan
    from yue2.protocol import CODEC_OFFSET, token_prefixes
    from yue2.storage import identity

    base = json.loads(args.request.read_text(encoding="utf-8"))
    pipe = YuE2Pipeline.from_pretrained("m-a-p/YuE2-3B", device=args.device, progress=False)
    model = pipe._load_model()
    n = args.batch
    seeds = [int(base.get("seed", 0)) + i for i in range(n)]
    requests = [pipe._request(**{**base, "seed": s, "id": f"{base.get('id', 'song')}_{i + 1}"}) for i, s in enumerate(seeds)]
    mode = requests[0].cot
    start = time.perf_counter()

    counts = [0] * n
    last = [0.0]

    def reporter(stage):
        def on_token(row, phase, token):
            counts[row] += 1
            if time.perf_counter() - last[0] > 10:
                last[0] = time.perf_counter()
                log(stage=stage, tokens=list(counts), elapsed=round(time.perf_counter() - start))
        return on_token

    if mode == "off" or requests[0].abc is not None:
        plans = [pipe.plan(request=r) for r in requests]
    else:
        prefixes = [token_prefixes(r, pipe.tokenizer) for r in requests]
        rows, timing = generate_tokens_batched(model, prefixes, pipe.generation_config.abc, seeds, "abc", on_token=reporter("plan"))
        plans = [SymbolicPlan(r, pipe.tokenizer.decode(ids), ids, token_prefixes(r, pipe.tokenizer, ids), t, trunc)
                 for r, (ids, t, trunc) in zip(requests, rows)]
        log(stage="plan", done=True, tokens=[len(p.abc_ids) for p in plans], seconds=round(timing["seconds"]))

    counts[:] = [0] * n
    sampling = dataclasses.replace(pipe.generation_config.semantic, max_tokens=min(args.max_tokens, pipe.generation_config.semantic.max_tokens))
    rows, timing = generate_tokens_batched(model, [p.prefix for p in plans], sampling, seeds, "semantic",
                                           legacy_off=(mode == "off"), on_token=reporter("song"))
    log(stage="song", done=True, tokens=[len(r[0]) for r in rows], truncated=[r[2] for r in rows],
        seconds=round(timing["seconds"]), ms_per_step=round(1000 * (timing["mean_step_seconds"] or 0)))

    for i, (plan, (tokens, t, truncated)) in enumerate(zip(plans, rows)):
        semantic = SemanticResult(plan, [int(x) - CODEC_OFFSET for x in tokens], t, truncated)
        model = pipe._load_model(for_nar=True)
        t0 = time.perf_counter()
        latents = synthesize(model, plan.prefix, semantic.tokens, plan.request.seed, steps=pipe.generation_config.ode_steps,
                             context=pipe.generation_config.context, offload_ar=pipe.offload_ar,
                             on_progress=lambda d, tot, i=i: log(stage="synthesize", song=i + 1, step=d, of=tot) if d % 8 == 0 else None)
        latents = latents.detach().float().cpu().numpy()
        nar = time.perf_counter() - t0
        t1 = time.perf_counter()
        audio = pipe.decode(latents)
        config = pipe.effective_config(plan.request)
        config["execution"] = "eager_batched"
        song = SongResult(audio, 48000, semantic, latents, config, pipe.weights,
                          {"semantic": t, "nar_seconds": nar, "vae_seconds": time.perf_counter() - t1},
                          identity({"request": plan.request.to_dict(), "config": config, "weights": pipe.weights}))
        directory = args.output / plan.request.id
        song.save_artifacts(directory)
        log(stage="saved", song=i + 1, path=str(directory / "audio.flac"), audio_seconds=round(len(audio) / 48000, 1),
            synth_seconds=round(nar), truncated=truncated or plan.truncated)
    log(stage="complete", seconds=round(time.perf_counter() - start), output=str(args.output))
    return 0


if __name__ == "__main__":
    sys.exit(main())
