"""Synthesis that starts on the GPU (MLX) and moves to the Neural Engine mid-trajectory.

Both engines integrate the same midpoint schedule from the same noise, and each step only needs
the current state, so a song can run its first steps on the GPU while the Neural Engine is busy
with another song and finish on the Neural Engine once it is free. The prefix K/V cache from the
PyTorch prefill is kept on the GPU until the Neural Engine solver is built from it.
"""
from __future__ import annotations
from contextlib import nullcontext
import time
import numpy as np
import torch

from .nar import CachedNAR, song_chunks
from .protocol import CONTEXT


def _logit(t):
    return float(torch.logit(torch.tensor(t, dtype=torch.float64)).clamp(-20, 20))


def synthesize_switchable(model, prefix, codec, seed, *, steps=32, context=CONTEXT, lock=None, cancelled=None,
                          on_progress=None, may_switch=None, on_switch=None, on_prepare=None, on_phase=None,
                          should_wait=None):
    """Return (latents, engine, switched_at_step).

    Solves on MLX; before each step, if ``may_switch()`` returns True, builds the Neural Engine
    solver for the current chunk and continues there (later chunks of the same song start on the
    Neural Engine directly). While still on MLX, ``should_wait()`` true pauses between steps (the GPU
    is wanted elsewhere), re-checking ``may_switch`` meanwhile. ``lock`` guards PyTorch device work
    as in ``nar.synthesize``.
    """
    from . import nar_mlx
    from .ane import runtime as ane_runtime
    import mlx.core as mx
    lock = nullcontext() if lock is None else lock
    phase = on_phase if on_phase is not None else (lambda text: None)
    with lock:
        weights = nar_mlx.weights_for(model)
    to_torch_dtype = torch.float32 if weights.dtype == mx.float32 else torch.bfloat16

    def velocity(solver, kind, state, raw):
        if kind == "ane":
            return solver.velocity(state, raw)
        v = solver.velocity(nar_mlx._to_mx(state.to(to_torch_dtype)), raw)
        mx.eval(v)
        return torch.from_numpy(np.array(v.astype(mx.float32)))

    chunks = song_chunks(prefix, codec, seed, context)
    output, used, switched_at = [], "mlx", None
    dt = 1.0 / steps
    for ci, chunk in enumerate(chunks):
        if cancelled is not None and cancelled():
            raise InterruptedError("Cancelled before acoustic prefill")
        phase("prefilling the prefix on the GPU")
        with lock:
            engine = CachedNAR(model, chunk)
        phase("solver step 1 running")
        solver, kind = None, None
        try:
            state = chunk.noise.to(torch.float32).clone()
            for step in range(steps):
                if cancelled is not None and cancelled():
                    raise InterruptedError("Cancelled during acoustic flow matching")
                switch = used == "ane"
                while kind != "ane" and not switch:
                    switch = may_switch is not None and may_switch()
                    if switch or should_wait is None or not should_wait():
                        break                                        # step now (here, or on the Neural Engine)
                    if cancelled is not None and cancelled():
                        raise InterruptedError("Cancelled during acoustic flow matching")
                    time.sleep(0.5)                                  # the GPU is wanted elsewhere
                if kind != "ane" and switch:
                    S, P = ane_runtime.buckets_for(engine)
                    ane_runtime.programs_for(model).ensure(S, P, on_progress=on_prepare)   # compiled already, normally
                    with lock:
                        ane = ane_runtime.ANEVelocity(engine, model)                        # takes the prefix K/V to host
                    solver, kind, used = ane, "ane", "ane"
                    if switched_at is None:
                        switched_at = ci * steps + step
                        if on_switch is not None:
                            on_switch(switched_at)
                if solver is None:
                    with lock:
                        solver = nar_mlx.MLXVelocity(engine, weights)
                    kind = "mlx"
                t = 1.0 - step * dt
                first = velocity(solver, kind, state, _logit(t))
                mid = state - first * (dt / 2)
                state = state - velocity(solver, kind, mid, _logit(t - dt / 2)) * dt
                if on_progress is not None:
                    on_progress(ci * steps + step + 1, steps * len(chunks))
            if not torch.isfinite(state).all():
                raise FloatingPointError("Acoustic flow matching produced non-finite latents")
            output.append(state)
        finally:
            if kind == "ane" and solver is not None:
                solver.close()
            solver = None
            with lock:
                engine.close()
    return torch.cat(output, dim=0), used, switched_at
