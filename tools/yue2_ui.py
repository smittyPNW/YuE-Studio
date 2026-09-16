#!/usr/bin/env python3
"""Local web UI for YuE2: lyrics + style in, N song variations out in one run.

    python tools/yue2_ui.py            # opens http://127.0.0.1:7860

All N songs decode together in one batch (see yue2.batched), so on a
bandwidth-bound GPU such as Apple Silicon the token stages cost about the same
for 4 songs as for 1. Audio synthesis and decoding run per song afterwards, and
each song appears in the page as soon as it is ready.
"""
import argparse
import datetime as dt
import json
import threading
import time
import traceback
from pathlib import Path

import gradio as gr
import torch

from yue2 import YuE2Pipeline
from yue2.batched import generate_tokens_batched
from yue2.pipeline import SemanticResult, SongResult, SymbolicPlan
from yue2.protocol import CODEC_OFFSET, token_prefixes
from yue2.storage import identity

ROOT = Path(__file__).resolve().parents[1]
MAX_BATCH = 8
EXAMPLE = json.loads((ROOT / "examples/song.json").read_text(encoding="utf-8"))
PIPE = None
STOP = threading.Event()


def pipeline():
    global PIPE
    if PIPE is None:
        device = "cuda" if torch.cuda.is_available() else "mps" if torch.backends.mps.is_available() else "cpu"
        PIPE = YuE2Pipeline.from_pretrained("m-a-p/YuE2-3B", device=device, progress=False)
        PIPE._load_model()
    return PIPE


def bar(fraction, width=24):
    filled = int(round(max(0.0, min(1.0, fraction)) * width))
    return "`" + "█" * filled + "░" * (width - filled) + f"` {100 * fraction:3.0f}%"


def render_status(state):
    elapsed = time.perf_counter() - state["start"]
    lines = [f"### {state['stage']}", bar(state["fraction"]), state["detail"], f"Elapsed {elapsed:.0f} s",
             f"Request received: style “{state['style'][:70]}…” · lyrics start “{state['lyric_start']}…” · "
             f"seeds {state['seeds']} · mode {state['mode']}"]
    if state["songs"]:
        lines.append("")
        lines.append("| Song | Status |")
        lines.append("|---|---|")
        for i, s in enumerate(state["songs"]):
            lines.append(f"| {i + 1} | {s} |")
    if state["error"]:
        lines.append(f"\n**Error:** `{state['error']}`")
    return "\n\n".join(lines)


