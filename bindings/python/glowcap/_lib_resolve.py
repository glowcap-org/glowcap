"""Internal: resolve where the glowcap shared libraries live.

Publishable cascade (ADR-0077, see ``c-abi-resolve.json`` and
``bindings/README.md``):

1. ``GLOWCAP_LIB_DIR`` (configure) wins: never downloads.
2. Abi-versioned download cache under ``GLOWCAP_CACHE_DIR`` (default
   ``$XDG_CACHE_HOME/glowcap/c-abi`` or ``~/.cache/glowcap/c-abi``).
3. In-tree ``zig-out/lib`` when a glowcap checkout is discoverable (dev only).
4. Bare library name (OS dynamic-linker search): refused on Windows (DLL
   search-order plant risk). Elsewhere a last resort with a stderr warning.

Download posture (native C-ABI packaging practice): HTTPS-only base URL,
required SHA256SUMS verification before extract, extract only the ``lib/``
prefix with path-traversal rejection, size-capped transfer. When contract
``releases_published`` is false, skip the network attempt unless
``GLOWCAP_DOWNLOAD=1`` (in-tree dogfoods use ``zig-out``). Hygiene failures
(non-HTTPS, checksum miss/mismatch, unsafe/link tar members, extract
refusal) always hard-fail. ``GLOWCAP_STRICT=1`` fail-closes soft paths
(network/tooling). ``GLOWCAP_ALLOW_INSECURE=1`` is the only escape from HTTPS.
"""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import platform
import re
import shutil
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request
from typing import NoReturn


def _lib_file(stem: str) -> str:
    """Platform-specific shared-library filename for an archive stem."""
    return (
        f"lib{stem}.dylib"
        if sys.platform == "darwin"
        else f"{stem}.dll"
        if sys.platform == "win32"
        else f"lib{stem}.so"
    )


def _env_truthy(name: str) -> bool:
    # Fixed set: 1 / true / yes (case-insensitive, trimmed).
    return os.environ.get(name, "").strip().lower() in ("1", "true", "yes")


def _package_dir() -> pathlib.Path:
    return pathlib.Path(__file__).resolve().parent


_CONTRACT: dict | None = None


def _contract() -> dict:
    global _CONTRACT
    if _CONTRACT is None:
        path = _package_dir() / "c-abi-resolve.json"
        with path.open(encoding="utf-8") as f:
            loaded = json.load(f)
        if loaded.get("require_https") is not True:
            raise RuntimeError("c-abi-resolve.json: require_https must be true")
        if loaded.get("require_checksum") is not True:
            raise RuntimeError("c-abi-resolve.json: require_checksum must be true")
        if not isinstance(loaded.get("releases_published"), bool):
            raise RuntimeError("c-abi-resolve.json: releases_published must be a bool")
        _CONTRACT = loaded
    return _CONTRACT


def _want_release_fetch(contract: dict) -> bool:
    """Cold-cache network gate from contract `releases_published`."""
    if contract["releases_published"]:
        return not _env_truthy("GLOWCAP_SKIP_DOWNLOAD")
    return _env_truthy("GLOWCAP_DOWNLOAD")


def _find_dev_root() -> pathlib.Path | None:
    here = _package_dir()
    for candidate in [here, *here.parents]:
        if (candidate / "build.zig").is_file() and (
            candidate / "include" / "glowcap_ocapn.h"
        ).is_file():
            return candidate
    return None


def _abi_version(dev_root: pathlib.Path | None, contract: dict) -> str:
    if dev_root is not None:
        header = dev_root / str(contract["version_header"])
        try:
            text = header.read_text(encoding="utf-8")
        except OSError:
            return str(contract["abi_version"])

        def macro(name: str, default: int) -> int:
            m = re.search(rf"^#define\s+{re.escape(name)}\s+(\d+)\s*$", text, re.M)
            return int(m.group(1)) if m else default

        return (
            f"{macro('GLOWCAP_VERSION_MAJOR', 0)}."
            f"{macro('GLOWCAP_VERSION_MINOR', 1)}."
            f"{macro('GLOWCAP_VERSION_PATCH', 0)}"
        )
    return str(contract["abi_version"])


def _apply_contract_template(
    tmpl: str, *, version: str, target: str, cache_base: str = ""
) -> str:
    return (
        tmpl.replace("{version}", version)
        .replace("{target}", target)
        .replace("{cache_base}", cache_base)
    )


# All host aliases from tools/c-abi/c-abi-host-aliases.json (source_check per-port presence).
_HOST_ALIAS_CORPUS = (
    "x86_64",
    "amd64",
    "x64",
    "aarch64",
    "arm64",
    "macos",
    "darwin",
    "macosx",
    "Darwin",
    "linux",
    "Linux",
    "windows",
    "win32",
)


