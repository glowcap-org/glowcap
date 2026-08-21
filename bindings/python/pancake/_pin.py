"""Internal: the one layout gate every hand-mirrored ctypes struct passes.

Each ``_ffi_*`` module declares its own ``ctypes.Structure`` for a C ABI
struct, because ctypes wants a symbolic declaration rather than a byte-offset
reader. :func:`pin_struct` is what proves a declaration still describes the
struct the library actually passes: it compares the declared size, field
count, field order, field offsets, and per-field widths against
``_layouts_gen.LAYOUTS``, which ``zig build gen-binding-ffi-layouts`` reflects
off the real Zig types. A Zig-side field change therefore moves a row in the
generated table, and the mirror that was not swept fails loudly the moment the
module is imported.

Centralizing the check prevents declarations below a module's pin from escaping
coverage. ``source-check`` requires every hand-mirrored struct to call it.

A plain ``raise`` rather than ``assert``, so ``python -O`` cannot strip the
gate.
"""

from __future__ import annotations

import ctypes
from typing import Any, Mapping, Optional

from ._layouts_gen import LAYOUTS


def pin_struct(
    cls: type,
    stem: str,
    *,
    aliases: Optional[Mapping[str, str]] = None,
) -> None:
    """Pin one mirror against the C ABI struct ``stem`` names.

    ``aliases`` maps an ABI field name to the name this mirror declares it by,
    for the rare slot a binding spells differently. An alias naming a field the
    ABI does not have is itself an error, so a rename cannot leave one behind.
    """
    layout = LAYOUTS.get(stem)
    if layout is None:
        raise ImportError(
            f"pancake FFI layout drift: {cls.__name__} pins against {stem}, "
            "which the C ABI does not declare; re-mirror the struct"
        )
    want_size, want_fields = layout
    got_size = ctypes.sizeof(cls)
    if got_size != want_size:
        raise ImportError(
            f"pancake FFI layout drift: sizeof({cls.__name__}) == {got_size}, "
            f"the C ABI says {want_size}; re-mirror the struct"
        )
    # `_fields_` is the declaration itself, so it is read off the class rather
    # than off a ctypes base mypy can name.
    declared: Any = getattr(cls, "_fields_")
    if len(declared) != len(want_fields):
        raise ImportError(
            f"pancake FFI layout drift: {cls.__name__} declares "
            f"{len(declared)} fields, the C ABI has {len(want_fields)} "
            f"({', '.join(name for name, _off, _size in want_fields)}); "
            "re-mirror the struct"
        )
    names = {name for name, _off, _size in want_fields}
    for abi_name in aliases or {}:
        if abi_name not in names:
            raise ImportError(
                f"pancake FFI layout drift: {cls.__name__} aliases "
                f"{abi_name!r}, which {stem} no longer has; re-mirror the struct"
            )
    for (abi_name, want_off, want_width), declared_field in zip(want_fields, declared):
        got_name = declared_field[0]
        want_name = (aliases or {}).get(abi_name, abi_name)
        if got_name != want_name:
            raise ImportError(
                f"pancake FFI layout drift: {cls.__name__} declares "
                f"{got_name!r} where the C ABI has {abi_name!r}; "
                "re-mirror the struct"
            )
        got_off = getattr(cls, got_name).offset
        got_width = ctypes.sizeof(declared_field[1])
        if got_off != want_off or got_width != want_width:
            raise ImportError(
                f"pancake FFI layout drift: {cls.__name__}.{got_name} is "
                f"{got_width} bytes at offset {got_off}, the C ABI says "
                f"{want_width} bytes at offset {want_off}; re-mirror the struct"
            )