def worker(state, style, lyrics, mode, abc, seeds):
    n = len(seeds)
    pipe = pipeline()
    tokenizer = pipe.tokenizer
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    out_root = ROOT / "outputs" / "ui" / stamp
    state["out_root"] = out_root
    cancelled = STOP.is_set
    requests = [pipe._request(style=style, lyrics=lyrics, cot=mode, seed=s, abc=abc or None,
                              id=f"song{i + 1}", **({"cfg_scale": 1.0} if mode == "off" else {}))
                for i, s in enumerate(seeds)]

    # Stage 1: symbolic plans, batched when the model must write the score.
    state.update(stage=f"Planning {n} score(s)", fraction=0.02, detail="Building prompts")
    model = pipe._load_model()  # a previous run's decode step parks the model on the CPU
    if mode == "off" or abc:
        plans = [pipe.plan(request=r) for r in requests]
    else:
        prefixes = [token_prefixes(r, tokenizer) for r in requests]
        counts = [0] * n

        def on_abc(row, phase, token):
            counts[row] += 1
            total = sum(counts)
            state.update(fraction=0.02 + 0.13 * min(1.0, total / (n * 700)),
                         detail=f"Score tokens so far: {', '.join(map(str, counts))} (one batch of {n})")
        rows, _ = generate_tokens_batched(model, prefixes, pipe.generation_config.abc, seeds, "abc",
                                          cancelled=cancelled, on_token=on_abc)
        plans = [SymbolicPlan(r, tokenizer.decode(ids), ids, token_prefixes(r, tokenizer, ids), timing, truncated)
                 for r, (ids, timing, truncated) in zip(requests, rows)]
    state["plans"] = plans

    # Stage 2: song tokens for all plans in one batch.
    counts = [0] * n
    state.update(stage=f"Generating song tokens for {n} song(s)", fraction=0.15, detail="Prefilling")

    def on_song(row, phase, token):
        counts[row] += 1
        total = sum(counts)
        state.update(fraction=0.15 + 0.25 * min(1.0, total / (n * 1500)),
                     detail=f"Song tokens so far: {', '.join(map(str, counts))} · ~25 tokens ≈ 1 s of audio")
    rows, batch_timing = generate_tokens_batched(model, [p.prefix for p in plans],
                                                 pipe.generation_config.semantic, seeds, "semantic",
                                                 legacy_off=(mode == "off"), cancelled=cancelled, on_token=on_song)
    state["batch_timing"] = batch_timing

    # Stage 3: synthesis + decode per song; each result is published as it lands.
    from yue2.nar import synthesize
    for i, (plan, (tokens, timing, truncated)) in enumerate(zip(plans, rows)):
        seconds_est = len(tokens) / 25
        state.update(stage=f"Synthesizing audio: song {i + 1} of {n}", fraction=0.4 + 0.6 * i / n,
                     detail=f"About {seconds_est:.0f} s of audio; this stage is compute-bound and runs per song")
        state["songs"][i] = "synthesizing"
        semantic = SemanticResult(plan, [int(t) - CODEC_OFFSET for t in tokens], timing, truncated)
        model = pipe._load_model(for_nar=True)

        def on_nar(done, total, i=i):
            state.update(fraction=0.4 + 0.6 * (i + 0.9 * done / max(total, 1)) / n,
                         detail=f"ODE step {done}/{total} · about {len(tokens) / 25:.0f} s of audio")
        t0 = time.perf_counter()
        latents = synthesize(model, plan.prefix, semantic.tokens, plan.request.seed,
                             steps=pipe.generation_config.ode_steps, context=pipe.generation_config.context,
                             offload_ar=pipe.offload_ar, cancelled=cancelled, on_progress=on_nar)
        latents = latents.detach().float().cpu().numpy()
        nar = time.perf_counter() - t0
        state.update(detail="Decoding waveform")
        t1 = time.perf_counter()
        audio = pipe.decode(latents)
        config = pipe.effective_config(plan.request)
        config["execution"] = "eager_batched"
        song = SongResult(audio, 48000, semantic, latents, config, pipe.weights,
                          {"semantic": timing, "nar_seconds": nar, "vae_seconds": time.perf_counter() - t1},
                          identity({"request": plan.request.to_dict(), "config": config, "weights": pipe.weights}))
        directory = out_root / plan.request.id
        song.save_artifacts(directory)
        length = len(audio) / 48000
        state["songs"][i] = f"done · {length:.1f} s · {nar:.0f} s to synthesize"
        state["results"][i] = (str(directory / "audio.flac"), plan.abc or "(no score: direct mode)",
                               length, plan.request.seed, truncated or plan.truncated)
    state.update(stage="Complete", fraction=1.0, detail="")


def outputs_for(state, n):
    out = []
    for i in range(MAX_BATCH):
        result = state["results"][i] if i < n else None
        if result:
            path, score, length, seed_i, truncated = result
            label = f"Song {i + 1} · seed {seed_i} · {length:.1f} s" + (" · truncated" if truncated else "")
            out += [gr.update(value=path, label=label, visible=True), gr.update(value=score, visible=True)]
        elif i < n:
            out += [gr.update(value=None, label=f"Song {i + 1} · pending", visible=True), gr.update(value="", visible=False)]
        else:
            out += [gr.update(value=None, visible=False), gr.update(value="", visible=False)]
    return out


