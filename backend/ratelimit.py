"""
Minimal in-process rate limiting.

No external service and no new dependency: the backend is a single-process
FastAPI app, and this only has to slow down bulk scraping of an
unauthenticated endpoint. State lives in memory, so it resets on restart and
is per-process (see SECURITY.md for the limits of that).

Only the public roll-number lookup uses it today.
"""

from __future__ import annotations

import threading
import time
from collections import deque
from typing import Deque, Dict, Optional, Tuple


class SlidingWindowLimiter:
    """Allow at most ``limit`` hits per ``window_seconds`` per key."""

    def __init__(
        self,
        limit: int,
        window_seconds: float = 60.0,
        max_keys: int = 4096,
    ) -> None:
        self._limit = max(0, int(limit))
        self._window = float(window_seconds)
        self._max_keys = max(1, int(max_keys))
        self._hits: Dict[str, Deque[float]] = {}
        self._lock = threading.Lock()

    @property
    def limit(self) -> int:
        """Configured limit; 0 means the limiter is disabled."""
        return self._limit

    def check(self, key: str, now: Optional[float] = None) -> Tuple[bool, int]:
        """Record one hit for ``key``.

        Returns ``(allowed, retry_after_seconds)``. ``retry_after`` is 0 when
        the hit was allowed.
        """
        if self._limit <= 0:
            return True, 0

        current = time.monotonic() if now is None else now

        with self._lock:
            hits = self._hits.get(key)
            if hits is None:
                hits = deque()
                self._hits[key] = hits

            cutoff = current - self._window
            while hits and hits[0] <= cutoff:
                hits.popleft()

            if len(hits) >= self._limit:
                retry_after = int(self._window - (current - hits[0])) + 1
                return False, max(1, retry_after)

            hits.append(current)
            if len(self._hits) > self._max_keys:
                self._prune(cutoff)
            return True, 0

    def reset(self, key: Optional[str] = None) -> None:
        """Forget the recorded hits for ``key`` (or for every key)."""
        with self._lock:
            if key is None:
                self._hits.clear()
            else:
                self._hits.pop(key, None)

    def _prune(self, cutoff: float) -> None:
        """Drop keys with no hits inside the window. Caller holds the lock."""
        for stale in [k for k, v in self._hits.items() if not v or v[-1] <= cutoff]:
            del self._hits[stale]
