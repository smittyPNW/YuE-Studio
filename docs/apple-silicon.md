# YuE2 on Apple Silicon (unofficial)

The README targets Linux + NVIDIA, but the torch backend runs on Apple Silicon
through PyTorch MPS. Measured on an M4 with 32 GB unified memory.

## Setup

```bash
uv venv --python 3.12 .venv && source .venv/bin/activate
uv pip install -e .
yue2 doctor                      # should report mps_available: true
yue2 generate --request examples/song.json --device mps --output outputs/first-song
```

The example song (20 s of audio) takes about 2.5 minutes: ~14 tokens/s for the
score plan and song tokens, then ~60 s of audio synthesis and a few seconds of
VAE decoding. `examples/generate.py` hard-codes `device="cuda"`; use the CLI or
pass `device="mps"` to `YuE2Pipeline.from_pretrained`.

## Batched decoding

Token generation is memory-bandwidth bound: every step streams ~5.3 GB of
weights for one token. `yue2.batched.generate_tokens_batched` decodes several
requests in one batch so that weight read is shared. Two MPS-specific patches
(`yue2.batched.mps_decode_patches`) are needed for the batch to actually scale:

- PyTorch MPS treats a `[batch, 1, hidden]` input to `nn.Linear` as a batched
  matmul and re-reads the weight once per row. Flattening to 2D fixes it.
- The grouped-query attention fallback copies K/V per row and the masked
  single-query SDPA kernel is slow. A broadcast-matmul attention replaces it.

Measured per-step cost with 200 fixed steps (`tools/bench_batched.py`):

| Songs per batch | ms per step | aggregate tokens/s |
|---|---|---|
| 1 (library loop) | 65 | 14 |
| 1 | 53 | 16 |
| 2 | 52 | 31 |
| 4 | 56 | 48 |
| 8 | 62 | 73 |

Audio synthesis is compute-bound and still runs per song. Seeded outputs from
the batched path are not bit-identical to the single-request loop.

## Web UI

```bash
python tools/yue2_ui.py          # http://127.0.0.1:7860
```

Enter a style and lyrics, pick a planning mode, and set "Songs per run". All
songs in a run share one batched planning pass and one batched token pass, then
are synthesized in turn. Artifacts land in `outputs/ui/<timestamp>/song<N>/`.

## Synthesis attention on MPS

Audio synthesis (the 32-step flow-matching solver) is compute-bound and runs
per song. On MPS the fused `scaled_dot_product_attention` kernel runs long
non-causal attention at under 1 TFLOP/s, three times slower than the dense
matmuls in the same layer. `yue2.nar.attention` therefore defaults to a
`matmul` path on MPS: contiguous `[KV, groups, S, D]` batched matmuls with a
fused bf16 softmax, no K/V head copies. Measured at 6,000 frames x 12,800 keys:
731 ms -> 351 ms per layer (2.1x); at 1,500 x 2,300: 35 -> 18 ms. Outputs match
the fused path to bf16 precision (relative RMS ~0.8%, latent correlation
0.99997 on a full song). Pass `attention="sdpa-legacy"` to `synthesize` for the
original path. The remaining ceiling is the GPU's ~3.2 TFLOP/s dense rate.

## MLX synthesis engine

`yue2.nar.synthesize(engine="mlx")` (the default on Apple Silicon when `mlx` is
installed; `YUE2_NAR_ENGINE=torch` restores PyTorch) keeps the AR prefix
prefill in PyTorch and runs the 64 velocity evaluations in MLX with its fused
attention kernel. The NAR-path weights are converted once per process (2.7 GB
bf16). Measured on a 3 min 51 s song (5,777 frames): legacy 2,643 s, PyTorch
matmul attention 1,533 s, MLX 1,080 s; latents correlate 0.99995 with the
legacy path. Do not run two model-holding processes at once on a 32 GB machine;
the extra 7 GB copy pushes the system into swap and multiplies run times.

## Neural Engine synthesis engine

`yue2.nar.synthesize(engine="ane")` runs the 28 decoder layers of the flow-matching
solver on the Apple Neural Engine through the private in-memory program API
(`src/yue2/ane/libyue2ane.m`, built with clang; no Core ML at run time). One
program per layer per length bucket (S rows in steps of 512, prefix keys P in
steps of 1024) is generated from the real weights by `src/yue2/ane/mil.py`
using coremltools offline, cached under `~/.cache/yue2-ane/`, and compiled on
first use in a process (about 4 s per layer). Attention is key-chunked with a
streaming softmax (1024 x 2048 tiles) and bucket padding is masked with a bias
input. The input embedding and output projection run on the CPU in fp32.
Measured on the 20 s example song: velocity correlation 0.99974 with PyTorch,
latent correlation 0.9999 with the legacy path, 387 ms per pass, 25 s per
solve (PyTorch 47 s, legacy 60 s).

## Native app

`app/YuEStudio` is a SwiftUI macOS app (`swift build -c release`, then run
`.build/release/YuEStudio`). It launches `tools/yue2_worker.py` from the
project's `.venv` as a long-lived worker and exchanges JSON lines with it, so
the model loads once. The log pane shows every stage: model load, score
planning, song tokens, ANE program compilation, solver steps, decoding, and
saved files. Songs play in place and open in Finder. Outputs go to
`outputs/app/<timestamp>/song<N>/`.

