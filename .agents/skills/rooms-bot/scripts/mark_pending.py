#!/usr/bin/env python3
"""Merge pending.json message ids into replied.json, then clear pending.

Env:
  BRIDGE_DIR / ROOMS_DIR   harness directory
"""
from __future__ import annotations

from lib import atomic_write_text, load_json_list, mark_replied, require_bridge_dir

bridge = require_bridge_dir()
pending_path = bridge / "pending.json"
pending = load_json_list(pending_path)
ids = [mid for m in pending if isinstance(m, dict) and (mid := m.get("id"))]
mark_replied(bridge, ids)
# Clearing pending is load-bearing: an uncleared file keeps the same fingerprint
# and the wake loop stays silent until a new message arrives.
atomic_write_text(pending_path, "[]\n")
print(f"marked {len(ids)} pending answered")
