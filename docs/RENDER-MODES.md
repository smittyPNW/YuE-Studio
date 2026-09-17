# Render modes and performance

Full quality is the default, including when loading a workspace saved before 0.5.1. It keeps the existing model precision, full score planning, 32-step synthesis, Apple MLX engine and 48 kHz lossless stereo delivery.

Choose **Draft preview** explicitly for an 8-step synthesis pass. Planning and song-token generation are still full; the sound can be less refined. Draft does not shorten your lyrics, lower the duration ceiling, quantize weights or compress the delivery file.

For an existing draft, **Finish at full quality** uses its saved score, song tokens and original seed. It skips planning and token generation and runs the complete 32-step synthesis. Edited prompt fields apply only to a new generation. The original draft is kept for comparison, with its metadata and a version backup. A failed synthesis does not replace the previous audio.

## What changed for speed

Already-installed models load from the local cache without a network freshness check on every new worker. Missing files still trigger the normal download; corruption and other model errors are reported rather than silently retried. Model precision, synthesis settings and integrity validation are unchanged.

The worker requests user-initiated scheduling. While generation is queued or active, Studio holds a macOS activity assertion against App Nap and automatic system sleep; it releases it after the queue drains or a job fails. This helps background rendering continue normally. It does not make the neural network itself cheaper, override explicit Sleep or keep the display lit. Generation, editing and mastering still share one heavy-job gate.

Existing saved five-minute recordings on an M4 Pro with 24 GB show roughly three minutes of song-token generation and ten minutes of acoustic synthesis, plus planning and waveform decoding. These are observed recordings, not universal estimates. Long songs still take time at full quality.

## Measured check on the M4 Pro

A private 12-second excerpt of saved song tokens was rendered through the 0.5.0 worker, then through the updated worker in Draft and Full modes. The source recording was not modified and no new composition was generated.

| Pass | Synthesis | Decode | Request through idle |
| --- | ---: | ---: | ---: |
| Previous Full, 32 steps | 23.19 s | 1.15 s | 30.97 s |
| Updated Draft, 8 steps | 10.85 s | 1.10 s | 19.25 s |
| Updated Full, 32 steps | 23.79 s | 1.11 s | 25.17 s |

The final Full audio FLAC and latent array were byte-identical to the previous worker's output. The 8-step draft remained available after upgrading. All source hashes were unchanged. This is a bounded regression check, not a benchmark across songs or a subjective evaluation of Draft sound quality.

The Full synthesis times were essentially unchanged. End-to-end timings differ with model loading and warm caches, so the 25.17-second pass is not evidence of a general Full-mode acceleration. Draft synthesis was about 2.1 times faster in this short test; whole-song speedups depend on duration, planning, memory pressure and other work on the Mac.

## Clear without losing a prompt

Each input has its own **Clear** button. **Undo clear** restores that exact field, including Unicode and section labels, until you type replacement text or leave the composition. It is an in-session safeguard, not a permanent history across restarts. Existing song audio, saved requests and the other field are unchanged.
