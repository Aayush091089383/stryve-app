"""Firebase Cloud Messaging delivery for Stryve push notifications.

Why this module exists
----------------------
``flutter_local_notifications`` can only raise an alert while the app is
running: the student's phone has to be open on Home for an assignment to show
up in the tray. Firebase Cloud Messaging lets the backend deliver the same
alert while the app is closed or in the background, so an upload reaches the
student immediately instead of on the next launch.

Design rules (all deliberate)
-----------------------------
* **The credential is never touched unless a push is actually sent.** The
  service-account JSON is loaded on the first call, not at import, so the
  backend (and every test suite) starts without Firebase, without network
  access and without the file.
* **Push is best effort.** Every failure path logs a short line and returns;
  nothing here can fail an upload. A teacher's file must be saved even if
  Google is unreachable or the credential is wrong.
* **No token or credential is ever logged.** Log lines carry counts and error
  class names only - a device token identifies a student, and the JSON holds a
  private key.
* **Unregistered tokens are returned, not raised.** The caller prunes them from
  the database so a reinstall stops costing a failed send on every upload.
"""

from __future__ import annotations

import logging
import threading
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, Mapping, Optional

from config import BACKEND_DIR, settings

logger = logging.getLogger("campussync.push")

# The FCM multicast API accepts at most 500 tokens per request.
_MULTICAST_LIMIT = 500

# Errors that mean "this token will never work again" rather than "try later".
_INVALID_TOKEN_CODES = {
    "messaging/registration-token-not-registered",
    "messaging/invalid-registration-token",
    "messaging/invalid-argument",
}

_app = None
_init_failed = False
_lock = threading.Lock()


@dataclass
class PushResult:
    """Outcome of one multicast send.

    ``invalid_tokens`` are the tokens Google rejected permanently; the caller
    deletes those rows. ``delivered`` counts the devices the message was handed
    to (FCM delivery itself is asynchronous).
    """

    delivered: int = 0
    failed: int = 0
    invalid_tokens: list[str] = field(default_factory=list)


def credentials_path() -> Path:
    """Absolute path of the service-account JSON (see ``settings``)."""
    configured = getattr(settings, "FCM_CREDENTIALS_FILE", "")
    path = Path(configured) if configured else Path("firebase-service-account.json")
    if not path.is_absolute():
        path = BACKEND_DIR / path
    return path


def is_enabled() -> bool:
    """Whether push is switched on *and* a credential file exists.

    Deliberately does not import ``firebase_admin`` - this is what a diagnostic
    or test can ask without touching Firebase.
    """
    return bool(settings.FCM_ENABLED) and credentials_path().is_file()


def reset_for_tests() -> None:
    """Forget the initialised app. Tests that flip settings call this."""
    global _app, _init_failed
    with _lock:
        _app = None
        _init_failed = False


def _ensure_app():
    """Return the Firebase app, initialising it once; ``None`` if unavailable."""
    global _app, _init_failed

    if _app is not None:
        return _app
    if _init_failed or not settings.FCM_ENABLED:
        return None

    with _lock:
        if _app is not None:
            return _app
        if _init_failed:
            return None

        path = credentials_path()
        if not path.is_file():
            # The path is configuration, not a secret; the file's contents and
            # any key material are never printed.
            logger.warning(
                "FCM disabled: service account file not found at %s", path
            )
            _init_failed = True
            return None

        try:
            import firebase_admin
            from firebase_admin import credentials

            try:
                _app = firebase_admin.get_app()
            except ValueError:
                # No default app yet - create it from the operator's file.
                _app = firebase_admin.initialize_app(
                    credentials.Certificate(str(path))
                )
        except Exception as exc:  # ImportError, bad JSON, bad key, ...
            logger.warning(
                "FCM disabled: could not initialise Firebase Admin (%s)",
                type(exc).__name__,
            )
            _init_failed = True
            return None

        logger.info("FCM initialised for push delivery")
        return _app


def send_push_notification(
    tokens: Iterable[str],
    title: str,
    body: str,
    data: Optional[Mapping[str, object]] = None,
) -> PushResult:
    """Send one notification to every token in ``tokens``.

    Never raises: an unconfigured, unreachable or rejected send is logged and
    reported through :class:`PushResult`. Duplicate and empty tokens are
    dropped, and the list is split into 500-token multicasts.
    """
    result = PushResult()

    unique: list[str] = []
    for token in tokens:
        cleaned = (token or "").strip()
        if cleaned and cleaned not in unique:
            unique.append(cleaned)

    if not unique:
        return result

    app = _ensure_app()
    if app is None:
        return result

    try:
        from firebase_admin import exceptions as firebase_exceptions
        from firebase_admin import messaging
    except Exception as exc:
        logger.warning(
            "FCM unavailable: firebase_admin.messaging import failed (%s)",
            type(exc).__name__,
        )
        return result

    payload = {
        str(key): str(value)
        for key, value in (data or {}).items()
        if value is not None
    }

    for start in range(0, len(unique), _MULTICAST_LIMIT):
        chunk = unique[start : start + _MULTICAST_LIMIT]
        try:
            message = messaging.MulticastMessage(
                tokens=chunk,
                notification=messaging.Notification(title=title, body=body),
                data=payload,
                android=messaging.AndroidConfig(
                    priority="high",
                    notification=messaging.AndroidNotification(
                        channel_id=settings.FCM_ANDROID_CHANNEL_ID,
                        sound="default",
                    ),
                ),
            )
            response = messaging.send_each_for_multicast(message, app=app)
        except Exception as exc:
            # A whole-chunk failure (quota, auth, network). Log the class only.
            logger.warning(
                "FCM send failed for a batch (%s)", type(exc).__name__
            )
            result.failed += len(chunk)
            continue

        for token, single in zip(chunk, response.responses):
            if single.success:
                result.delivered += 1
                continue

            result.failed += 1
            error = single.exception
            code = getattr(error, "code", "") or ""
            # A per-token failure can only be about that token, so an
            # InvalidArgumentError here means the string is not a usable FCM
            # token (truncated, reused from another project, ...) and would
            # fail on every future upload too. Chunk-level errors never reach
            # this branch, which is why classifying them as dead is safe.
            if (
                isinstance(error, messaging.UnregisteredError)
                or isinstance(error, firebase_exceptions.InvalidArgumentError)
                or code in _INVALID_TOKEN_CODES
            ):
                result.invalid_tokens.append(token)
            logger.warning(
                "FCM send failed for one device (%s)", type(error).__name__
            )

    logger.info(
        "FCM push: delivered=%s failed=%s stale=%s",
        result.delivered,
        result.failed,
        len(result.invalid_tokens),
    )
    return result
