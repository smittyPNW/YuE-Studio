# Songwriting companion for YuE Studio

Give an assistant a song idea, a hook, or an existing lyric. The optional [YuE2 Songwriter skill](../skills/yue2-songwriter/SKILL.md) returns a complete lyric and a matching musical direction, ready for Studio's two text fields. It also supports style-only revisions and instrumental briefs.

This is a text-writing companion, not an AI service bundled into the Mac app. It does not download models or generate songs. It complements the upstream [YuE2 Music skill](../skills/yue2-music/SKILL.md), which handles model execution and score-based editing.

## Use with Codex

From this repository's root, copy the skill into your Codex skills directory. This command refuses to replace an existing installed version:

```bash
python3 - <<'PY'
import os
import shutil
from pathlib import Path
source = Path('skills/yue2-songwriter')
destination = Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex'))) / 'skills' / source.name
shutil.copytree(source, destination)
print(f'Installed at {destination}. Start a new Codex session to discover it.')
PY
```

If you already have the skill, compare and back up your version before replacing it. No models or extra Python dependencies are needed for this copy.

Ask, for example:

> Use $yue2-songwriter. Write an allegorical country-metal song about opening a locked town gate. Keep the hook “Leave a light for the stranger.” Give the electric guitar a melodic break after the second chorus.

Copy the response into Studio's songwriter importer, or paste the first block into musical direction and the second into lyrics. Enter the title separately. Import one option at a time. Review the composition before generating. For an entirely instrumental piece, enable Instrumental; leave it off for a vocal song containing a solo.

## Use with another assistant

Provide both [SKILL.md](../skills/yue2-songwriter/SKILL.md) and [the prompting guide](../skills/yue2-songwriter/references/prompting-guide.md) as context, then supply your brief. Assistants without skill discovery can still use the writing instructions. The Markdown files themselves are not fields to paste into YuE Studio.

## What has been validated

This revision was checked against the official request schema and native ABC helper, including E major, E minor, 4/4, 7/8, quarter-note tempo and an eight-bar instrumental passage. Five isolated tests of the app's actual import method passed. It corrects stale app defaults and documents the difference between requested instruments and symbolic melody control. These are source, score and format checks, not an audio-quality benchmark; no songs were rendered. The [validation record and protocol](../skills/yue2-songwriter/references/validation.md) separate completed checks from a future listening comparison.

The companion's instructions are Apache-2.0 licensed; its [license](../skills/yue2-songwriter/LICENSE) travels with the copied folder. It does not change the separate licenses of YuE2 weights or other project components. Credit for the underlying model and original Studio remains in [Credits](../CREDITS.md).
