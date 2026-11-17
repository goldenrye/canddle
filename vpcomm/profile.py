"""Bounded, signed cosmetic profiles. Images are never treated as identity proof."""

from .crypto import decode
from .lobby import transcript, verify

MAX_PHOTO_BYTES = 5120


def validate_profile(message, identity):
    if set(message) != {"type", "identity", "revision", "photo", "signature"}:
        raise ValueError("Invalid profile")
    if message["identity"] != identity or message["type"] != "profile":
        raise ValueError("Wrong profile identity")
    revision = int(message["revision"])
    if not 0 < revision < 1 << 64 or str(revision) != message["revision"]:
        raise ValueError("Invalid profile revision")
    raw = message["photo"]
    if len(raw) > 6827:
        raise ValueError("Photo too large")
    photo = decode(raw, len(raw) * 6 // 8)
    if photo and (
        len(photo) > MAX_PHOTO_BYTES or len(photo) < 4
        or not photo.startswith(b"\xff\xd8") or not photo.endswith(b"\xff\xd9")
    ):
        raise ValueError("Invalid photo envelope")
    verify(identity, message["signature"], transcript(
        "device-profile", identity, message["revision"], raw
    ))
    return revision
