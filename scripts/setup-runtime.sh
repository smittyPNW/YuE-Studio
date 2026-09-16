#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUPPORT="$HOME/Library/Application Support/YuE Studio"
if [[ "$(uname -m)" != arm64 || "$(uname -s)" != Darwin ]]; then
  echo "This desktop setup requires an Apple Silicon Mac." >&2; exit 1
fi
command -v uv >/dev/null || { echo "Install uv first: brew install uv" >&2; exit 1; }
if [[ -e "$SUPPORT/env" ]]; then
  echo "An existing YuE runtime is present. It has not been modified."
  echo "Use it as-is, or back it up and move it aside before rerunning setup."
  exit 0
fi
mkdir -p "$SUPPORT" "$HOME/Music/YuE Studio"
export HF_HOME="$SUPPORT/models"
export HF_HUB_DISABLE_TELEMETRY=1
export UV_PYTHON_INSTALL_DIR="$SUPPORT/python"
echo "Installing Python 3.12 and dependencies; model download follows (several GB)."
uv python install 3.12
uv venv "$SUPPORT/env" --python 3.12
# An editable install keeps the verified source checkout as the runtime source.
uv pip install --python "$SUPPORT/env/bin/python" -e "$ROOT[apple]"
"$SUPPORT/env/bin/python" "$ROOT/tools/download_models.py"
echo "Runtime ready. Keep this source checkout in place. Build with: bash custom/package-local.sh"
