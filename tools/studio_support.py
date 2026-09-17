"""Storage and recovery helpers; no inference changes."""
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import shutil
import uuid


def cached_pipeline(factory, model, *, cache_miss_errors, on_download, **kwargs):
    """Use installed weights immediately; only missing cache files trigger a download.

    Corrupt weights and other runtime errors must remain visible, not cause a
    silent retry or a change of inference settings.
    """
    try:
        return factory(model, local_files_only=True, **kwargs)
    except cache_miss_errors:
        on_download()
        return factory(model, local_files_only=False, **kwargs)


def recoverable_ane_error(error):
    text = str(error)
    return text.startswith('compile') or (text.startswith('evaluate:') and
           ('com.apple.appleneuralengine' in text or 'ANEProgramProcessRequestDirect' in text))


def acquire_worker_lock(path):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    handle = path.open('a+')
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        handle.close()
        raise RuntimeError('Another YuE Studio worker is running. Close the other copy before retrying.')
    handle.seek(0); handle.truncate(); handle.write(str(os.getpid())); handle.flush()
    return handle


def persist_state(directory, stage, detail='', **extra):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    value = dict(stage=stage, detail=detail, updated=dt.datetime.now(dt.timezone.utc).isoformat(), **extra)
    tmp = directory / ('studio-state.' + uuid.uuid4().hex + '.tmp')
    tmp.write_text(json.dumps(value, indent=2))
    os.replace(tmp, directory / 'studio-state.json')


def save_render(song, directory, quality, steps, engine):
    """Stage a complete output first. Keep old audio + provenance before atomic file promotion."""
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    stage = directory / ('.render-' + uuid.uuid4().hex)
    stage.mkdir()
    try:
        result = song.save_artifacts(stage)
        result.update(quality=quality, ode_steps=steps, nar_engine=engine)
        (stage / 'result.json').write_text(json.dumps(result, indent=2))
        old = directory / 'audio.flac'
        if old.exists():
            version = directory / 'versions' / (dt.datetime.now().strftime('%Y%m%d-%H%M%S-') + uuid.uuid4().hex[:6])
            version.mkdir(parents=True)
            for name in ('audio.flac', 'result.json', 'config.json', 'latent.npy', 'request.json', 'score.abc', 'plan.json', 'plan_manifest.json', 'semantic.npy', 'prefix.npy', 'abc_tokens.npy', 'tokens.json'):
                src = directory / name
                if src.exists(): shutil.copy2(src, version / name)
            previous = json.loads((directory / 'result.json').read_text()) if (directory / 'result.json').exists() else {}
            if quality == 'full' and previous.get('quality') == 'draft' and not (directory / 'draft.flac').exists():
                shutil.copy2(old, directory / 'draft.flac')
                shutil.copy2(directory / 'result.json', directory / 'draft-result.json')
        # The result manifest is the final commit marker. Audio is never written in place.
        for src in stage.iterdir():
            if src.name != 'result.json': os.replace(src, directory / src.name)
        os.replace(stage / 'result.json', directory / 'result.json')
        return result
    finally:
        shutil.rmtree(stage, ignore_errors=True)


def song_directory(path):
    path = Path(path)
    return path.parent if (path.is_file() or (not path.is_dir() and path.suffix.lower() in {'.flac', '.wav'})) else path
