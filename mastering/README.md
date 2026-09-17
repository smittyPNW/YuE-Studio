# Studio Mastering

A complete local mastering engine, included in this community edition under **AGPL-3.0-only**. It provides full-song analysis, Smart Master recommendations, 43 styles, repair controls and 24-bit WAV rendering. See [license](LICENSE) and [notices](NOTICE.md).

## Build

`bash custom/package-local.sh` at the repository root builds and bundles the engine, catalog and native app. Requires macOS 14+, Apple Silicon, CMake, Ninja and Xcode command-line tools. CMake downloads the pinned JUCE revision. For an existing checkout, pass `JUCE_ROOT=/path/to/JUCE` as an environment variable. No model weights or generation runtime are required for mastering.

For a standalone helper: `cmake -S mastering -B mastering/build -G Ninja -DCMAKE_BUILD_TYPE=Release`, then `cmake --build mastering/build`. The executable is `mastering/build/StudioMasterEngine_artefacts/Release/StudioMasterEngine`; `--catalog` prints the style and quick-repair catalog.

## Invocation and input

The app invokes `StudioMasterEngine /absolute/path/request.json`. One process handles one operation and exits. Request fields:

| Field | Contract |
| --- | --- |
| `command` | `analyze`, `smart`, or `render` |
| `input` | Absolute path to the session's private source copy |
| `output` | New, nonexistent destination WAV path |
| `lock` | Shared generation/mastering lock path |
| `parameters` | Codable `MasterParameters` from the public Swift interface |
| `presetName`, `title`, `artist` | Display/export metadata |

See `app/YuEStudio/Sources/YuEStudio/MasteringModels.swift` for the public typed fields.

## Output protocol

Standard output is newline-delimited JSON. Standard error is diagnostic text. Flush progress promptly.

```json
{"event":"progress","fraction":0.25,"message":"Analyzing audio"}
```

A successful terminal record has `event: "result"`, `duration` (seconds), `sampleRate` (Hz), `analysis` (`lufs`, `truePeak`, `samplePeak`), and an optional human-readable `message`. Smart Master also returns `parameters`; rendering returns the completed absolute `output` path. Measurements must be finite values. Report `event: "error"` and a message on failure; exit nonzero. Exit zero only after durable successful completion. Examples describe the protocol, not measured engine output.

## Catalog contract

`presets` is an array of `name`, `description`, and complete `parameters` objects. `repairs` is an array of `name` and sparse `patch` objects. Repair identifiers are `Stereo`, `Bass`, `Mid`, and `High`; the interface labels them Fix Stereo, More Bass, Clear Mids, and Smooth Highs. Array patches use string indices; unrelated settings must be preserved. The catalog is generated from the included source. HiFi is a non-stacking native parameter recipe; see `docs/HIFI.md`.

## Required behavior

- Acquire an exclusive nonblocking `flock` on the supplied lock **before** loading/processing audio; use the same file as the Python worker.
- Preserve the source and all existing output files; reject destination collisions and source/output identity.
- Validate format, channel count, length, parameters, and finite samples.
- Handle SIGTERM cooperatively; clean only this job's partial output; retain earlier results.
- Deliver the complete offline processing result, not a reduced preview.
- Release resources and lock on all exit paths.

The app first reserves mastering, shuts down its generation worker, and waits for worker exit. The file lock adds process-level exclusion. Any alternative engine must honor both sides of the protocol. Listening-level matching is performed by the player and must not change export bytes.
