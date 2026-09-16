#!/usr/bin/env python3
"""Long-lived YuE2 worker for native front ends: JSON lines in on stdin, JSON events out on stdout.

Every request joins a queue and flows through three independent stages, each on its own thread:

    queue -> tokens (GPU: score + song tokens, all songs of a job in one batch)
          -> synthesis (Neural Engine at full quality; GPU/MLX for drafts, and for a full-quality song
                        that would otherwise wait while the GPU is idle: it moves to the Neural Engine mid-solve)
          -> decode (GPU: VAE to waveform, files written)

The stages overlap: the GPU generates the next job's tokens while the Neural Engine synthesizes
this one, and finished latents are decoded as soon as they arrive. Machines under 24 GB run the
stages one at a time (YUE2_PIPELINE=1 forces overlap, =0 forces one at a time).

Requests: {"cmd": "generate", "style", "lyrics", "cot": "full|melody|off", "seed", "random_seed", "batch",
           "max_tokens", "engine": "auto|torch|mlx|ane", "abc": str|null, "quality": "draft|full", "draft_steps",
           "instrumental": bool}   (instrumental: no-vocal tags, marker-only lyrics, vocal voice silenced in the planned score)
          {"cmd": "render", "path": song directory or its audio.flac, "engine", "quality": "full|draft"}
          {"cmd": "cancel", "path"}   {"cmd": "stop"}   {"cmd": "ping"}   {"cmd": "quit"}
Events:   {"event": "ready"}   {"event": "log", "message"}   {"event": "pong"}   {"event": "error", "message"}
          {"event": "started", "job", "output", "songs": [{"index", "seed", "path"}]}     (songs are queued)
          {"event": "stage", "path", "stage": "queued|planning|tokens|synth|decode|ready|failed|cancelled", "detail", "engine"}
          {"event": "progress", "path", "fraction": 0-1, "detail", "gflops": rate}   (gflops: rough throughput, GFLOP/s)
          {"event": "song", "index", "path", "score", "seconds", "seed", "truncated", "quality", "steps", "engine"}
          {"event": "failed", "path", "message"}   {"event": "idle"}   (every queued song finished or was cancelled)
"""
import collections, datetime as dt, json, os, sys, threading, time, traceback
from studio_support import recoverable_ane_error, acquire_worker_lock, persist_state, save_render, song_directory
from pathlib import Path
os.environ.setdefault("TQDM_DISABLE", "1")          # coremltools progress bars would otherwise flood the app log
import warnings
warnings.filterwarnings("ignore")