def _host_target_triple() -> str:
    """Host → zig build release-pack target (`tools/c-abi/c-abi-host-aliases.json`)."""
    machine = platform.machine().lower()
    arch = {
        "x86_64": "x86_64",
        "amd64": "x86_64",
        "x64": "x86_64",
        "aarch64": "aarch64",
        "arm64": "aarch64",
    }.get(machine, machine)
    # system is .lower()'d so Darwin/Linux appear via lower; macosx/win32 mapped.
    system = platform.system().lower()
    zig_os = {
        "darwin": "macos",
        "macosx": "macos",
        "linux": "linux",
        "windows": "windows",
        "win32": "windows",
    }.get(system, system)
    return f"{arch}-{zig_os}"


def _cache_base(contract: dict) -> pathlib.Path:
    override = os.environ.get("GLOWCAP_CACHE_DIR")
    if override:
        return pathlib.Path(override)
    xdg = os.environ.get("XDG_CACHE_HOME")
    if xdg:
        return pathlib.Path(xdg) / "glowcap" / "c-abi"
    home = os.environ.get("HOME") or os.environ.get("USERPROFILE")
    if home:
        return pathlib.Path(home) / ".cache" / "glowcap" / "c-abi"
    return pathlib.Path(tempfile.gettempdir()) / str(contract["fallback_cache_name"])


def _cache_lib_dir(contract: dict, version: str, target: str) -> pathlib.Path:
    base = _cache_base(contract)
    layout = str(contract["cache_layout"])
    return pathlib.Path(
        _apply_contract_template(
            layout, version=version, target=target, cache_base=str(base)
        )
    )


def _soft_fail(msg: str) -> None:
    if _env_truthy("GLOWCAP_STRICT"):
        raise RuntimeError(msg)
    print(f"glowcap: {msg} (soft-fail)", file=sys.stderr)


def _hard_fail(msg: str) -> NoReturn:
    """Hygiene/security failures always fail closed (never gated on STRICT)."""
    raise RuntimeError(msg)


def _require_https(base: str) -> None:
    if base.startswith("https://"):
        return
    if _env_truthy("GLOWCAP_ALLOW_INSECURE"):
        return
    _hard_fail(f"refusing non-HTTPS release base URL: {base}")


def _download(url: str, dest: pathlib.Path, *, max_bytes: int, user_agent: str) -> None:
    req = urllib.request.Request(url, headers={"User-Agent": user_agent})
    with urllib.request.urlopen(req, timeout=60) as resp:  # noqa: S310 - HTTPS gated
        length = resp.headers.get("Content-Length")
        if length is not None and int(length) > max_bytes:
            raise OSError(
                f"Content-Length {length} exceeds max_tarball_bytes {max_bytes}"
            )
        written = 0
        with dest.open("wb") as out:
            while True:
                chunk = resp.read(1024 * 1024)
                if not chunk:
                    break
                written += len(chunk)
                if written > max_bytes:
                    raise OSError(f"download exceeded max_tarball_bytes {max_bytes}")
                out.write(chunk)


def _verify_sha256(sums_text: str, tarball: str, tarball_path: pathlib.Path) -> None:
    expect = None
    for line in sums_text.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[1].lstrip("*") == tarball:
            expect = parts[0].lower()
            break
    if expect is None:
        raise OSError(f"SHA256SUMS has no entry for {tarball}")
    got = hashlib.sha256(tarball_path.read_bytes()).hexdigest()
    if got != expect:
        raise OSError(f"SHA256 mismatch for {tarball}: got {got}, want {expect}")


def _safe_extract_lib(
    tarball_path: pathlib.Path,
    stage: pathlib.Path,
    *,
    prefix: str,
) -> None:
    """Extract only regular files under prefix/, rejecting traversal and links."""
    stage_resolved = stage.resolve()
    prefix_slash = prefix + "/"
    with tarfile.open(tarball_path, "r:gz") as tf:
        for member in tf.getmembers():
            name = member.name
            if name.startswith("./"):
                name = name[2:]
            if name != prefix and not name.startswith(prefix_slash):
                continue
            parts = pathlib.PurePosixPath(name).parts
            if pathlib.PurePosixPath(name).is_absolute() or ".." in parts:
                raise OSError(f"refusing unsafe tar member: {member.name}")
            if member.issym() or member.islnk():
                raise OSError(f"refusing link tar member: {member.name}")
            # Everything else that is not a regular file or a directory gets
            # the same verdict the other resolve ports reach. Skipping a
            # device or fifo member instead would extract partially where
            # every other port hard-fails.
            if not (member.isfile() or member.isdir()):
                raise OSError(f"refusing non-file tar member: {member.name}")
            dest = (stage / name).resolve()
            if (
                not str(dest).startswith(str(stage_resolved) + os.sep)
                and dest != stage_resolved
            ):
                raise OSError(f"tar member escapes stage: {member.name}")
            tf.extract(member, path=stage, set_attrs=False)


