"""
envload.py -- read .env into the environment.

Imported first by worker.py and server.py so that `edgar` and `store` see
their configuration when they read it at import time. Real environment
variables always win, which is what makes Render's settings override a
stray local .env.

No dependency on python-dotenv; the file format we need is three lines long.
"""

from __future__ import annotations

import os
import pathlib

_HERE = pathlib.Path(__file__).resolve().parent


def load(filename: str = ".env") -> bool:
    path = _HERE / filename
    if not path.exists():
        return False
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key and value:
            os.environ.setdefault(key, value)
    return True


load()
