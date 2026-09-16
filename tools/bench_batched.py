#!/usr/bin/env python3
"""Measure whether N songs decoded together cost ~the same per step as one.

Stage 1: fixed-length decode (min_tokens == max_tokens) for batch sizes 1..N,
reporting ms/step and aggregate tokens/s. Stage 2 (optional): a real batched
run of two songs with natural stopping, synthesized and saved as audio.
"""
import argparse, json, time
from pathlib import Path
import torch
from yue2 import YuE2Pipeline
from yue2.protocol import Sampling
from yue2.sampling import generate_tokens, synchronize
from yue2.batched import generate_tokens_batched
from yue2.pipeline import SemanticResult, SongResult
from yue2.protocol import CODEC_OFFSET
from yue2.storage import identity

ROOT = Path(__file__).resolve().parents[1]


def build_requests(pipe):
    song = json.loads((ROOT / "examples/song.json").read_text())
    score = (ROOT / "outputs/first-song/city_lights/score.abc").read_text()
    a = dict(song, abc=score, cot="full")                      # City Lights with its planned score
    b = dict(id="melody_cover", style="English, upbeat indie folk, male vocal, acoustic guitar, "
             "hand claps, bright and hopeful, 118 BPM", lyrics=song["lyrics"],
             abc=(ROOT / "examples/melody.abc").read_text(), cot="melody", seed=17)
    return a, b


def plans(pipe, requests):
    return [pipe.plan(request=pipe._request(**r)) for r in requests]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--steps", type=int, default=200)
    ap.add_argument("--sizes", default="1,2,4,8")
    ap.add_argument("--real", action="store_true", help="also render two real songs batched")
    ap.add_argument("--output", default="outputs/batched")
    args = ap.parse_args()
    sizes = [int(s) for s in args.sizes.split(",")]

    pipe = YuE2Pipeline.from_pretrained("m-a-p/YuE2-3B", device="mps", progress=False)
    model = pipe._load_model()
    cfg = model.config
    print(json.dumps({"layers": cfg.num_hidden_layers, "kv_heads": cfg.num_key_value_heads,
                      "head_dim": cfg.head_dim, "hidden": cfg.hidden_size, "vocab": cfg.vocab_size,
                      "params_M": round(sum(p.numel() for p in model.parameters()) / 1e6)}))
    a, b = build_requests(pipe)
    plan_a, plan_b = plans(pipe, [a, b])
    print(json.dumps({"prefix_a": len(plan_a.prefix), "prefix_b": len(plan_b.prefix)}))

    # Correctness: batched prefill logits vs unpadded single prefill for the shorter row.
    from yue2.modeling_yue2 import StaticKVCache
    def single_logits(prefix):
        cache = StaticKVCache(num_layers=cfg.num_hidden_layers, batch_size=1, num_kv_heads=cfg.num_key_value_heads,
                              max_seq_len=len(prefix) + 1, head_dim=cfg.head_dim, dtype=torch.bfloat16, device=pipe.device)
        return model(torch.tensor([prefix], device=pipe.device), past_key_values=cache, use_cache=True,
                     logits_to_keep=1).logits[0, -1].float()
    fixed1 = Sampling(min_tokens=1, max_tokens=1)
    rows, _ = generate_tokens_batched(model, [plan_a.prefix, plan_b.prefix], fixed1, [1, 1], "semantic")
    # Re-run prefill only to grab logits: cheap hack via temperature=0 argmax agreement.
    fixed0 = Sampling(temperature=0, min_tokens=1, max_tokens=1)
    rows0, _ = generate_tokens_batched(model, [plan_a.prefix, plan_b.prefix], fixed0, [1, 1], "semantic")
    with torch.inference_mode():
        for name, plan, row in (("a", plan_a, rows0[0]), ("b", plan_b, rows0[1])):
            single = single_logits(plan.prefix)
            single[:CODEC_OFFSET] = -float("inf")
            print(json.dumps({"check": name, "single_argmax": int(single.argmax()), "batched_argmax": row[0][0],
                              "agree": int(single.argmax()) == row[0][0]}))

    # Stage 1: fixed-length decode timing.
    fixed = Sampling(min_tokens=args.steps, max_tokens=args.steps)
    results = []
    # Library single-request loop as the reference.
    synchronize(pipe.device); t0 = time.perf_counter()
    _, timing, _ = generate_tokens(model, plan_a.prefix, fixed, 1, "semantic")
    ref = {"batch": "library-1", "ms_per_step": 1000 * (timing["seconds"] - timing["prefill_seconds"]) / args.steps,
           "aggregate_tps": timing["output_tps"], "prefill_s": timing["prefill_seconds"]}
    print(json.dumps(ref)); results.append(ref)
    for n in sizes:
        prefixes = [plan_a.prefix, plan_b.prefix] * ((n + 1) // 2)
        prefixes = prefixes[:n]
        seeds = list(range(100, 100 + n))
        try:
            rows, batch = generate_tokens_batched(model, prefixes, fixed, seeds, "semantic")
        except RuntimeError as e:
            print(json.dumps({"batch": n, "error": str(e)[:200]})); break
        r = {"batch": n, "ms_per_step": 1000 * batch["mean_step_seconds"], "aggregate_tps": batch["aggregate_tps"],
             "per_song_tps": batch["aggregate_tps"] / n, "prefill_s": batch["prefill_seconds"]}
        print(json.dumps(r)); results.append(r)
    (ROOT / "outputs").mkdir(exist_ok=True)
    (ROOT / "outputs/bench_batched.json").write_text(json.dumps(results, indent=2))

    if not args.real:
        return
    # Stage 2: two real songs, natural stopping, then per-song synthesis and decode.
    sampling = pipe.generation_config.semantic
    t0 = time.perf_counter()
    rows, batch = generate_tokens_batched(model, [plan_a.prefix, plan_b.prefix], sampling,
                                          [plan_a.request.seed, plan_b.request.seed], "semantic")
    print(json.dumps({"real_batched_semantic": batch}))
    for name, plan, (tokens, timing, truncated) in (("a_city_lights", plan_a, rows[0]), ("b_melody_cover", plan_b, rows[1])):
        semantic = SemanticResult(plan, [int(t) - CODEC_OFFSET for t in tokens], timing, truncated)
        s0 = time.perf_counter()
        latents = pipe.synthesize(semantic)
        nar = time.perf_counter() - s0
        v0 = time.perf_counter()
        audio = pipe.decode(latents)
        config = pipe.effective_config(plan.request)
        config["execution"] = "eager_batched"
        song = SongResult(audio, 48000, semantic, latents, config, pipe.weights,
                          {"semantic": timing, "nar_seconds": nar, "vae_seconds": time.perf_counter() - v0},
                          identity({"request": plan.request.to_dict(), "config": config, "weights": pipe.weights}))
        out = ROOT / args.output / name
        song.save_artifacts(out)
        print(json.dumps({"saved": str(out / "audio.flac"), "seconds_audio": round(len(audio) / 48000, 1),
                          "tokens": len(tokens), "truncated": truncated}))
    print(json.dumps({"real_total_seconds": time.perf_counter() - t0}))


if __name__ == "__main__":
    main()