Four-minute song (5,777 frames, largest bucket 6144 x 8192): 843 s on the ANE
versus 1,080 s MLX and 2,643 s legacy, latent correlation 0.9996. Two constraints
shaped the runtime: the engine's ~3.5 GiB per-process address window (each
prepared program keeps a working-buffer arena, so layers are grouped two per
program and only a small pool of prefix-key surfaces is mapped), and the
per-process compile cost (~5 ms per MIL op; about 6 minutes for the largest
bucket, 20 s for a 20-second song). `engine="auto"` selects the ANE.

## Memory (16 GB Macs)

Measured with `footprint` on the worker (20 s song, bucket 512 x 2048):

| stage | before | after |
| --- | --- | --- |
| model loaded | 8.4 GB | 5.3 GB |
| end of a 500-token song stage | 9.7 GB (+2.6 MB per token, unbounded) | 5.5 GB |
| ANE programs compiled, synthesizing | ~11.3 GB | 6.7 GB |
| VAE decode | ~12 GB plus a 7 GB CPU copy of the model | 9.4 GB (1024-frame tiles), less with 512 |

Four changes:

- **Lean model** (`yue2/lean.py`, `YuE2Pipeline(lean=True)`, on by default in the
  worker on Apple Silicon): the model is built on the meta device and only the
  AR path is streamed from the safetensors file to the GPU (4.0 GiB instead of
  6.8; load 2 s instead of 7). The NAR-path layer weights are read from the
  checkpoint on demand by the ANE program builder and by the MLX engine
  (`nar_layer_state`), so nothing is lost; only the pure-PyTorch synthesis engine
  needs the full model.
- **Bounded kernel shapes in token decoding** (`BucketedKVCache`): on MPS every
  distinct attended length is a new compiled graph that stays cached for the
  life of the process (about 2.6 MB per token; gigabytes for a long song, and
  the compile cost about 11 ms per step). Views of the static cache are now
  rounded up to 256 slots, with the slack masked. Steps drop from 50 to 39 ms and
  memory no longer grows with the song. Numerically identical apart from bf16
  accumulation order, the same class of noise as changing the batch composition.
- **No CPU round trip around the VAE**: `decode()` no longer parks the LM on the
  CPU on MPS (unified memory; the copy cost 7 GB and a compressor storm). The GPU
  copy of the prefix K/V is released as soon as the ANE solver has it.
- **ANE program memory**: weight blobs are memory-mapped instead of read into
  private memory, the temp copy the framework needs is an APFS clone, and on
  machines under 24 GB only the current bucket's compiled programs are kept
  (`YUE2_ANE_KEEP_BUCKETS`). The worker also picks 512-frame VAE tiles there.

A retained temp directory does not make a later ANE compile faster
(28.8 s vs 26.8 s for the largest program); the per-process compile remains.

## Draft quality and full renders

Synthesis is the expensive stage for long songs, and most of its cost is
independent of whether the song is any good. The app therefore defaults to
**Draft** quality: the score and tokens are generated exactly as before (they
define the song), and synthesis runs 8 midpoint steps on MLX instead of 32. No
Neural Engine compile is involved. Measured on a 20 s song against the 32-step
reference (`tools/bench_draft.py`):

| steps | time | latent corr | rel. RMS error |
| --- | --- | --- | --- |
| 32 | 52 s | 1 | 0 |
| 16 | 40 s | 0.9999 | 0.012 |
| 12 | 28 s | 0.9998 | 0.018 |
| 8 | 18 s | 0.9996 | 0.030 |

Each draft row has **Render full quality**, which re-synthesizes from the saved
tokens with the same seed and noise at 32 steps (worker command `render`),
keeps the preview as `draft.flac`, and replaces `audio.flac`. `result.json`
records `quality`, `ode_steps` and `nar_engine`.

Engine choice per song (`choose_engine` in the worker): drafts use MLX; "auto"
uses the Neural Engine only when the bucket has at most 8192 NAR rows (about
5.4 minutes of audio), because its compiler rejects larger programs (seen at
8704 x 12288 and 9216 x 14336); longer songs use MLX. Compile time grows roughly
with S x (S + P): under a minute for a 20 s song, 6 minutes for 4 minutes of
audio, about 30 minutes for 5 minutes, and the ANE solve is only ~1.3x faster
than MLX at that length, so a single long song is faster on MLX end to end.

## One program per bucket (weights as inputs)

The compiler used to be run 14 times per bucket, once per pair of layers,
because each program had its layers' 100 MB of weights baked in as constants.
Since all 28 layers have the same shape, the program now takes the weights as
inputs (`build_program(..., weights_as_inputs=True)`, MIL v6): one compile per
bucket, and the 28 layers run as 14 calls of the same program with each layer's
weight surfaces bound by name (`WeightSurfaces`, created once per process,
~2.8 GB of fp16 IOSurfaces; `YUE2_ANE_WEIGHT_POOL=n` keeps only n layers'
surfaces and rewrites them per call).