def _fetch_into_cache(
    contract: dict, version: str, target: str, cache_lib: pathlib.Path
) -> None:
    base = os.environ.get(
        "GLOWCAP_RELEASE_BASE_URL",
        contract["default_release_base_url"],
    )
    _require_https(base)
    max_bytes = int(contract["max_tarball_bytes"])
    max_sums = int(contract["max_sums_bytes"])
    user_agent = str(contract["user_agent"])
    tag = _apply_contract_template(
        str(contract["release_tag_template"]), version=version, target=target
    )
    tarball = _apply_contract_template(
        str(contract["tarball_template"]), version=version, target=target
    )
    extract_prefix = str(contract["extract_prefix"])
    url = f"{base}/{tag}/{tarball}"
    cache_root = cache_lib.parent
    cache_root.mkdir(parents=True, exist_ok=True)

    lock_dir = cache_root / ".lock"
    waited = 0
    while True:
        try:
            lock_dir.mkdir()
            break
        except FileExistsError:
            waited += 1
            if waited > 300:
                _soft_fail(f"timed out waiting for cache lock at {lock_dir}")
                return
            time.sleep(0.1)

    try:
        marker = _lib_file(str(contract["marker_shared_stem"]))
        if (cache_lib / marker).is_file():
            return

        tarball_path = cache_root / tarball
        print(f"glowcap: downloading {url}", file=sys.stderr)
        try:
            _download(url, tarball_path, max_bytes=max_bytes, user_agent=user_agent)
        except (urllib.error.URLError, OSError) as err:
            tarball_path.unlink(missing_ok=True)
            _soft_fail(f"download failed: {url} ({err})")
            return

        sums_url = f"{base}/{tag}/SHA256SUMS"
        sums_path = cache_root / "SHA256SUMS"
        try:
            _download(sums_url, sums_path, max_bytes=max_sums, user_agent=user_agent)
        except (urllib.error.URLError, OSError) as err:
            tarball_path.unlink(missing_ok=True)
            sums_path.unlink(missing_ok=True)
            _hard_fail(
                f"checksum required before extract: SHA256SUMS download failed ({err})"
            )

        try:
            _verify_sha256(sums_path.read_text(encoding="utf-8"), tarball, tarball_path)
        except OSError as err:
            tarball_path.unlink(missing_ok=True)
            sums_path.unlink(missing_ok=True)
            _hard_fail(str(err))

        stage = cache_root / f"stage.{os.getpid()}"
        if stage.exists():
            shutil.rmtree(stage, ignore_errors=True)
        stage.mkdir(parents=True, exist_ok=True)
        try:
            _safe_extract_lib(tarball_path, stage, prefix=extract_prefix)
        except (tarfile.TarError, OSError) as err:
            shutil.rmtree(stage, ignore_errors=True)
            _hard_fail(f"tar extract failed: {err}")
        extracted = stage / extract_prefix
        if not extracted.is_dir():
            shutil.rmtree(stage, ignore_errors=True)
            _hard_fail(f"tarball missing {extract_prefix}/")
        if cache_lib.exists():
            shutil.rmtree(cache_lib, ignore_errors=True)
        extracted.rename(cache_lib)
        shutil.rmtree(stage, ignore_errors=True)
    finally:
        try:
            lock_dir.rmdir()
        except OSError:
            pass


def _lib_dir() -> pathlib.Path | None:
    """Directory to load archives from, or None for a bare name (OS search)."""
    override = os.environ.get("GLOWCAP_LIB_DIR")
    if override:
        return pathlib.Path(override)

    contract = _contract()
    dev_root = _find_dev_root()
    version = _abi_version(dev_root, contract)
    target = _host_target_triple()
    cache_lib = _cache_lib_dir(contract, version, target)
    marker = _lib_file(str(contract["marker_shared_stem"]))
    zig_out = (dev_root / "zig-out" / "lib") if dev_root is not None else None

    if (cache_lib / marker).is_file():
        return cache_lib

    if zig_out is not None and (zig_out / marker).is_file():
        # GLOWCAP_DOWNLOAD refreshes the cache even when zig-out exists,
        # including when releases_published is false.
        if _env_truthy("GLOWCAP_DOWNLOAD"):
            _fetch_into_cache(contract, version, target, cache_lib)
            if (cache_lib / marker).is_file():
                return cache_lib
        return zig_out

    if _want_release_fetch(contract):
        _fetch_into_cache(contract, version, target, cache_lib)
        if (cache_lib / marker).is_file():
            return cache_lib

    if zig_out is not None and zig_out.is_dir():
        return zig_out
    return None


def _lib_path(stem: str) -> str:
    """Resolve an archive: absolute path under the cascade, or a bare name."""
    name = _lib_file(stem)
    directory = _lib_dir()
    if directory is not None:
        return str(directory / name)
    # Bare names ride the OS search path: a DLL/so plant risk. Refuse on
    # Windows; warn elsewhere (system install / LD_LIBRARY_PATH posture).
    if sys.platform == "win32":
        raise RuntimeError(
            "glowcap: could not resolve an absolute path for "
            f"{name}; set GLOWCAP_LIB_DIR or populate the abi-versioned cache "
            "(Windows refuses bare DLL names to avoid search-order plants)"
        )
    print(
        f"glowcap: warning: loading bare {name} via the OS search path",
        file=sys.stderr,
    )
    return name
