#!/usr/bin/env python3
"""The browser glue compiler follows the application's locked library version."""
from pathlib import Path
import tomllib

container = Path(__file__).resolve().parent.parent
manifest = container / "rooms-Cargo.lock"
if not manifest.is_file():
    manifest = container.parent / "apps/rooms/rust/Cargo.lock"
with manifest.open("rb") as source:
    versions = {
        package["version"]
        for package in tomllib.load(source)["package"]
        if package["name"] == "wasm-bindgen"
    }
if len(versions) != 1:
    raise SystemExit("Rooms needs exactly one locked wasm-bindgen version")
print(versions.pop())
