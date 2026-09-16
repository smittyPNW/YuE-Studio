# Build and run

## Requirements

- Apple Silicon Mac running macOS 14 or later.
- Xcode command-line tools (`xcode-select --install`) and Swift 5.9 or newer.
- `uv` for generation setup (`brew install uv` if you use Homebrew).
- Internet for dependency/model installation; enough disk for the several-GB model cache, runtime, build products, and song artifacts.
- This edition was exercised on an M4 Pro with 24 GB memory. Runtime and song length affect resource needs.

## Generation runtime

Run `bash scripts/setup-runtime.sh` from the repository root. It installs a Python 3.12 environment under `~/Library/Application Support/YuE Studio/env` and downloads the upstream YuE2 generation/listening models to the corresponding `models` folder. Read `MODEL_LICENSE` before using those weights.

An existing environment is not replaced. The script will say so and exit. Do not remove or repair a working runtime while the app is generating. Because the source is installed in editable mode, retain this checkout at the same location. Moving it requires reinstalling the package into the environment after all jobs finish.

If setup is interrupted after creating the environment, inspect the error. Rerun the failed dependency/download step with that environment, or move the incomplete environment aside before rerunning setup. Do not delete existing model caches or song folders as a troubleshooting shortcut.

The optional experimental Neural Engine bridge is not built by this setup script. The public UI defaults to the existing auto engine selection, which uses available engines and can fall back to MLX. No lower-step shortcut is introduced.

## App bundle

```bash
bash custom/package-local.sh
```

Open `custom/dist/YuE Studio.app`. Copy it to Applications only after closing any running copy. If a different edition is installed, preserve that bundle before replacing it. Do not replace a working private-engine edition with the public bundle unless you intend to remove that bundled engine.

The icon is included in the signed bundle. A Finder alias to the installed application will keep the same icon; pin that installed application in the Dock rather than a transient build path.

The package is ad-hoc signed, not notarized. This repository does not provide a one-click notarized download or automatic updater.

## Optional mastering

The default build contains no ReSoul executable or preset catalog. Master displays an informational screen until an authorized engine is supplied. See `mastering/README.md`. Generation setup is not required for an independently supplied mastering engine.

## Tests

```bash
swift test --package-path app/YuEStudio
python3 -m unittest discover -s custom/Tests -v
python3 scripts/check-public-tree.py
```

These interface/export/recovery checks do not download model weights or create songs. The full upstream model test suite requires its separate dependencies and resources.
