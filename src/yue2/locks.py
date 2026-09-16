"""A first-come, first-served lock for sharing one PyTorch Metal stream between threads.

PyTorch's MPS backend encodes every thread's kernels into one command buffer, so two threads
running GPU work at the same time trip a Metal assertion. Long GPU loops (token decoding, tiled
VAE decoding) take this lock per step so short pieces of GPU work from other stages (a synthesis
prefill, a tile) interleave with them; a plain ``threading.Lock`` would let the loop re-acquire
before any waiter ran.
"""
from __future__ import annotations
import threading


class FairLock:
    def __init__(self):
        self._cv = threading.Condition()
        self._next, self._serving = 0, 0

    def acquire(self):
        with self._cv:
            ticket = self._next; self._next += 1
            while ticket != self._serving:
                self._cv.wait()

    def release(self):
        with self._cv:
            self._serving += 1
            self._cv.notify_all()

    def __enter__(self):
        self.acquire(); return self

    def __exit__(self, *exc):
        self.release()

    def yield_turn(self):
        """Let waiting threads run before continuing (no-op when nobody waits)."""
        with self._cv:
            waiting = self._next - self._serving > 1
        if waiting:
            self.release(); self.acquire()
