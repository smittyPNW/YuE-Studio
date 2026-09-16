# Optional mastering integration

**ReSoul’s engine remains private.** This repository publishes the native interface and the process-level JSON contract only. It does not contain ReSoul’s DSP, Smart Master policy, repair values, 43-style catalog, JUCE build, or a redistributable ReSoul binary. No public engine download is promised.

The screenshots show a working private integration. The default public build displays a clear missing-engine screen and continues to offer song creation independently.

## Authorized integration package

A provider-supplied directory must contain:

```text
ReSoulMaster             executable native helper
ReSoulCatalog.json      provider's presets and repair patches
licenses/               all required engine and dependency notices
```

Build locally with `RESOUL_ENGINE_DIR=/path/to/authorized/package bash custom/package-local.sh`. This is a local integration mechanism, not permission to redistribute the engine. Never commit that directory, a resulting private bundle, or its catalog to this public repository.

## Invocation and input

The app invokes `ReSoulMaster /absolute/path/request.json`. One process handles one operation and exits. Request fields:

| Field | Contract |
| --- | --- |
| `command` | `analyze`, `smart`, or `render` |
| `input` | Absolute path to the session's private source copy |
| `output` | New, nonexistent destination WAV path |
| `lock` | Shared generation/mastering lock path |
| `parameters` | Codable `MasterParameters` from the public Swift interface |
| `presetName`, `title`, `artist` | Display/export metadata |

See `app/YuEStudio/Sources/YuEStudio/MasteringModels.swift` for the public typed fields. Defaults define an interface state; they do not implement processing.

## Output protocol

Standard output is newline-delimited JSON. Standard error is diagnostic text. Flush progress promptly.

```json
{"event":"progress","fraction":0.25,"message":"Analyzing audio"}
```

A successful terminal record has `event: "result"`, `duration` (seconds), `sampleRate` (Hz), `analysis` (`lufs`, `truePeak`, `samplePeak`), and an optional human-readable `message`. Smart Master also returns `parameters`; rendering returns the completed absolute `output` path. Measurements must be finite values. Report `event: "error"` and a message on failure; exit nonzero. Exit zero only after durable successful completion. Examples describe the protocol, not measured engine output.

## Catalog contract

`presets` is an array of `name`, `description`, and complete `parameters` objects. `repairs` is an array of `name` and sparse `patch` objects. Repair identifiers are `Stereo`, `Bass`, `Mid`, and `High`; the interface labels them Fix Stereo, More Bass, Clear Mids, and Smooth Highs. Array patches use string indices; unrelated settings must be preserved. No proprietary catalog is provided here.

## Required behavior

- Acquire an exclusive nonblocking `flock` on the supplied lock **before** loading/processing audio; use the same file as the Python worker.
- Preserve the source and all existing output files; reject destination collisions and source/output identity.
- Validate format, channel count, length, parameters, and finite samples.
- Handle SIGTERM cooperatively; clean only this job's partial output; retain earlier results.
- Deliver the complete offline processing result, not a reduced preview.
- Release resources and lock on all exit paths.

The app first reserves mastering, shuts down its generation worker, and waits for worker exit. The file lock adds process-level exclusion. Any alternative engine must honor both sides of the protocol. Listening-level matching is performed by the player and must not change export bytes.
