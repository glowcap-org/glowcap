#!/usr/bin/env python3
"""Regenerate the Syrup byte-fixture corpus through the upstream Python encoder.

Each builder below hand-constructs the record structure glowcap's Syrup codec
produces for the corresponding ``model.Message``, then serializes it through
the upstream Python Syrup encoder and writes one ``.bin`` per fixture to the
directory passed on the command line. The Syrup grammar is small and
unambiguous, so a different reference implementation encoding the same record
must produce byte-identical output, the Racket sibling
(``generate.rkt``) is the one ``zig build fixture-gen-check`` runs
against the committed corpus.

Requires the upstream ``syrup.py`` module on ``PYTHONPATH``; the devcontainer
does not install it, so this generator is the cross-check you run by hand::

    PYTHONPATH=/path/to/syrup/impls/python python3 generate.py /tmp/out
"""

from __future__ import annotations

import sys
from pathlib import Path

from syrup import Record, Symbol, syrup_encode  # type: ignore[import-not-found]

# The operation and signed-handoff record builders live beside this entry in
# ``records.py``; the star import is what lets the fixture table below name
# every builder the way it always has.
from records import *  # noqa: F401,F403


# ── ADR-0007 / op:get + op:index field-projection ops ─────────────
#
# Goblins's `(define-recordable-struct op:get (receiver-desc
# field-name new-answer-pos))` and the parallel `op:index` at
# `goblins/ocapn/captp.rkt:98-104`. Mirrors the Racket fixture
# builders in `generate.rkt`; both encoders must produce
# byte-identical output for the same record.


def op_get() -> Record:
    """``<op:get <desc:export 7> "name" 11+>``.

    receiver = sender's ``Reference::Far(import_position=7)`` → wire
    ``<desc:export 7>`` (target-position perspective flip per
    ADR-0010 § Decision 3). ``field-name`` is a Syrup *String* per
    CapTP § op:get (Goblins guards ``string?`` on receipt).
    ``new-answer-pos`` is the result-promise answer id the sender
    just allocated.
    """
    target = Record(Symbol("desc:export"), (7,))
    return Record(Symbol("op:get"), (target, "name", 11))


def op_index() -> Record:
    """``<op:index <desc:export 7> 5+ 11+>``.

    receiver = sender's ``Reference::Far(import_position=7)`` → wire
    ``<desc:export 7>``. ``index`` is a Syrup positive integer per
    ADR-0007 § Decision 1; ``new-answer-pos`` is the result-promise
    answer id.
    """
    target = Record(Symbol("desc:export"), (7,))
    return Record(Symbol("op:index"), (target, 5, 11))


def op_untag() -> Record:
    """``<op:untag <desc:export 7> "cm" 11+>``.

    receiver = sender's ``Reference::Far(import_position=7)`` → wire
    ``<desc:export 7>``. ``tag`` is a Syrup *String* per CapTP §
    op:untag, matching op:get's field-name choice.
    ``new-answer-pos`` is the result-promise answer id.
    """
    target = Record(Symbol("desc:export"), (7,))
    return Record(Symbol("op:untag"), (target, "cm", 11))


# ── primitive Syrup fixtures (E3) ──────────────────────────────────
#
# Primitive-level coverage so the byte-shape verification doesn't
# stop at the OCapN record layer. Each builder returns a Python
# value the upstream `syrup_encode` accepts directly.


def prim_string_hello() -> str:
    return "hello"


def prim_integer_pos_42() -> int:
    return 42


def prim_integer_neg_7() -> int:
    return -7


def prim_integer_big_neg() -> int:
    return -1267650600228229401496703205376


def prim_list_of_ints() -> list:
    return [1, 2, 3]


def prim_set_of_ints() -> set:
    return {1, 2, 3}


def prim_dict_str_to_int() -> dict:
    return {"a": 1, "b": 2}


# Filename → record builder. Filenames match the fixture names
# `test/oracle/protocol_oracle.zig` embeds (CapTP-record fixtures, plus
# primitive fixtures prefixed `prim_`) and the Racket sibling's table.
FIXTURES = {
    "op_abort.bin": op_abort_shutting_down,
    "op_abort_typed.bin": op_abort_typed,
    "op_deliver.bin": op_deliver_minimal,
    "op_resolve_break.bin": op_resolve_break,
    "op_resolve_fulfill_far.bin": op_resolve_fulfill_far,
    "op_resolve_fulfill_near.bin": op_resolve_fulfill_near,
    "op_resolve_fulfill_promise.bin": op_resolve_fulfill_promise,
    "op_resolve_fulfill_import_promise.bin": op_resolve_fulfill_import_promise,
    "op_listen_promise_target.bin": op_listen_promise_target,
    "op_listen_export_target.bin": op_listen_export_target,
    "op_listen_v1_0_wants_partial_false.bin": op_listen_v1_0_wants_partial_false,
    "op_listen_v1_0_wants_partial_true.bin": op_listen_v1_0_wants_partial_true,
    "op_deliver_v1_0_with_resolve_me_desc.bin": op_deliver_v1_0_with_resolve_me_desc,
    # op:listen break-notification fire (bare-Symbol reason)
    "op_deliver_listen_break_notification.bin": op_deliver_listen_break_notification,
    "op_gc_exports.bin": op_gc_exports,
    "op_gc_answers.bin": op_gc_answers,
    "desc_handoff_give_signed.bin": signed_handoff_give,
    "desc_handoff_receive_signed.bin": signed_handoff_receive,
    "op_deliver_withdraw_gift.bin": op_deliver_withdraw_gift,
    # ADR-0007 op:get / op:index field-projection ops
    "op_get.bin": op_get,
    "op_index.bin": op_index,
    "op_untag.bin": op_untag,
    # ADR-0006 op:start-session handshake (V1_0)
    "op_start_session_v1_0.bin": op_start_session_v1_0,
    # ADR-0025 typed-abort wire kind
    "op_abort_resource_exhausted.bin": op_abort_resource_exhausted,
    # ADR-0008 adapter-projected typed-abort wire kinds
    "op_abort_crossed_hellos.bin": op_abort_crossed_hellos,
    "op_abort_connection_lost.bin": op_abort_connection_lost,
    "op_abort_graceful_shutdown.bin": op_abort_graceful_shutdown,
    # ADR-0021 widened `Argument` arms (op:deliver one-arg shape)
    "op_deliver_arg_void.bin": op_deliver_arg_void,
    "op_deliver_arg_float64.bin": op_deliver_arg_float64,
    "op_deliver_arg_big_integer.bin": op_deliver_arg_big_integer,
    "op_deliver_arg_tagged.bin": op_deliver_arg_tagged,
    "op_deliver_arg_keyword.bin": op_deliver_arg_keyword,
    "op_deliver_arg_set.bin": op_deliver_arg_set,
    "prim_string_hello.bin": prim_string_hello,
    "prim_integer_pos_42.bin": prim_integer_pos_42,
    "prim_integer_neg_7.bin": prim_integer_neg_7,
    "prim_integer_big_neg.bin": prim_integer_big_neg,
    "prim_list_of_ints.bin": prim_list_of_ints,
    "prim_set_of_ints.bin": prim_set_of_ints,
    "prim_dict_str_to_int.bin": prim_dict_str_to_int,
}


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {argv[0]} <out-dir>", file=sys.stderr)
        return 2
    out_dir = Path(argv[1])
    out_dir.mkdir(parents=True, exist_ok=True)
    for name, builder in FIXTURES.items():
        bytes_out = syrup_encode(builder())
        (out_dir / name).write_bytes(bytes_out)
        print(f"  wrote {name} ({len(bytes_out)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