ROOT = Path(__file__).resolve().parents[1]
OUTPUT_DIR = Path(os.environ.get("YUE2_OUTPUT_DIR", ROOT / "outputs" / "app"))
PIPE = None
LOCK = threading.Lock()                              # stdout
MODEL_LOCK = threading.Lock()                        # model load/unload and memory release
# PyTorch's Metal backend encodes every thread into one command buffer, so all PyTorch GPU work
# (token steps, the synthesis prefill, decode tiles) takes turns on this lock; the Neural Engine
# and MLX solvers run outside it, which is what lets synthesis overlap token generation.
from yue2.locks import FairLock
TORCH_LOCK = FairLock()
IDLE_UNLOAD_S = float(os.environ.get("YUE2_IDLE_UNLOAD_S", 600))   # drop the model after this long idle (reloads in ~1 s)
LAST_ACTIVE = [time.time()]
PHYSICAL_GIB = float(os.environ.get("YUE2_PHYSICAL_GIB") or os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES") / 2**30)
CONCURRENT = os.environ.get("YUE2_PIPELINE", "1" if PHYSICAL_GIB >= 24 else "0") != "0"
STAGE_LOCK = threading.Lock() if not CONCURRENT else None          # one stage at a time on small machines
ANE_MAX_FRAMES = 12288    # MIL v7 compiles up to here (9216 x 14336 verified); 12288 x 14336 is refused, and a
                          # refused compile fails within seconds and falls back to MLX (synthesize_item)


def emit(**event):
    event.setdefault("t", round(time.time(), 2))
    with LOCK:
        sys.stdout.write(json.dumps(event) + "\n"); sys.stdout.flush()


def log(message):
    emit(event="log", message=message, time=dt.datetime.now().strftime("%H:%M:%S"))


def pipeline():
    """The loaded pipeline (loading or reloading the model as needed). Call under MODEL_LOCK."""
    global PIPE
    if PIPE is None:
        import torch
        from yue2 import YuE2Pipeline
        device = "cuda" if torch.cuda.is_available() else "mps" if torch.backends.mps.is_available() else "cpu"
        log(f"Loading YuE2 model on {device} (first run only)")
        t0 = time.perf_counter()
        # Apple Silicon: synthesis runs on the Neural Engine (or MLX), so only the AR path is
        # kept in PyTorch; the NAR weights are read from the checkpoint by those engines.
        lean = device == "mps" and os.environ.get("YUE2_LEAN", "1") != "0"
        # The VAE decodes in tiles; smaller tiles halve its activation peak (about 3.6 GB at 1024
        # frames) on machines where the whole memory is shared with the model.
        PIPE = YuE2Pipeline.from_pretrained("m-a-p/YuE2-3B", device=device, progress=False, lean=lean,
                                            vae_core_frames=1024 if PHYSICAL_GIB >= 24 else 512)
        log(f"Physical memory {PHYSICAL_GIB:.0f} GB: {'lean' if lean else 'full'} model, VAE tile {PIPE.vae_core_frames} frames, "
            f"stages {'overlap' if CONCURRENT else 'run one at a time'}")
        PIPE._load_model()
        log(f"Model ready in {time.perf_counter() - t0:.0f} s")
    elif PIPE._model is None:                        # dropped while idle
        t0 = time.perf_counter()
        PIPE._load_model()
        log(f"Model reloaded in {time.perf_counter() - t0:.0f} s")
    return PIPE


def choose_engine(engine, pipe, n_frames, quality):
    """Resolve the engine for one song. Drafts always use MLX (no compile); "auto" uses the Neural
    Engine only for songs its compiler accepts and falls back to MLX beyond that."""
    from yue2.ane import runtime as ane_runtime
    from yue2 import nar_mlx
    if engine == "torch" and pipe.lean:
        engine = "auto"
    if quality == "draft":
        return "mlx" if nar_mlx.available() else "torch"
    S = ane_runtime.bucket(n_frames + 2, ane_runtime.S_STEP)
    if engine in ("auto", "ane"):
        if ane_runtime.available() and S <= ANE_MAX_FRAMES:
            return "ane"
        return "mlx" if nar_mlx.available() else "torch"
    return engine


# ── Pipeline state ───────────────────────────────────────────────────────────

class Item:
    """One song on its way through the stages."""

    def __init__(self, job, index, seed, request, directory, quality, steps, engine):
        self.job, self.index, self.seed, self.request = job, index, seed, request
        self.directory = Path(directory)
        self.path = str(self.directory / "audio.flac")
        self.quality, self.steps, self.engine = quality, steps, engine
        self.cancel = threading.Event()
        self.stage = "queued"
        self.plan = None; self.codec = None; self.semantic_timing = {}; self.truncated = False
        self.latents = None; self.used_engine = None; self.nar_seconds = 0.0

    @property
    def label(self):
        return f"{self.directory.parent.name}/{self.directory.name}"

    def set_stage(self, stage, detail="", **extra):
        self.stage = stage
        try:
            persist_state(self.directory, stage, detail, **extra)
        except OSError as exc:
            log(f"Could not persist job state: {exc}")
        emit(event="stage", path=self.path, stage=stage, detail=detail, **extra)

    def progress(self, fraction, detail="", gflops=None):
        extra = {} if gflops is None else {"gflops": round(gflops, 1)}
        emit(event="progress", path=self.path, fraction=max(0.0, min(1.0, fraction)), detail=detail, **extra)


# ── Throughput estimates (rough, for the status line) ────────────────────────
# Matmul work only, 2 FLOP per multiply-add, derived from the model shapes; attention counted as
# QK^T and PV over the attended length. The VAE figure was measured with torch's FLOP counter.
VAE_GFLOP_PER_FRAME = 2.31


def _shapes(cfg):
    return cfg.hidden_size, cfg.intermediate_size, cfg.num_attention_heads, cfg.num_key_value_heads, cfg.head_dim, cfg.num_hidden_layers


def flops_per_token(cfg, context):
    """One autoregressive step of one sequence attending ``context`` tokens."""
    D, F, H, KV, HD, L = _shapes(cfg)
    linear = 2 * (D * H * HD + 2 * D * KV * HD + H * HD * D + 3 * D * F)
    attention = 4 * context * H * HD
    return L * (linear + attention) + 2 * D * 32770             # sliced output head (song phase)


def flops_per_pass(cfg, S, P):
    """One velocity evaluation of the synthesis network over S frames attending S + P keys."""
    D, F, H, KV, HD, L = _shapes(cfg)
    linear = 2 * S * (D * H * HD + 2 * D * KV * HD + H * HD * D + 3 * D * F)
    attention = 4 * S * (S + P) * H * HD
    return L * (linear + attention)


class Rate:
    """Smoothed throughput in GFLOP/s from (work done, time) samples."""

    def __init__(self, alpha=0.3):
        self.alpha, self.value, self.last = alpha, None, None

    def add(self, flops):
        now = time.perf_counter()
        if self.last is not None and now > self.last:
            sample = flops / (now - self.last) / 1e9
            self.value = sample if self.value is None else self.alpha * sample + (1 - self.alpha) * self.value
        self.last = now
        return self.value


class Job:
    """One generate request: its songs share a batch in the tokens stage."""

    def __init__(self, id, req, items):
        self.id, self.req, self.items = id, req, items


class Channel:
    """FIFO between stages; cancelled entries are skipped and can be removed while queued."""

    def __init__(self):
        self.items = collections.deque()
        self.cv = threading.Condition()

    def put(self, item):
        with self.cv:
            self.items.append(item); self.cv.notify()

    def get(self):
        with self.cv:
            while not self.items:
                self.cv.wait()
            return self.items.popleft()

    def take(self, pred, on_take=None):
        """The first queued item satisfying ``pred`` (re-checked every second, since predicates may
        depend on lane state); ``on_take`` runs under the lock once it is chosen."""
        with self.cv:
            while True:
                for item in self.items:
                    if pred(item):
                        self.items.remove(item)
                        if on_take is not None:
                            on_take()
                        return item
                self.cv.wait(1.0)

    def remove(self, item):
        with self.cv:
            try:
                self.items.remove(item); return True
            except ValueError:
                return False

    def snapshot(self):
        with self.cv:
            return list(self.items)


class Pipeline:
    def __init__(self):
        self.jobs, self.synth, self.decode = Channel(), Channel(), Channel()
        self.live = {}                               # path -> Item, from queueing until ready/failed/cancelled
        self.lock = threading.Lock()

    def add(self, items):
        with self.lock:
            for item in items:
                self.live[item.path] = item

    def finish(self, item, stage, detail="", **extra):
        """Take an item out of the pipeline (ready, failed or cancelled) and release memory when it was the last."""
        with self.lock:
            if self.live.pop(item.path, None) is None:
                return                                   # already out (cancelled twice)
            empty = not self.live
        item.set_stage(stage, detail, **extra)
        if empty:
            self.drained()

    def drained(self):
        LAST_ACTIVE[0] = time.time()
        with MODEL_LOCK:
            with self.lock:
                if self.live:                        # new work arrived meanwhile
                    return
            try:
                with TORCH_LOCK:
                    release()
            except Exception as exc:
                log(f"Memory release failed: {exc}")
        emit(event="idle")

    def cancel(self, item, reason="cancelled"):
        item.cancel.set()
        if self.synth.remove(item) or self.decode.remove(item):
            self.finish(item, "cancelled", reason); return           # was waiting between stages: gone at once
        job = item.job
        if job is not None and job in self.jobs.snapshot():
            if all(it.cancel.is_set() for it in job.items):
                self.jobs.remove(job)
            self.finish(item, "cancelled", reason); return           # queued job: siblings keep their place
        log(f"Cancelling {item.label} ({item.stage})")              # running: the stage drops it at its next check

    def stop(self):
        with self.lock:
            items = list(self.live.values())
        log(f"Stop requested: cancelling {len(items)} song(s)")
        for item in items:
            self.cancel(item, "stopped")

    def summary(self):
        with self.lock:
            return collections.Counter(it.stage for it in self.live.values())


PIPELINE = Pipeline()


# ── Stages ───────────────────────────────────────────────────────────────────

def stage_lock():
    from contextlib import nullcontext
    return STAGE_LOCK if STAGE_LOCK is not None else nullcontext()


def acquire_model():
    with MODEL_LOCK:
        LAST_ACTIVE[0] = time.time()
        pipe = pipeline()
        return pipe, pipe._load_model()


def save_tokens(item):
    """Persist the plan and song tokens as soon as they exist, so a song can be synthesized later
    (render command) even if the worker stops before its audio is written."""
    import numpy as np
    from yue2.storage import write_json
    item.directory.mkdir(parents=True, exist_ok=True)
    item.plan.save(item.directory)
    np.save(item.directory / "semantic.npy", np.asarray(item.codec, dtype=np.int32))
    write_json(item.directory / "request.json", item.request.to_dict())
    write_json(item.directory / "tokens.json", {"seed": item.seed, "frames": len(item.codec), "quality": item.quality,
                                               "steps": item.steps, "engine": item.engine, "truncated": bool(item.truncated),
                                               "timing": item.semantic_timing})


def tokens_stage():
    while True:
        job = PIPELINE.jobs.get()
        items = [it for it in job.items if not it.cancel.is_set()]
        if not items:
            continue
        with stage_lock():
            set_lane(tokens=True)
            try:
                run_tokens(job, items)
            except InterruptedError:
                for it in items:
                    PIPELINE.finish(it, "cancelled", "stopped")
            except Exception as exc:
                traceback.print_exc(file=sys.stderr)
                log(f"Token generation failed for {job.id}: {type(exc).__name__}: {exc}")
                for it in items:
                    emit(event="failed", path=it.path, message=f"{type(exc).__name__}: {exc}")
                    PIPELINE.finish(it, "failed", str(exc)[:200])
            finally:
                set_lane(tokens=False)


def run_tokens(job, items):
    import dataclasses
    from yue2.batched import generate_tokens_batched
    from yue2.pipeline import SymbolicPlan
    from yue2.protocol import CODEC_OFFSET, token_prefixes
    req = job.req
    pipe, model = acquire_model()
    tokenizer = pipe.tokenizer
    n = len(items); mode = req.get("cot", "full"); engine = req.get("engine", "auto")
    if engine == "torch" and pipe.lean:
        log("The PyTorch synthesis engine needs the full model; using the automatic engine instead")
        engine = "auto"
    abc = (req.get("abc") or "").strip() or None
    cancelled = lambda: all(it.cancel.is_set() for it in items)
    log(f"Tokens: {job.id}, {n} song(s), mode {mode}, seeds {[it.seed for it in items]}")
    max_tokens = min(int(req.get("max_tokens", 9000)), 9000)

    counts = [0] * n; last = [0.0]
    def reporter(phase, expected, prefix_len):
        """Per-song progress and throughput. A batch step costs the same however many rows are still
        producing, so each row's figure is its own tokens per second; a row that reached its end token
        waits for the rest of the batch and shows no rate."""
        from yue2.protocol import ABC_END, MUSIC_END
        end = ABC_END if phase == "abc" else MUSIC_END
        rates, reported, finished = [Rate() for _ in items], [0] * n, [False] * n
        for r in rates:
            r.add(0)
        def on_token(row, _phase, token):
            counts[row] += 1
            if token == end:
                finished[row] = True
            if time.perf_counter() - last[0] > 0.5 or finished[row]:
                last[0] = time.perf_counter()
                for i, it in enumerate(items):
                    if finished[i]:
                        if reported[i] >= 0:
                            it.progress(1.0, "tokens finished"); reported[i] = -1
                        continue
                    gflops = rates[i].add((counts[i] - reported[i]) * flops_per_token(model.config, prefix_len + counts[i]))
                    reported[i] = counts[i]
                    detail = f"{counts[i]} score tokens" if phase == "abc" else f"{counts[i]} tokens (about {counts[i] / 25:.0f} s of audio)"
                    it.progress(min(1.0, counts[i] / expected), detail, gflops)
        return on_token

    requests = [it.request for it in items]
    instrumental = bool(req.get("instrumental"))
    if mode == "off" or abc:
        plans = [pipe.plan(request=r) for r in requests]
    else:
        for it in items:
            it.set_stage("planning", "planning the score")
        prefixes = [token_prefixes(r, tokenizer) for r in requests]
        rows, timing = generate_tokens_batched(model, prefixes, pipe.generation_config.abc, [it.seed for it in items], "abc",
                                               cancelled=cancelled, on_token=reporter("abc", 900, max(len(p) for p in prefixes)), lock=TORCH_LOCK)
        plans = [SymbolicPlan(r, tokenizer.decode(ids), ids, token_prefixes(r, tokenizer, ids), t, trunc)
                 for r, (ids, t, trunc) in zip(requests, rows)]
        log(f"Scores planned for {job.id}: {[len(p.abc_ids) for p in plans]} tokens in {timing['seconds']:.0f} s")
    if instrumental and not abc:
        # Re-plan from each score with its vocal voice silenced: the tokens then carry no sung melody.
        from yue2.instrumental import silence_vocals
        import dataclasses as dc
        plans = [pipe.plan(request=dc.replace(p.request, abc=silence_vocals(p.abc))) if p.abc else p for p in plans]
        log(f"Instrumental: vocal voice silenced in the planned score(s) for {job.id}")
    counts[:] = [0] * n
    for it in items:
        it.set_stage("tokens", "generating song tokens")
    sampling = dataclasses.replace(pipe.generation_config.semantic, max_tokens=max_tokens)

    released = set()
    def release_song(i, tokens, t, truncated):
        """Hand a song to synthesis: as soon as its row ends (while the batch continues), or after the batch."""
        it, plan = items[i], plans[i]
        it.plan, it.codec, it.semantic_timing, it.truncated = plan, [int(x) - CODEC_OFFSET for x in tokens], t, truncated
        it.engine = choose_engine(engine, pipe, len(it.codec), it.quality)
        save_tokens(it)
        released.add(i)
        if it.cancel.is_set():
            PIPELINE.finish(it, "cancelled", "stopped"); return
        it.set_stage("synth", "waiting", engine=it.engine)
        PIPELINE.synth.put(it)
    def on_row_done(i, tokens, t):
        if i not in released:
            log(f"Song tokens for {items[i].label}: {len(tokens)} ({t['seconds']:.0f} s); synthesis can start while the batch continues")
            release_song(i, tokens, t, False)

    rows, timing = generate_tokens_batched(model, [p.prefix for p in plans], sampling, [it.seed for it in items], "semantic",
                                           legacy_off=(mode == "off"), cancelled=cancelled,
                                           on_token=reporter("semantic", max_tokens, max(len(p.prefix) for p in plans)), lock=TORCH_LOCK,
                                           on_row_done=on_row_done)
    log(f"Song tokens for {job.id}: {[len(r[0]) for r in rows]} in {timing['seconds']:.0f} s ({1000 * (timing['mean_step_seconds'] or 0):.0f} ms per step)")
    for i, (tokens, t, truncated) in enumerate(rows):
        if i in released:
            items[i].semantic_timing = t          # final figures for the record
        else:
            release_song(i, tokens, t, truncated)


# ── Synthesis lanes ──────────────────────────────────────────────────────────
# Two lanes share the synthesis queue. The Neural Engine lane takes full-quality songs. The GPU
# lane takes drafts and songs the Neural Engine cannot compile, and, when the GPU has nothing else
# to do, a full-quality song that would otherwise wait: it starts on MLX and moves to the Neural
# Engine mid-solve as soon as that is free (nar_switch), giving the GPU back for rendering.
LANES = {"tokens": False, "decode": False, "gpu_synth": False, "ane": "idle", "migrate_wanted": False,
         "ane_gpu": False}                      # the Neural Engine lane's song is on the GPU (prefix prefill)
SCHED = PIPELINE.synth.cv                        # one condition for the queue and the lane state


def set_lane(**changes):
    with SCHED:
        LANES.update(changes); SCHED.notify_all()


def gpu_idle():
    """Nothing is using or about to use the GPU (tokenizing, rendering, a GPU-lane song)."""
    return CONCURRENT and not LANES["tokens"] and not LANES["decode"] and not LANES["gpu_synth"] \
        and not PIPELINE.jobs.items and not PIPELINE.decode.items


def ane_lane():
    while True:
        item = PIPELINE.synth.take(lambda it: it.engine == "ane" and LANES["ane"] == "idle" and not LANES["migrate_wanted"],
                                   on_take=lambda: LANES.update(ane="lane"))
        try:
            run_synth(item, "ane")
        finally:
            set_lane(ane="idle", ane_gpu=False)


def gpu_lane():
    """One GPU song at a time; each runs in its own thread so the lane is free again the moment a
    song moves to the Neural Engine, even though that song's solve continues."""
    while True:
        item = PIPELINE.synth.take(lambda it: not LANES["gpu_synth"] and (it.engine != "ane" or (LANES["ane"] != "idle" and gpu_idle())),
                                   on_take=lambda: LANES.update(gpu_synth=True))
        def run(item=item):
            try:
                run_synth(item, "gpu")
            finally:
                with SCHED:
                    if getattr(item, "migrated", False):
                        LANES["ane"] = "idle"
                    else:
                        LANES["gpu_synth"] = False
                    LANES["migrate_wanted"] = False
                    SCHED.notify_all()
        threading.Thread(target=run, name=f"gpu-{item.label}", daemon=True).start()


def run_synth(item, lane):
    if item.cancel.is_set():
        PIPELINE.finish(item, "cancelled", "stopped"); return
    with stage_lock():
        try:
            synthesize_item(item, lane)
            if item.cancel.is_set():
                PIPELINE.finish(item, "cancelled", "stopped"); return
            item.set_stage("decode", "waiting", engine=item.used_engine)
            PIPELINE.decode.put(item)
        except InterruptedError:
            PIPELINE.finish(item, "cancelled", "stopped")
        except Exception as exc:
            traceback.print_exc(file=sys.stderr)
            log(f"Synthesis failed for {item.label}: {type(exc).__name__}: {exc}")
            emit(event="failed", path=item.path, message=f"{type(exc).__name__}: {exc}")
            PIPELINE.finish(item, "failed", str(exc)[:200])


WARMING = threading.Lock()


def warm_next(pipe, model, current):
    """While the Neural Engine solves this song, compile the programs of the next Neural Engine song
    in the queue (a different length bucket) so it starts without waiting for the compiler. Songs in
    the same bucket reuse this song's program and need no compile."""
    from yue2.ane import runtime as ane_runtime
    from yue2.nar import song_chunks
    if not WARMING.acquire(blocking=False):
        return
    def warm():
        try:
            for nxt in PIPELINE.synth.snapshot():
                if nxt.engine != "ane" or nxt.cancel.is_set() or nxt.codec is None:
                    continue
                chunk = song_chunks(nxt.plan.prefix, nxt.codec, nxt.seed)[0]
                S, P = ane_runtime.buckets_for((len(chunk.noise) + 2, len(chunk.ar_tokens)))
                if (S, P) in ane_runtime.programs_for(model).loaded:
                    nxt.set_stage("synth", f"waiting for {current.label.split('/')[-1]} · Neural Engine program ready", engine="ane")
                    continue
                nxt.set_stage("synth", f"waiting for {current.label.split('/')[-1]} · compiling its Neural Engine program meanwhile", engine="ane")
                log(f"Background: compiling Neural Engine programs for {nxt.label} (bucket {S} x {P})")
                t0 = time.perf_counter()
                ane_runtime.programs_for(model).precompile(S, P)
                log(f"Background: Neural Engine programs for {nxt.label} ready in {time.perf_counter() - t0:.0f} s")
                if nxt.stage == "synth" and not nxt.cancel.is_set():
                    nxt.set_stage("synth", f"waiting for {current.label.split('/')[-1]} · Neural Engine program ready", engine="ane")
                break
        except Exception as exc:
            log(f"Background compile failed: {str(exc).splitlines()[0][:160]}")
        finally:
            WARMING.release()
    threading.Thread(target=warm, daemon=True).start()


def synthesize_item(item, lane):
    from yue2.nar import synthesize
    from yue2.nar_switch import synthesize_switchable
    from yue2.ane import runtime as ane_runtime
    pipe, model = acquire_model()
    if item.plan is None:
        raise ValueError("song has no plan")
    engine = item.engine
    audio_s = len(item.codec) / 25
    switching = lane == "gpu" and engine == "ane"
    log(f"Synthesizing {item.label}: about {audio_s:.0f} s of audio, {item.quality} quality ({item.steps} steps), "
        + ("on the GPU until the Neural Engine is free" if switching else f"engine {engine}"))
    item.set_stage("synth", "preparing", engine="mlx" if switching else engine)
    def on_prepare(done, total):
        item.progress(0.0, f"compiling Neural Engine program {done}/{total}")
        if done in (1, total):
            log(f"Neural Engine program {done}/{total} ready for {item.label}")
    warmed = [False]
    S, P = len(item.codec) + 2, len(item.plan.prefix) + len(item.codec) + 1
    per_step = 2 * flops_per_pass(model.config, S, P)               # midpoint solver: two passes per step
    rate, seen = Rate(), [0]
    def on_nar(done, total):
        if item.used_engine == "ane" and not warmed[0]:
            warmed[0] = True; warm_next(pipe, model, item)
        if seen[0] == 0:
            rate.last = time.perf_counter(); gflops = None            # the first step also carried the prefill/compile: skip it
        else:
            gflops = rate.add((done - seen[0]) * per_step)
        seen[0] = done
        item.progress(done / max(total, 1), f"solver step {done}/{total}", gflops)
    def on_phase(text):
        item.progress(0.0, text)
        if lane == "ane":
            set_lane(ane_gpu=text.startswith("prefilling"))     # a GPU-lane song yields while this runs
    kwargs = dict(steps=item.steps, context=pipe.generation_config.context, cancelled=item.cancel.is_set,
                  on_progress=on_nar, lock=TORCH_LOCK, on_phase=on_phase)
    t0 = time.perf_counter()
    if switching:
        item.used_engine = "mlx"
        # Compile this song's Neural Engine program in the background; the move waits for it.
        bucket = ane_runtime.buckets_for((S, P))
        programs = ane_runtime.programs_for(model)
        ready, failed = threading.Event(), [False]
        if bucket in programs.loaded:
            ready.set()
        else:
            def compile_():
                try:
                    log(f"Background: compiling Neural Engine programs for {item.label} (bucket {bucket[0]} x {bucket[1]})")
                    programs.precompile(*bucket)
                    log(f"Background: Neural Engine programs for {item.label} ready")
                except Exception as exc:
                    failed[0] = True
                    log(f"{item.label} stays on the GPU: the Neural Engine cannot compile its program ({str(exc).splitlines()[0][:100]})")
                finally:
                    ready.set()
            threading.Thread(target=compile_, daemon=True).start()
        def may_switch():
            if getattr(item, "migrated", False):
                return True                                          # already claimed the Neural Engine
            if failed[0] or not ready.is_set() or item.cancel.is_set():
                return False
            with SCHED:
                if LANES["ane"] != "idle":
                    if not LANES["migrate_wanted"]:
                        LANES["migrate_wanted"] = True          # claim the Neural Engine for when it frees
                        item.set_stage("synth", "on the GPU · moves to the Neural Engine when it is free", engine="mlx")
                    return False
                LANES["ane"], LANES["migrate_wanted"] = "migrated", False
                item.migrated = True
                SCHED.notify_all()
                return True
        def on_switch(step):
            log(f"{item.label} moved to the Neural Engine at solver step {step}/{item.steps}")
            item.used_engine = "ane"
            item.set_stage("synth", f"moved to the Neural Engine at step {step}", engine="ane")
            set_lane(gpu_synth=False)                                # the GPU lane may take its next song
        paused = [False]
        def should_wait():
            # Tokenizing and rendering own the GPU: MLX's long kernels would starve them (25x slower
            # token steps measured), so a GPU-lane song sits out until they are done or the Neural
            # Engine takes it.
            busy = LANES["tokens"] or LANES["decode"] or LANES["ane_gpu"]
            if busy != paused[0]:
                paused[0] = busy
                if busy:
                    what = "tokenizing" if LANES["tokens"] else "rendering" if LANES["decode"] else "prefilling for the Neural Engine"
                    log(f"{item.label} pauses: the GPU is {what}")
                    item.set_stage("synth", f"paused · the GPU is busy {what} · resumes or moves to the Neural Engine", engine="mlx")
                else:
                    log(f"{item.label} resumes on the GPU")
                    item.set_stage("synth", "on the GPU · moves to the Neural Engine when it is free", engine="mlx")
            return busy
        item.set_stage("synth", "on the GPU · moves to the Neural Engine when it is free", engine="mlx")
        latents, used, switched_at = synthesize_switchable(model, item.plan.prefix, item.codec, item.seed, may_switch=may_switch,
                                                           on_switch=on_switch, on_prepare=on_prepare, should_wait=should_wait, **kwargs)
        item.used_engine = "mlx+ane" if switched_at is not None else "mlx"
    else:
        item.used_engine = engine
        try:
            latents = synthesize(model, item.plan.prefix, item.codec, item.seed, engine=engine, on_prepare=on_prepare,
                                 offload_ar=pipe.offload_ar, **kwargs)
        except RuntimeError as exc:
            # The Neural Engine compiler rejects some very large shapes; the song is not lost.
            if engine != "ane" or not recoverable_ane_error(exc):
                raise
            log(f"The Neural Engine could not render this song ({str(exc).splitlines()[0][:160]}); "
                f"synthesizing it on the GPU with MLX instead")
            # Release failed ANE programs/surfaces before allocating the GPU fallback.
            with MODEL_LOCK:
                with TORCH_LOCK:
                    release()
            item.used_engine = "mlx"; item.set_stage("synth", "preparing", engine="mlx"); t0 = time.perf_counter()
            latents = synthesize(model, item.plan.prefix, item.codec, item.seed, engine="mlx", offload_ar=pipe.offload_ar, **kwargs)
    item.latents = latents.detach().float().cpu().numpy()
    item.nar_seconds = time.perf_counter() - t0
    log(f"Synthesis of {item.label} done in {item.nar_seconds:.0f} s ({item.nar_seconds / audio_s:.1f} s per second of audio, "
        f"{item.steps} steps, {item.used_engine})")


def decode_stage():
    while True:
        item = PIPELINE.decode.get()
        if item.cancel.is_set():
            PIPELINE.finish(item, "cancelled", "stopped"); continue
        with stage_lock():
            set_lane(decode=True)
            try:
                decode_item(item)
                PIPELINE.finish(item, "ready")
            except InterruptedError:
                PIPELINE.finish(item, "cancelled", "stopped")
            except Exception as exc:
                traceback.print_exc(file=sys.stderr)
                log(f"Decoding failed for {item.label}: {type(exc).__name__}: {exc}")
                emit(event="failed", path=item.path, message=f"{type(exc).__name__}: {exc}")
                PIPELINE.finish(item, "failed", str(exc)[:200])
            finally:
                item.latents = None
                set_lane(decode=False)


def decode_item(item):
    from yue2.pipeline import SemanticResult, SongResult
    from yue2.storage import identity
    pipe, _ = acquire_model()
    item.set_stage("decode", "decoding waveform", engine=item.used_engine)
    item.progress(0.5, "decoding waveform")
    t1 = time.perf_counter()
    rate, seen = Rate(), [0]
    rate.add(0)
    def on_tile(done, total):
        gflops = rate.add((done - seen[0]) * pipe.vae_core_frames * VAE_GFLOP_PER_FRAME * 1e9); seen[0] = done
        item.progress(done / max(total, 1), f"decoding tile {done}/{total}", gflops)
        if item.cancel.is_set():
            raise InterruptedError("stopped")
        TORCH_LOCK.yield_turn()                  # let a waiting token step or prefill in between tiles
    with TORCH_LOCK:
        audio = pipe.decode(item.latents, on_progress=on_tile)
    if item.cancel.is_set():
        raise InterruptedError("stopped")
    plan = item.plan
    config = pipe.effective_config(plan.request)
    config.update({"execution": "eager_batched", "nar_engine": item.used_engine, "ode_steps": item.steps, "quality": item.quality})
    semantic = SemanticResult(plan, item.codec, item.semantic_timing or {}, item.truncated)
    song = SongResult(audio, 48000, semantic, item.latents, config, pipe.weights,
                      {"semantic": item.semantic_timing or {}, "nar_seconds": item.nar_seconds, "vae_seconds": time.perf_counter() - t1},
                      identity({"request": plan.request.to_dict(), "config": config, "weights": pipe.weights}))
    directory = item.directory
    result = save_render(song, directory, item.quality, item.steps, item.used_engine)
    length = len(audio) / 48000
    log(f"Saved {directory / 'audio.flac'} ({length:.1f} s, {item.quality})")
    emit(event="song", index=item.index, path=item.path, score=plan.abc or "", seconds=round(length, 1), seed=item.seed,
         truncated=bool(item.truncated or plan.truncated), quality=item.quality, steps=item.steps, engine=item.used_engine)


# ── Requests ─────────────────────────────────────────────────────────────────

def steps_for(quality, req):
    if quality == "draft":
        return max(1, min(int(req.get("draft_steps", 8)), 32))
    from yue2.protocol import GenerationConfig
    return (PIPE.generation_config if PIPE is not None else GenerationConfig()).ode_steps


def submit_generate(req):
    from yue2.protocol import SongRequest
    from yue2.storage import write_json
    n = int(req.get("batch", 1)); mode = req.get("cot", "full")
    style, lyrics = req["style"].strip(), req["lyrics"].strip()
    if req.get("instrumental"):
        from yue2.instrumental import instrumental_tags, structure_only
        style, lyrics = instrumental_tags(style), structure_only(lyrics)
        if mode == "off":
            mode = "full"                      # the vocal voice can only be silenced in a planned score
    quality = "draft" if req.get("quality", "draft") == "draft" else "full"
    base = int(time.time()) % 10_000_000 if req.get("random_seed") else int(req.get("seed", 831001))
    seeds = [base + i for i in range(n)]
    abc = (req.get("abc") or "").strip() or None
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    out_root = OUTPUT_DIR / stamp
    with PIPELINE.lock:
        taken = {it.directory.parent for it in PIPELINE.live.values()}
    while out_root in taken or out_root.exists():                                      # two jobs in one second
        stamp += "b"; out_root = OUTPUT_DIR / stamp
    steps = steps_for(quality, req)
    items = []
    for i, seed in enumerate(seeds):
        request = SongRequest(style=style, lyrics=lyrics, cot=mode, seed=seed, abc=abc,
                              id=f"song{i + 1}", **({"cfg_scale": 1.0} if mode == "off" else {}))
        items.append(Item(None, i + 1, seed, request, out_root / f"song{i + 1}", quality, steps, req.get("engine", "auto")))
    job = Job(stamp, dict(req, cot=mode), items)
    for it in items:
        it.job = job
        it.directory.mkdir(parents=True, exist_ok=True)
        write_json(it.directory / "studio-job.json", req)
        write_json(it.directory / "studio.json", {"title": req.get("title", "Untitled song"), "created": dt.datetime.now().isoformat()})
    PIPELINE.add(items)
    emit(event="started", job=stamp, output=str(out_root), songs=[{"index": it.index, "seed": it.seed, "path": it.path} for it in items])
    for it in items:
        it.set_stage("queued", "waiting for the GPU")
    log(f"Queued {stamp}: {n} song(s), {quality} quality ({steps} steps), seeds {seeds}" + (", instrumental" if req.get("instrumental") else ""))
    PIPELINE.jobs.put(job)


def submit_render(req):
    """Synthesize a song from its saved tokens: a full-quality render of a draft, or a song whose
    tokens were saved but never synthesized. Same tokens, seed and noise."""
    import numpy as np
    from yue2.pipeline import SymbolicPlan
    directory = song_directory(req["path"])
    if str(directory / "audio.flac") in PIPELINE.live:
        emit(event="error", message=f"{directory.name} is already queued"); return
    quality = "draft" if req.get("quality", "full") == "draft" else "full"
    plan = SymbolicPlan.load(directory)
    codec = np.load(directory / "semantic.npy", allow_pickle=False).astype(int).tolist()
    previous = {}
    for name in ("result.json", "tokens.json"):
        if (directory / name).exists():
            previous = json.loads((directory / name).read_text()); break
    truncated = previous.get("truncated")
    truncated = bool(truncated.get("semantic", False) if isinstance(truncated, dict) else truncated)
    index = int(directory.name[4:]) if directory.name.startswith("song") and directory.name[4:].isdigit() else 1
    item = Item(None, index, plan.request.seed, plan.request, directory, quality, steps_for(quality, req), req.get("engine", "auto"))
    item.plan, item.codec, item.truncated = plan, codec, truncated
    item.semantic_timing = previous.get("timing", {}) if "tokens.json" in previous else {}
    with MODEL_LOCK:
        item.engine = choose_engine(item.engine, pipeline(), len(codec), quality)
    PIPELINE.add([item])
    emit(event="started", job=directory.parent.name, output=str(directory.parent), songs=[{"index": index, "seed": item.seed, "path": item.path}])
    log(f"Queued {item.label} for {quality} synthesis ({item.steps} steps, engine {item.engine}): about {len(codec) / 25:.0f} s of audio")
    item.set_stage("synth", "waiting", engine=item.engine)
    PIPELINE.synth.put(item)


def submit(req):
    try:
        (submit_render if req.get("cmd") == "render" else submit_generate)(req)
    except Exception as exc:
        traceback.print_exc(file=sys.stderr)
        log(f"Error: {type(exc).__name__}: {exc}"); emit(event="error", message=f"{type(exc).__name__}: {exc}")


# ── Memory ───────────────────────────────────────────────────────────────────

def footprint_mb():
    """Physical footprint of this process (macOS), or None."""
    try:
        import subprocess
        out = subprocess.run(["/usr/bin/footprint", "-p", str(os.getpid())], capture_output=True, text=True, timeout=10).stdout
        for line in out.splitlines():
            if "phys_footprint:" in line:
                value, unit = line.split()[1:3]
                return float(value) * {"KB": 1 / 1024, "MB": 1, "GB": 1024}.get(unit, 1)
    except Exception:
        return None


def release(deep=False):
    """Free GPU/engine memory held between jobs: MLX weights and cache, ANE weight surfaces and
    program mappings, the VAE and the MPS cache. deep=True also drops the model (lean reload ~1 s)
    and the compiled ANE programs. Call under MODEL_LOCK with the pipeline empty."""
    global PIPE
    import gc, torch
    before = footprint_mb()
    if PIPE is not None and PIPE._model is not None:
        model = PIPE._model
        model._yue2_mlx_weights = None
        programs = getattr(model, "_yue2_ane_programs", None)
        if programs is not None:                 # unmap programs before freeing the surfaces they bind
            with programs.lock:
                for key in list(programs.loaded):
                    for program in programs.loaded[key]:
                        if deep:
                            program.free()
                        elif program.resident:
                            program.unload()
                if deep:
                    programs.loaded.clear()
        weights = getattr(model, "_yue2_ane_weights", None)
        if weights is not None:
            weights.close(); model._yue2_ane_weights = None
        PIPE._vae = None
        if deep:
            PIPE._model = None
        del model, programs, weights             # no local may keep the model alive through the collection below
    try:
        import mlx.core as mx
        (getattr(mx, "clear_cache", None) or mx.metal.clear_cache)()
    except Exception:
        pass
    gc.collect()
    if torch.backends.mps.is_available():
        torch.mps.empty_cache()
    after = footprint_mb()
    if before is not None and after is not None:
        log(f"{'Unloaded the model' if deep else 'Released working memory'}: {before / 1024:.1f} GB -> {after / 1024:.1f} GB")


def idle_watch():
    while True:
        time.sleep(30)
        if PIPE is not None and PIPE._model is not None and time.time() - LAST_ACTIVE[0] > IDLE_UNLOAD_S:
            with MODEL_LOCK:
                if PIPELINE.live or time.time() - LAST_ACTIVE[0] <= IDLE_UNLOAD_S or PIPE._model is None:
                    continue
                with TORCH_LOCK:
                    release(deep=True)


# ── Main loop ────────────────────────────────────────────────────────────────

def main():
    worker_lock = acquire_worker_lock(os.environ.get("YUE_STUDIO_LOCK", str(OUTPUT_DIR / ".worker.lock")))
    emit(event="ready", root=str(ROOT), concurrent=CONCURRENT)
    for target in (tokens_stage, ane_lane, gpu_lane, decode_stage, idle_watch):
        threading.Thread(target=target, name=target.__name__, daemon=True).start()
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            emit(event="error", message="bad json"); continue
        cmd = req.get("cmd")
        if cmd == "ping":
            emit(event="pong")
        elif cmd == "quit":
            PIPELINE.stop(); break
        elif cmd == "unload":
            with MODEL_LOCK:
                if PIPELINE.live:
                    emit(event="error", message="Finish or cancel the current render before freeing memory.")
                else:
                    with TORCH_LOCK:
                        release(deep=True)
                    emit(event="memory_released")
        elif cmd == "stop":
            PIPELINE.stop()
        elif cmd == "cancel":
            item = PIPELINE.live.get(str(Path(req.get("path", "")))) or PIPELINE.live.get(str(Path(req.get("path", "")) / "audio.flac"))
            if item is None:
                emit(event="error", message="not queued")
            else:
                PIPELINE.cancel(item)
        elif cmd in ("generate", "render"):
            threading.Thread(target=submit, args=(req,), daemon=True).start()     # never block the command loop on a model load
        else:
            emit(event="error", message=f"unknown command {cmd}")


if __name__ == "__main__":
    main()