def generate(style, lyrics, mode, abc, seed, random_seed, batch):
    style, lyrics, abc = style.strip(), lyrics.strip(), (abc or "").strip()
    if not style or not lyrics:
        raise gr.Error("Enter both a style and lyrics.")
    if mode == "off" and abc:
        raise gr.Error("A supplied score needs full or melody mode.")
    n = int(batch)
    base = int(time.time()) % 10_000_000 if random_seed else int(seed)
    seeds = [base + i for i in range(n)]
    STOP.clear()
    first_line = next((l for l in lyrics.splitlines() if l.strip() and not l.strip().startswith("[")), lyrics)[:50]
    state = {"stage": "Starting", "fraction": 0.0, "detail": "Loading model on first run", "start": time.perf_counter(),
             "songs": ["queued"] * n, "results": [None] * n, "error": None, "done": False,
             "style": style, "lyric_start": first_line, "seeds": seeds, "mode": mode}
    yield [render_status(state), *outputs_for(state, n)]

    def run():
        try:
            worker(state, style, lyrics, mode, abc, seeds)
        except InterruptedError:
            state.update(stage="Stopped", detail="Cancelled by the Stop button")
        except Exception as exc:  # surfaced in the status panel
            state["error"] = f"{type(exc).__name__}: {exc}"
            traceback.print_exc()
        finally:
            state["done"] = True
    threading.Thread(target=run, daemon=True).start()

    published = 0
    while not state["done"]:
        time.sleep(1)
        ready = sum(1 for r in state["results"] if r)
        if ready != published:
            published = ready
            yield [render_status(state), *outputs_for(state, n)]
        else:
            yield [render_status(state), *([gr.update()] * (2 * MAX_BATCH))]
    if state["error"]:
        raise gr.Error(state["error"])
    if state.get("batch_timing") and state["stage"] == "Complete":
        bt = state["batch_timing"]
        total = time.perf_counter() - state["start"]
        state["detail"] = (f"**{n} song(s) in {total:.0f} s.** Token stages ran as one batch of {n}: "
                           f"{bt['aggregate_tps']:.1f} tokens/s aggregate, {1000 * (bt['mean_step_seconds'] or 0):.0f} ms per step. "
                           f"Saved under `{state['out_root'].relative_to(ROOT)}`")
    yield [render_status(state), *outputs_for(state, n)]


def build():
    with gr.Blocks(title="YuE2 batch studio") as demo:
        gr.Markdown("# YuE2 batch studio\nLyrics and a style in, several song variations out of one run. "
                    "Each song gets its own seed and, in full or melody mode, its own score.")
        with gr.Row():
            with gr.Column(scale=1):
                style = gr.Textbox(label="Style", value=EXAMPLE["style"], lines=3,
                                   info="Language, genre, voice, instruments, mood, tempo")
                lyrics = gr.Textbox(label="Lyrics", value=EXAMPLE["lyrics"], lines=14,
                                    info="Use section tags such as [Verse] and [Chorus]")
                with gr.Row():
                    batch = gr.Slider(1, MAX_BATCH, value=2, step=1, label="Songs per run (batch size)")
                    mode = gr.Radio(["full", "melody", "off"], value="full", label="Planning mode",
                                    info="full: melody + chords plan · melody: melody plan · off: direct")
                with gr.Row():
                    seed = gr.Number(value=EXAMPLE["seed"], precision=0, label="Base seed", info="Song i uses seed + i")
                    random_seed = gr.Checkbox(value=False, label="Random seed each run")
                with gr.Accordion("Supply your own ABC score (optional)", open=False):
                    abc = gr.Textbox(label="ABC score", lines=8, placeholder="Paste an ABC score for full or melody mode")
                with gr.Row():
                    run = gr.Button("Generate", variant="primary")
                    stop = gr.Button("Stop", variant="stop")
                status = gr.Markdown("Ready. Expect roughly 2 minutes of token generation for the whole batch, "
                                     "then about 4 seconds of synthesis per second of audio for each song.")
            with gr.Column(scale=1):
                players, scores = [], []
                for i in range(MAX_BATCH):
                    players.append(gr.Audio(label=f"Song {i + 1}", type="filepath", visible=False, interactive=False))
                    scores.append(gr.Textbox(label=f"Score {i + 1} (ABC)", lines=6, visible=False))
        outputs = [status]
        for player, score in zip(players, scores):
            outputs += [player, score]
        run.click(generate, inputs=[style, lyrics, mode, abc, seed, random_seed, batch], outputs=outputs,
                  show_progress="minimal")
        stop.click(lambda: STOP.set(), None, None, queue=False)
    return demo


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=7860)
    ap.add_argument("--no-browser", action="store_true")
    args = ap.parse_args()
    build().queue(default_concurrency_limit=1).launch(server_name="127.0.0.1", server_port=args.port,
                                                       inbrowser=not args.no_browser, show_error=True)