| bucket | compile before | compile now | pass before | pass now | output |
| --- | --- | --- | --- | --- | --- |
| 512 x 2048 (20 s) | 14 x 1.8 s | 0.9 s | 27 ms / 2 layers | 32 ms | identical |
| 6144 x 8192 (4 min) | 14 x 25 s = 354 s | 25 s | 871 ms / 2 layers | 902 ms | identical |

The ANE compiler itself cannot be parallelised: threads and even separate
processes all queue on one single-threaded `ANECompilerService`.

**Song-length ceiling (MIL v7).** The compiler refused any bucket above 8192
frames. Probing one op at a time showed the per-head RMSNorm (`q_norm`,
`k_norm`, a reduce over `[.., S, 128]`) as the only op that fails past 8192
rows, in any layout. It is now computed in the flat `[1,1,S,H*128]` layout
with two small constant matmuls (block sums, then spread back; block *sums*,
not means, so the products stay out of fp16's subnormal range). The query heads
of a K/V group also moved from a stacked `2S` row axis to the batch axis. With
that, 8704 x 12288, 9216 x 14336, 12288 x 4096 and 8192 x 18432 all compile;
12288 x 14336 still does not, so the worker tries the ANE up to 12288 frames and
falls back to MLX on a refusal. Accuracy is unchanged (velocity 0.9997 on the
20 s song, 0.9995 on the 4-minute song; latents 0.9999); the batch-axis layout
roughly doubles the op count, so the 4-minute bucket compiles in ~47 s.

**Pipelined worker.** `tools/yue2_worker.py` runs three stages on their own
threads behind a queue: tokens (GPU: score and song tokens, all songs of a job in
one batch), synthesis (Neural Engine at full quality, GPU/MLX for drafts) and
decode (GPU: VAE). They overlap: the GPU generates the next job's tokens while
the Neural Engine solves this one, and latents are decoded as they arrive.
PyTorch's Metal backend cannot be driven from two threads at once (it encodes
into one command buffer and asserts), so every PyTorch GPU section takes turns
on `locks.FairLock`: each token step, the synthesis prefill and weight copies,
each decode tile. The Neural Engine and MLX solvers run outside the lock, which
is where the overlap comes from; a `threading.Lock` would let the token loop
starve the others. Below 24 GB the stages run one at a time (`YUE2_PIPELINE=1`
overrides). Songs enter the queue with a `started` event and report `stage`
(`queued`, `planning`, `tokens`, `synth`, `decode`, `ready`, `failed`, `cancelled`) and
per-song `progress`; `idle` fires when the last queued song finishes. Tokens are
written to the song folder (`semantic.npy`, plan files, `tokens.json`) as soon
as they exist, so a song whose synthesis never ran can be synthesized later with
the `render` command (the app lists such songs as "tokens only").

**Early release from the token batch.** All songs of a job are tokenized in one
batch (one or two rows cost the same per step), but a row that emits its end
token is handed to synthesis at once (`generate_tokens_batched(on_row_done=...)`)
while the batch continues for the longer songs, so the first song of a pair is
already on the Neural Engine while the second is still tokenizing.

**Two synthesis lanes.** The synthesis queue feeds a Neural Engine lane (full-quality
songs) and a GPU lane (drafts, songs the Neural Engine cannot compile). When the
GPU has nothing else to do (no tokenizing, no rendering, nothing queued for them)
the GPU lane also takes the next full-quality song that would otherwise wait: it
starts on MLX while its Neural Engine program compiles in the background, and
moves to the Neural Engine at the next step boundary once that is free
(`nar_switch.synthesize_switchable`: same noise and schedule, the state is
handed over, the prefix K/V cache stays on the GPU until the Neural Engine solver
is built from it). The Neural Engine lane waits for a claimed hand-off rather
than starting another song, so the GPU is freed for rendering. While still on
the GPU the song pauses between steps whenever tokenizing or rendering starts
(MLX's long kernels starve the token loop: 25x slower steps measured), resuming
when they finish or moving to the Neural Engine if it frees up meanwhile. Such
a song is recorded with `nar_engine: mlx+ane`.

**Instrumental songs.** Tags alone ("instrumental, no vocals") do not stop the
singer: the token model follows the planned score, which has a Vocal voice. The
app's "Instrumental (no vocals)" switch (worker `instrumental: true`) adds the
no-vocal tags, keeps only the section markers of the lyrics, plans the score as
usual and then re-plans from that score with every Vocal bar replaced by rests
(`yue2.instrumental.silence_vocals`, chords kept), so the tokens carry no sung
melody. Planning is forced on for it. Verified by ear on a 30 s draft.

**Memory between jobs.** When the queue drains the worker releases its
working memory (MLX weights and cache, ANE weight surfaces and program
mappings, the VAE, the MPS cache): about 11 GB -> 5 GB resident with the lean
model kept. After `YUE2_IDLE_UNLOAD_S` (default 600 s) idle it drops the model
too (-> 0.6 GB); the next job reloads it in about a second. Compiled ANE
programs survive the first level (they hold no weights now) and are freed by
the second.
