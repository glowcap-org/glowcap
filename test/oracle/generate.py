#!/usr/bin/env python3
"""Regenerate the Syrup byte-fixture corpus through the upstream Python encoder.

Each builder below hand-constructs the record structure pancake's Syrup codec
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


# ── record builders ────────────────────────────────────────────────


def op_abort_shutting_down() -> Record:
    """``<op:abort "shutting down">``, Goblins-shape-aligned."""
    return Record(Symbol("op:abort"), ("shutting down",))


def op_deliver_minimal() -> Record:
    """``<op:deliver <desc:export 7> [b"hello"] 42 #f>``.

    Field 4 (``resolve-me-desc``) is pancake-shape divergent, pancake
    always emits ``#f`` (Syrup wire compatibility).
    """
    target = Record(Symbol("desc:export"), (7,))
    args = [b"hello"]
    return Record(Symbol("op:deliver"), (target, args, 42, False))


def op_resolve_break() -> Record:
    """``<op:resolve 42 <resolve:break <error "target unreachable">>>``.

    The ``<op:resolve …>`` envelope is pancake-shape (Syrup wire compatibility).
    The ``<error …>`` payload label is pancake-pinned pending
    upstream ocapn/ocapn#142.
    """
    error = Record(Symbol("error"), ("target unreachable",))
    resolution = Record(Symbol("resolve:break"), (error,))
    return Record(Symbol("op:resolve"), (42, resolution))


def op_resolve_fulfill_far() -> Record:
    """``<op:resolve 7 <resolve:fulfill <desc:export 5>>>``."""
    desc = Record(Symbol("desc:export"), (5,))
    resolution = Record(Symbol("resolve:fulfill"), (desc,))
    return Record(Symbol("op:resolve"), (7, resolution))


def op_resolve_fulfill_near() -> Record:
    """``<op:resolve 7 <resolve:fulfill <desc:import-object 9>>>``.

    The encoder side of the perspective flip, sender's
    ``Reference::Near`` becomes ``<desc:import-object N>`` in
    payload position. Receiver decode flips it to
    ``Reference::Far``.
    """
    desc = Record(Symbol("desc:import-object"), (9,))
    resolution = Record(Symbol("resolve:fulfill"), (desc,))
    return Record(Symbol("op:resolve"), (7, resolution))


def op_resolve_fulfill_promise() -> Record:
    """``<op:resolve 7 <resolve:fulfill <desc:answer 11>>>``."""
    desc = Record(Symbol("desc:answer"), (11,))
    resolution = Record(Symbol("resolve:fulfill"), (desc,))
    return Record(Symbol("op:resolve"), (7, resolution))


def op_resolve_fulfill_import_promise() -> Record:
    """``<op:resolve 7 <resolve:fulfill <desc:import-promise 99>>>``.

    Encoder side of the perspective flip for a local unresolved
    promise: sender's ``Reference::Near{.promise}`` becomes
    ``<desc:import-promise N>`` in payload position
    (ADR-0080 ``Slot.local_unresolved``).
    """
    desc = Record(Symbol("desc:import-promise"), (99,))
    resolution = Record(Symbol("resolve:fulfill"), (desc,))
    return Record(Symbol("op:resolve"), (7, resolution))


def op_listen_promise_target() -> Record:
    """``<op:listen <desc:answer 7> <desc:import-object 9>>``.

    Stage 1 op:listen wire-shape per ADR-0007 § Decision 4, two
    desc:* reference operands. ``to-desc`` may be ``desc:answer``
    (the pipelining target case) or ``desc:export`` (the local-
    export target case). ``listen-desc`` is ``desc:import-object``
    or ``desc:import-promise`` per the spec; pancake's encoder
    emits ``desc:import-object`` for ``Reference::Near`` listener
    arguments via the standard payload-position perspective flip.

    Same shape on next and V1_0, adding a new record is wire-
    additive (existing peers without ADR-0007 reject the unknown
    record up the negotiation chain). The Stage 2 V1_0 Goblins-
    canonical 3-operand ``wants-partial?`` extension lives in a
    separate fixture once the Stage 2 Goblins-canonical wire
    profile lands.
    """
    target = Record(Symbol("desc:answer"), (7,))
    listener = Record(Symbol("desc:import-object"), (9,))
    return Record(Symbol("op:listen"), (target, listener))


def op_listen_export_target() -> Record:
    """``<op:listen <desc:export 5> <desc:import-object 9>>``.

    Local-export listen target case per ADR-0007 § Decision 9,
    the listener fires immediately with the export as the
    ``Fulfill`` argument when the receiver records the listen.
    """
    target = Record(Symbol("desc:export"), (5,))
    listener = Record(Symbol("desc:import-object"), (9,))
    return Record(Symbol("op:listen"), (target, listener))


def op_listen_v1_0_wants_partial_false() -> Record:
    """``<op:listen <desc:answer 7> <desc:import-object 9> #f>``.

    V1_0 Goblins-canonical 3-operand `op:listen` per ADR-0007
    § Decision 4, the third operand is the `wants-partial?`
    boolean (Goblins-canonical extension per
    ``goblins/ocapn/captp.rkt:86-88``). `#f` is spec-strict
    behavior (fire once, on the eventually-settled non-promise
    resolution).
    """
    target = Record(Symbol("desc:answer"), (7,))
    listener = Record(Symbol("desc:import-object"), (9,))
    return Record(Symbol("op:listen"), (target, listener, False))


def op_listen_v1_0_wants_partial_true() -> Record:
    """``<op:listen <desc:answer 7> <desc:import-object 9> #t>``.

    V1_0 Goblins-canonical 3-operand `op:listen` with
    `wants-partial? = #t` — fire on each intermediate
    `Fulfill(Promise(M))` step before the eventually-settled
    non-promise value, per Goblins's ``core.rkt:1153-1199``.
    """
    target = Record(Symbol("desc:answer"), (7,))
    listener = Record(Symbol("desc:import-object"), (9,))
    return Record(Symbol("op:listen"), (target, listener, True))


def op_deliver_v1_0_with_resolve_me_desc() -> Record:
    """``<op:deliver <desc:export 7> [b"hello"] 42 <desc:import-object 99>>``.

    V1_0 Goblins-canonical resolver-callback shape (ADR-0003,
    ADR-0010): the fourth ``op:deliver`` field carries the
    partner-installable ``<desc:import-object pos>`` resolver
    descriptor. A future ``op:deliver`` to that import carries the
    resolution ``('fulfill <ref>)`` or ``('break <error>)``, that
    callback ``op:deliver`` is shape-identical to the existing
    ``op_deliver.bin`` fixture and is not a separate vector.
    """
    target = Record(Symbol("desc:export"), (7,))
    args = [b"hello"]
    resolve_me_desc = Record(Symbol("desc:import-object"), (99,))
    return Record(Symbol("op:deliver"), (target, args, 42, resolve_me_desc))


def op_deliver_listen_break_notification() -> Record:
    """``<op:deliver <desc:export 9> ['break 'target unreachable] #f #f>``.

    The ``op:listen`` break-notification fire the engine emits
    (``borrowedListenerFire`` in
    ``src/ocapn/engine/pipeline_resolution.zig``): a no-answer deliver
    to the listener whose args are ``[Symbol("break"), Symbol(reason)]``
    — the reason as a *bare* Symbol, never an ``<error>`` record.
    Goblins' unmarshaller rejects unknown records and the upstream
    conformance suite's ``test_op_listen_to_promise_and_break`` asserts
    exactly this shape, so a regression to an ``<error>``-record payload
    must fail hermetically against this fixture, not only under the
    opt-in live-Goblins gates.
    """
    target = Record(Symbol("desc:export"), (9,))
    args = [Symbol("break"), Symbol("target unreachable")]
    return Record(Symbol("op:deliver"), (target, args, False, False))


# ── Stage 2 / ADR-0008 fixtures ────────────────────────────────────


def op_gc_exports() -> Record:
    """``<op:gc-exports [3 7] [1 2]>``, Goblins-canonical
    ``op:gc-exports`` per
    ``goblins/ocapn/captp.rkt:90-92``: two parallel lists, the
    sender's dropped position ids and the matching wire-deltas.
    Receiver decrements its export refcounts by the wire-delta
    per ADR-0008 § Wire-delta reference counting.
    """
    return Record(Symbol("op:gc-exports"), ([3, 7], [1, 2]))


def op_gc_answers() -> Record:
    """``<op:gc-answers [11 13]>`` — Goblins-canonical
    ``op:gc-answers`` per ``goblins/ocapn/captp.rkt:94-96``: a
    single list of answer-pos values being released. No wire-delta
    — each answer-pos is single-reference per ADR-0008
    § Wire format: op:gc-answers.
    """
    return Record(Symbol("op:gc-answers"), ([11, 13],))


def op_abort_typed() -> Record:
    """``<op:abort "VersionMismatch: peer requested 2.0">``.

    Stage 2 / ADR-0008 typed-reason wire projection: pancake's
    ``AbortReasonKind`` taxonomy emits the spec-strict single-
    string ``op:abort`` with a ``"<KindName>: <message>"`` prefix
    on V1_0 syrup. Goblins-canonical wire stays a single string;
    the typed-kind round-trips on decode via
    ``AbortReason::parse_v1_0``. Companion to the existing
    ``op_abort.bin`` fixture (which exercises the prefix-less
    ``Other`` kind).
    """
    return Record(Symbol("op:abort"), ("VersionMismatch: peer requested 2.0",))


def op_abort_resource_exhausted() -> Record:
    """``<op:abort "ResourceExhausted: ImportTable cap hit">``.

    Stage 4 / ADR-0025 typed-reason wire projection: pancake's
    new ``AbortReasonKind::ResourceExhausted`` kind emits the
    spec-strict single-string ``op:abort`` with the
    ``"ResourceExhausted: <message>"`` prefix on V1_0 syrup, the
    same shape as the other typed kinds per ADR-0008 § Wire
    format. Companion to ``op_abort.bin`` (prefix-less ``Other``)
    and ``op_abort_typed.bin`` (``VersionMismatch`` prefix).
    """
    return Record(Symbol("op:abort"), ("ResourceExhausted: ImportTable cap hit",))


def op_abort_crossed_hellos() -> Record:
    """``<op:abort "CrossedHellos: byte-lower side closing">``.

    ADR-0008 typed abort taxonomy: ``CrossedHellos`` is the abort
    kind an adapter projects when it detects a concurrent inbound
    session for the same partner; the no-I/O core carries the kind
    and its wire projection but does not detect the condition. Same
    single-string ``"<KindName>: <message>"`` shape as the other
    typed kinds per ADR-0008 § Typed abort taxonomy.
    """
    return Record(Symbol("op:abort"), ("CrossedHellos: byte-lower side closing",))


def op_abort_connection_lost() -> Record:
    """``<op:abort "ConnectionLost: peer TCP RST">``.

    ADR-0008 typed abort taxonomy: ``ConnectionLost`` is the abort
    kind an adapter projects best-effort when its transport reports a
    lost connection; partners observing this MAY retry. Same
    single-string ``"<KindName>: <message>"`` shape as the other
    typed kinds per ADR-0008 § Typed abort taxonomy.
    """
    return Record(Symbol("op:abort"), ("ConnectionLost: peer TCP RST",))


def op_abort_graceful_shutdown() -> Record:
    """``<op:abort "GracefulShutdown: SIGTERM drain complete">``.

    ADR-0008 typed abort taxonomy: ``GracefulShutdown`` is the abort
    kind an adapter projects on a drain-to-completion shutdown;
    partners observing this SHOULD NOT retry (distinct from the
    retryable ``ConnectionLost``). Same single-string
    ``"<KindName>: <message>"`` shape as the other typed kinds per
    ADR-0008 § Typed abort taxonomy.
    """
    return Record(Symbol("op:abort"), ("GracefulShutdown: SIGTERM drain complete",))


# ── ADR-0021 widened-Argument fixtures ──────────────────
#
# `op:deliver to=<desc:export 7> args=[<arg>] answer-pos=42 #f`
# shape for each new `Argument` variant ADR-0021 added. The outer
# `op:deliver` shape matches `op_deliver_minimal` exactly except
# for the args list, so a regression on the outer envelope
# surfaces against both fixtures, and a regression on a specific
# arg variant surfaces against its dedicated fixture.


def _op_deliver_one_arg(arg) -> Record:
    """Build an ``op:deliver`` carrying exactly one positional arg.

    The target / answer-pos / resolve-me-desc are pinned to match
    the existing `op_deliver_minimal` shape so the per-variant
    fixtures only differ from each other in the single positional
    arg slot.
    """
    target = Record(Symbol("desc:export"), (7,))
    return Record(Symbol("op:deliver"), (target, [arg], 42, False))


def op_deliver_arg_void() -> Record:
    """``op:deliver`` carrying ``<'void>`` (zero-arg record).

    ADR-0021 wire shape for the Goblins ``(void)`` value pancake
    rejected pre-ADR-0021. The fixture pins the cross-impl byte
    shape so a regression to the pre-ADR rejection (or to a
    different ``Void`` wire encoding) surfaces in CI.

    **Pin direction:** the bytes here are produced by the upstream
    Python Syrup encoder against the same record shape pancake's
    encoder claims to produce; both encoders agreeing on the
    Syrup grammar is the load-bearing check.
    """
    void_record = Record(Symbol("void"), ())
    return _op_deliver_one_arg(void_record)


def op_deliver_arg_big_integer() -> Record:
    """``op:deliver`` carrying a Python int outside i64 (2^100).

    ADR-0049: the upstream Syrup encoders render an arbitrary-precision
    integer as its canonical decimal digits, the same bytes pancake's
    ``big_integer`` arm carries.
    """
    return _op_deliver_one_arg(1267650600228229401496703205376)


def op_deliver_arg_float64() -> Record:
    """``op:deliver`` carrying ``D<8 bytes>`` (IEEE 754 double).

    ADR-0021 wire shape for the Goblins double-flonum value. The
    fixture uses ``1.5`` because its IEEE 754 BE representation
    (``0x3FF8000000000000``) has no surprising bit patterns and
    is easy to verify by eyeballing.

    **Pin direction:** Python Syrup encodes ``1.5`` as
    ``D\\x3f\\xf8\\x00\\x00\\x00\\x00\\x00\\x00``; pancake's
    encoder must produce identical bytes for ``Argument::Float64(1.5)``.
    """
    return _op_deliver_one_arg(1.5)


def op_deliver_arg_tagged() -> Record:
    """``op:deliver`` carrying ``<'user-record 'point (1 2)>``.

    ADR-0021 wire shape for the Goblins ``'user-record`` catch-all
    (a non-`'error` / non-`'kw` user-extensible tagged record).
    pancake's ``Argument::Tagged.value`` carries a ``Vec<Argument>``
    so the model cell matches the wire's record-args list verbatim
    at every arity; a 2-element ``(1 2)`` value list exercises the
    multi-arg shape.

    **Pin direction:** Python Syrup encodes the
    ``Record(Symbol("user-record"), (Symbol("point"), [1, 2]))``
    shape as the spec-canonical bytes; pancake's encoder must
    produce identical bytes for
    ``Argument::Tagged { tag: "point", value: vec![Integer(1), Integer(2)] }``.
    """
    inner = Record(Symbol("user-record"), (Symbol("point"), [1, 2]))
    return _op_deliver_one_arg(inner)


def op_deliver_arg_keyword() -> Record:
    """``op:deliver`` carrying ``<'kw 'name>``.

    ADR-0021 wire shape for the Goblins Racket keyword value (a
    structurally-1-arg user-record that pancake special-cases on
    decode as ``Argument::Keyword``). Distinct from
    ``Argument::Symbol`` because keyword args are a discrete
    dispatch concern in OCapN's call shape, not a general-purpose
    symbol value.

    **Pin direction:** Python Syrup encodes
    ``Record(Symbol("kw"), (Symbol("name"),))`` as the canonical
    bytes; pancake's encoder must produce identical bytes for
    ``Argument::Keyword("name")``.
    """
    inner = Record(Symbol("kw"), (Symbol("name"),))
    return _op_deliver_one_arg(inner)


def op_deliver_arg_set() -> Record:
    """``op:deliver`` carrying ``#1 2 3 $`` (Syrup Set).

    ADR-0021 wire shape for the Goblins ``(set …)`` value. The
    in-memory ``Argument::Set(Vec<Argument>)`` is insertion-
    ordered; canonical sort by encoded bytes happens at codec-
    encode time only. Equality is order-agnostic / multiset-
    matching, ``Set([3, 1, 2])`` round-trips equal to
    ``Set([1, 2, 3])`` after the canonical-sort.

    **Pin direction:** Python's ``set`` type when fed to
    ``syrup_encode`` produces canonical-sort bytes; pancake's
    encoder must produce identical bytes for
    ``Argument::Set(vec![Integer(1), Integer(2), Integer(3)])``.
    """
    return _op_deliver_one_arg({1, 2, 3})


# ── Stage 2 / ADR-0009 handoff envelope fixtures ───────────────────


def _peer_key_sexp(q_value: bytes):
    """Encode an Ed25519 public key as the OCapN-canonical gcrypt
    s-expression ``['public-key ['ecc ['curve 'Ed25519] ['flags 'eddsa]
    ['q q_value]]]`` per the CapTP spec § Public Key. In Syrup, the
    s-expression renders as nested lists of symbols / a 32-byte
    ByteArray for ``q_value``.
    """
    return [
        Symbol("public-key"),
        [
            Symbol("ecc"),
            [Symbol("curve"), Symbol("Ed25519")],
            [Symbol("flags"), Symbol("eddsa")],
            [Symbol("q"), q_value],
        ],
    ]


def _signature_sexp(sig_64: bytes):
    """Encode a 64-byte Ed25519 signature as
    ``['sig-val ['eddsa ['r r_value] ['s s_value]]]`` (RFC 8032 r||s).
    """
    assert len(sig_64) == 64, "Ed25519 signature must be 64 bytes"
    return [
        Symbol("sig-val"),
        [
            Symbol("eddsa"),
            [Symbol("r"), sig_64[:32]],
            [Symbol("s"), sig_64[32:]],
        ],
    ]


def _ocapn_peer_no_hints(transport: str, designator: str):
    """Build an `<ocapn-peer transport designator hints>` record
    matching pancake's `locator_to_syrup` output for empty hints.
    Empty hints emit an empty dict `{}` to match Goblins-Racket and
    the OCapN Python conformance suite's `OCapNPeer.to_syrup_record`.
    A prior fixture revision used Syrup `False` here, which diverged
    from upstream and broke `op:start-session` signature verification.
    """
    return Record(Symbol("ocapn-peer"), (Symbol(transport), designator, {}))


def _handoff_give_record():
    """Inner ``<desc:handoff-give recipient-key exporter-location
    session gifter-side gift-id>`` certificate per ADR-0009."""
    return Record(
        Symbol("desc:handoff-give"),
        (
            _peer_key_sexp(bytes([0x42] * 32)),
            _ocapn_peer_no_hints("memory", "exporter"),
            bytes([0xCC] * 32),  # gifter-exporter session id (32 bytes)
            bytes([0x11] * 32),  # gifter-side public identifier (32 bytes)
            bytes([0x01] * 32),  # gift-id (32 bytes)
        ),
    )


def op_handoff_give() -> Record:
    """``<desc:sig-envelope <desc:handoff-give …> <sig-val …>>``.

    Stage 2 / ADR-0009 wire shape for a Gifter-signed
    ``desc:handoff-give`` envelope: the spec-canonical
    ``desc:sig-envelope`` wrapping the 5-field handoff-give
    certificate plus the gcrypt-canonical signature s-expression.
    """
    return Record(
        Symbol("desc:sig-envelope"),
        (
            _handoff_give_record(),
            _signature_sexp(bytes([0xAA] * 64)),
        ),
    )


def op_handoff_receive() -> Record:
    """``<desc:sig-envelope <desc:handoff-receive receiving-session
    receiving-side handoff-count <signed-give>> <sig-val …>>``.

    Stage 2 / ADR-0009 wire shape for a Receiver-signed
    ``desc:handoff-receive`` envelope. The ``signed-give`` slot
    nests the same ``desc:sig-envelope``-wrapped ``desc:handoff-give``
    structure as the ``op_handoff_give.bin`` fixture, but with a
    fresh inner-Gifter signature byte pattern (``0xAA``) and
    an outer Receiver signature byte pattern (``0xBB``), matches
    pancake's ``ocapn_tests::handoff_receive_roundtrips_through_syrup``.
    """
    nested_signed_give = Record(
        Symbol("desc:sig-envelope"),
        (
            _handoff_give_record(),
            _signature_sexp(bytes([0xAA] * 64)),
        ),
    )
    inner_receive = Record(
        Symbol("desc:handoff-receive"),
        (
            bytes([0xDD] * 32),  # receiving-session
            bytes([0x22] * 32),  # receiving-side
            1,                    # handoff-count
            nested_signed_give,
        ),
    )
    return Record(
        Symbol("desc:sig-envelope"),
        (
            inner_receive,
            _signature_sexp(bytes([0xBB] * 64)),
        ),
    )


def op_deliver_withdraw_gift() -> Record:
    """``<op:deliver <desc:export 0> [<symbol withdraw-gift>
    <desc:sig-envelope <desc:handoff-receive …>
    <desc:sig-envelope <desc:handoff-give …> <sig-val r/s>>
    <sig-val r/s>>] 99 #f>``.

    Stage 2 / ADR-0009 § Receiver side step 8 wire shape: the
    Receiver invokes ``withdraw-gift`` on the Exporter's bootstrap
    object (`<desc:export 0>`) carrying a `desc:sig-envelope`-wrapped
    `desc:handoff-receive` certificate as the second ``op:deliver``
    arg. The argument is pancake's ``Argument::Handoff`` variant
    per the model extension that landed alongside ADR-0009; on the
    wire it is the spec-canonical envelope itself (no extra
    wrapper), so the field-position 4 ``resolve-me-desc`` slot
    stays ``#f`` in this fixture (the Exporter resolves through
    the regular ``Message::Resolve`` path on next, or through
    the resolver-callback ``op:deliver`` on V1\\_0; either way the
    fixture's wire bytes don't depend on which the runtime
    chooses).

    Inner field bytes match ``op_handoff_receive`` so a single
    Goblins-Racket ↔ Python ↔ pancake parity assertion exercises
    the cross-implementation byte shape of both shapes at once;
    only the outer ``op:deliver`` envelope differs.
    """
    nested_signed_give = Record(
        Symbol("desc:sig-envelope"),
        (
            _handoff_give_record(),
            _signature_sexp(bytes([0xAA] * 64)),
        ),
    )
    inner_receive = Record(
        Symbol("desc:handoff-receive"),
        (
            bytes([0xDD] * 32),  # receiving-session
            bytes([0x22] * 32),  # receiving-side
            1,                    # handoff-count
            nested_signed_give,
        ),
    )
    signed_receive = Record(
        Symbol("desc:sig-envelope"),
        (
            inner_receive,
            _signature_sexp(bytes([0xBB] * 64)),
        ),
    )
    target = Record(Symbol("desc:export"), (0,))
    args = [Symbol("withdraw-gift"), signed_receive]
    return Record(Symbol("op:deliver"), (target, args, 99, False))


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


# ── ADR-0006 op:start-session handshake fixture ─────────


def op_start_session_v1_0() -> Record:
    """``<op:start-session "1.0" <public-key …> <ocapn-peer …> <sig-val …>>``.

    Goblins's `(define-recordable-struct op:start-session
    (captp-version handoff-pubkey acceptable-location
    acceptable-location-sig))` at `goblins/ocapn/captp.rkt:185-191`.
    Four-field record: the V1_0 wire version string ``"1.0"``, the
    per-session Ed25519 verifying key as the gcrypt s-expression, the
    ``acceptable-location`` ``<ocapn-peer>`` record, and the
    location signature s-expression. Byte patterns (``0xAA`` pubkey,
    ``0xCC`` signature) are fixture placeholders matching the
    Goblins-Racket sibling + the pancake-side `wire_vector_fixtures`
    assertion.
    """
    return Record(
        Symbol("op:start-session"),
        (
            "1.0",
            _peer_key_sexp(bytes([0xAA] * 32)),
            _ocapn_peer_no_hints("memory", "exporter"),
            _signature_sexp(bytes([0xCC] * 64)),
        ),
    )


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
    "op_handoff_give.bin": op_handoff_give,
    "op_handoff_receive.bin": op_handoff_receive,
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
