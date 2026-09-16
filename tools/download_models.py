#!/usr/bin/env python3
"""Download the YuE2 models, printing JSON progress lines: {"bytes": done, "total": total, "rate_mbps": r}.

Uses huggingface_hub's tqdm_class hook so byte counts come from the downloader itself.
"""
import json, os, sys, threading, time
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
os.environ["HF_HUB_DISABLE_XET"] = "1"      # the Xet engine reports no progress until a file completes; plain HTTPS reports per chunk
from huggingface_hub import HfApi, snapshot_download
import importlib
hf_tqdm = importlib.import_module("huggingface_hub.utils.tqdm")   # the package attribute shadows the module

REPOS = ["m-a-p/YuE2-3B", "m-a-p/YuE2-Vae"]
api = HfApi()
total = sum((f.size or 0) for r in REPOS for f in api.model_info(r, files_metadata=True).siblings)
state = {"bars": {}, "last": 0.0, "samples": []}
lock = threading.Lock()


def report(force=False):
    now = time.time()
    if not force and now - state["last"] < 0.5:
        return
    state["last"] = now
    done = sum(state["bars"].values())
    state["samples"].append((now, done))
    state["samples"] = [s for s in state["samples"] if now - s[0] <= 15]
    rate = 0.0
    if len(state["samples"]) > 1 and now - state["samples"][0][0] >= 2:
        rate = (done - state["samples"][0][1]) / (now - state["samples"][0][0]) / 1e6
    print(json.dumps({"bytes": done, "total": total, "rate_mbps": round(rate, 1)}), flush=True)


class Progress(hf_tqdm.tqdm):
    """Silent tqdm that accumulates byte progress across all files.

    huggingface_hub builds its per-file byte bars from its own ``utils.tqdm.tqdm``
    (``tqdm_class`` only reaches the outer file counter), so that class is replaced.
    """
    def __init__(self, *args, **kwargs):
        kwargs["disable"] = True
        super().__init__(*args, **kwargs)
        self._bytes = kwargs.get("unit") == "B"
        self._count = kwargs.get("initial", 0) or 0
        if self._bytes:
            with lock:
                state["bars"][id(self)] = self._count

    def update(self, n=1):
        if self._bytes:
            self._count += n
            with lock:
                state["bars"][id(self)] = self._count
                report()
        return super().update(n)


hf_tqdm.tqdm = Progress
print(json.dumps({"bytes": 0, "total": total, "rate_mbps": 0.0}), flush=True)
for repo in REPOS:
    snapshot_download(repo, max_workers=16)
with lock:
    report(force=True)
print(json.dumps({"done": True, "total": total}), flush=True)
