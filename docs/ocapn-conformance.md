---
type: living
description: Reviewed draft sections and upstream test sources with adoption states and evidence for each claimed profile.
sources:
  - resource: /conformance/ocapn-spec/upstream/draft-specifications/CapTP Specification.md
  - resource: /conformance/ocapn-conformance/upstream/
  - resource: /tools/check/source_check/docs/ocapn_conformance.zig
---

# OCapN conformance manifest

The specification pin tracks reviewed upstream text independently of what
glowcap implements. Moving it changes neither the opening grammar nor the
Goblins interoperability target. Each row records, against that text, the
adoption state of one draft section or upstream suite source.

- **Profile** names the wire profile the state applies to: `1.0`, `next`
  (`glowcap-next`), or `both`. A section whose row names only `next` keeps its
  Goblins-compatible shape on `1.0`.
- **State** is one of:
  - **adopted**: the profile implements the reviewed text, Evidence lists the
    build steps that exercise it, and Decision is `none`.
  - **deferred**: a deliberate exception. Decision names the repository
    Markdown file that owns the reason and the condition for reconsideration.
  - **pending**: implementation or proof remains. Decision names the file that
    owns the work.
- **Evidence** is `none` for deferred and pending rows, because a passing
  baseline check does not prove the deferred or pending behavior.
- **Text** is the first 12 lowercase hex characters of SHA-256 over the
  section, from its heading to the next first- or second-level heading,
  without trailing newlines. A suite row hashes the whole file the same way. A
  draft section that upstream removed keeps its row with Text `removed`, and
  its state records whether the profile has stopped accepting and emitting it.

`zig build ocapn-adoption-check` holds both tables complete and current.
`source-check` runs the same validation, and the TCP and onion suite steps
require it before starting a peer. A green check proves the accounting is
complete, not that any behavior conforms. Every build step a row names must
appear in `docs/build-steps.md`.

## Updating upstream references

1. Advance the spec or suite submodule, then run
   `zig build ocapn-adoption-check`.
2. Read every section or suite source the check names, including shared
   setup when no test module changed.
3. Update each affected row's state, evidence or decision, and fingerprint.
   Remove an obsolete suite row only after accounting for its lost coverage.
4. Run the evidence for adopted behavior and the baseline Goblins checks.
   Record an incompatible test as a deferral with its reason, never by
   dropping it.

## Draft review

Every top-level section and each of its second-level sections needs a row,
including sections upstream adds. The introduction, document links, history,
funding, and the draft warning are excluded as framing. Heading text inside
fenced examples stays in the fingerprint without creating section boundaries.

The hello and its crypto representations, including identifiers and signed
handoff records that depend on them, stay shared and deferred under
[the transition plan](planning/ocapn-crypto-version-handshake.md). The newer
operation contracts are adopted on next under
[ADR-0065](decisions/adr/ADR-0065-next-profile-operations.md). `1.0`
conversations keep the Goblins-compatible opening and operations, and this
table does not count them as current-draft conformance.

| Section | Profile | State | Evidence | Decision | Text |
| --- | --- | --- | --- | --- | --- |
| CapTP Overview | both | adopted | `zig build test` | none | d6f70e96056a |
| Establishing a connection | both | deferred | none | `docs/planning/ocapn-crypto-version-handshake.md` | 5d50ab18e82c |
| Sending and receiving messages | next | adopted | `zig build test`, `zig build ocapn-conformance-next` | none | 5b5347710d05 |
| Ending a session | both | adopted | `zig build test` | none | 91c405bb4b4f |
| Promises | both | adopted | `zig build test` | none | 44cfa92a7e5b |
| Promise and Resolver Objects | both | adopted | `zig build test` | none | 6a1de750e0dd |
| Promise pipelining | next | adopted | `zig build test`, `zig build ocapn-conformance-next` | none | b8c4436d2bb0 |
| Cryptography | both | deferred | none | `docs/planning/ocapn-crypto-version-handshake.md` | f155f1b82e8f |
| Public Key | both | deferred | none | `docs/planning/ocapn-crypto-version-handshake.md` | b2d3ae686b1d |
| Public Identifier | both | deferred | none | `docs/planning/ocapn-crypto-version-handshake.md` | 2132ca400439 |
| Session ID | both | deferred | none | `docs/planning/ocapn-crypto-version-handshake.md` | 43ba3f2cb6e6 |
| Signature | both | deferred | none | `docs/planning/ocapn-crypto-version-handshake.md` | 0d8e55d19a90 |
| Third Party Handoffs | both | adopted | `zig build test` | none | 6c28d6157a1b |
| Handoffs from the Gifter's perspective | both | deferred | none | `docs/planning/ocapn-crypto-version-handshake.md` | 726cc09f7bbf |
| Handoffs from the Receiver's perspective | both | deferred | none | `docs/planning/ocapn-crypto-version-handshake.md` | 2b4d5b679dca |
| Handoffs from the Exporter's perspective | both | deferred | none | `docs/planning/ocapn-crypto-version-handshake.md` | 0fbc3eeea350 |
| The bootstrap Object | both | adopted | `zig build test` | none | 3af421cbac01 |
| `fetch` | next | adopted | `zig build test`, `zig build ocapn-conformance-next` | none | 9a0a90077309 |
| `deposit-gift` | next | adopted | `zig build test`, `zig build ocapn-conformance-next` | none | db4d18d75a9b |
| `withdraw-gift` | both | deferred | none | `docs/planning/ocapn-crypto-version-handshake.md` | 2e7533f1c183 |
| Operations | both | adopted | `zig build test` | none | 8b26b571a1c1 |
| `op:start-session` | both | deferred | none | `docs/planning/ocapn-crypto-version-handshake.md` | 86ae02d05167 |
| `op:deliver-only` | next | adopted | `zig build test`, `zig build ocapn-conformance-next` | none | e604032ff445 |
| `op:deliver` | next | adopted | `zig build test`, `zig build ocapn-conformance-next` | none | 470a67a16c59 |
| `op:abort` | both | adopted | `zig build test`, `zig build oracle-check`, `zig build ocapn-conformance`, `test/oracle/corpus/op_abort.bin` | none | 74f1ff26a307 |
| `op:listen` | next | adopted | `zig build test`, `zig build ocapn-conformance-next` | none | d9e2f9da8ea7 |
| `op:gc-exports` | both | adopted | `zig build test`, `zig build oracle-check`, `zig build ocapn-conformance`, `zig build goblins-gc`, `test/oracle/corpus/op_gc_exports.bin` | none | ccb238956fb5 |
| `op:gc-answers` | both | adopted | `zig build test`, `zig build oracle-check`, `zig build ocapn-conformance`, `zig build goblins-gc`, `test/oracle/corpus/op_gc_answers.bin` | none | 1cff19c14cf6 |
| Descriptors | both | adopted | `zig build test` | none | 9724642c9b81 |
| `desc:import-object` | both | adopted | `zig build test`, `zig build ocapn-conformance`, `zig build goblins-interop` | none | bd4c29950636 |
| `desc:import-promise` | both | adopted | `zig build test`, `zig build ocapn-conformance`, `zig build goblins-interop` | none | e7bec9baf689 |
| `desc:export` | both | adopted | `zig build test`, `zig build oracle-check`, `zig build ocapn-conformance`, `zig build goblins-interop` | none | 3774fe4d56d5 |
| `desc:answer` | both | adopted | `zig build test`, `zig build ocapn-conformance`, `zig build goblins-interop` | none | aa0e37267eb1 |
| `desc:sig-envelope` | both | deferred | none | `docs/planning/ocapn-crypto-version-handshake.md` | 96a37a57b972 |
| `desc:handoff-give` | both | deferred | none | `docs/planning/ocapn-crypto-version-handshake.md` | 0243b7dd18c5 |
| `desc:handoff-receive` | both | deferred | none | `docs/planning/ocapn-crypto-version-handshake.md` | ccd6bca5fecb |
| `op:get` | next | adopted | `zig build test`, `zig build ocapn-conformance-next` | none | removed |
| `op:index` | next | adopted | `zig build test`, `zig build ocapn-conformance-next` | none | removed |
| `op:untag` | next | adopted | `zig build test`, `zig build ocapn-conformance-next` | none | removed |

## Upstream suite review

This table covers every Python source in the separately pinned suite: test
modules, shared session setup, message types, and netlayers. A shared hello
change therefore fails the check even when no test module moved.

The baseline TCP runner runs
all discovered test modules except `tests.op_abort`, replaced by the strict
portable abort probe. The next lane consumes these rows as execution policy: every
pending source blocks the run, a deferred module reports its decision, and an
adopted module must run without skips. The onion runner has its own exclusions.

`zig build ocapn-conformance-next` first runs the baseline lane, then the
adopted upstream assertions through a next wire fixture and locally written draft
cases. The fixture verifies a signed next offer using the retained hello,
requires draft delivery shapes, and chooses 32-byte gift IDs before signing.

| Suite source | Profile | State | Evidence | Decision | Text |
| --- | --- | --- | --- | --- | --- |
| `contrib/__init__.py` | 1.0 | adopted | `zig build ocapn-conformance` | none | 5bc573f9ff1a |
| `contrib/__init__.py` | next | adopted | `zig build ocapn-conformance-next` | none | 5bc573f9ff1a |
| `contrib/syrup.py` | 1.0 | adopted | `zig build ocapn-conformance` | none | 6d61d26e80e0 |
| `contrib/syrup.py` | next | adopted | `zig build ocapn-conformance-next` | none | 6d61d26e80e0 |
| `netlayers/__init__.py` | 1.0 | adopted | `zig build ocapn-conformance` | none | 5bc573f9ff1a |
| `netlayers/__init__.py` | next | adopted | `zig build ocapn-conformance-next` | none | 5bc573f9ff1a |
| `netlayers/base.py` | 1.0 | adopted | `zig build ocapn-conformance` | none | 717f4ba837eb |
| `netlayers/base.py` | next | adopted | `zig build ocapn-conformance-next` | none | 717f4ba837eb |
| `netlayers/onion.py` | 1.0 | adopted | `zig build ocapn-conformance-onion` | none | df3a7bb1b79e |
| `netlayers/onion.py` | next | deferred | none | `conformance/ocapn-conformance/README.md` | df3a7bb1b79e |
| `netlayers/testing_only_tcp.py` | 1.0 | adopted | `zig build ocapn-conformance` | none | 85e9156fef7f |
| `netlayers/testing_only_tcp.py` | next | adopted | `zig build ocapn-conformance-next` | none | 85e9156fef7f |
| `test_runner.py` | 1.0 | adopted | `zig build ocapn-conformance` | none | 735c7c1859c7 |
| `test_runner.py` | next | deferred | none | `conformance/ocapn-conformance/README.md` | 735c7c1859c7 |
| `tests/__init__.py` | 1.0 | adopted | `zig build ocapn-conformance` | none | 5bc573f9ff1a |
| `tests/__init__.py` | next | adopted | `zig build ocapn-conformance-next` | none | 5bc573f9ff1a |
| `tests/op_abort.py` | 1.0 | deferred | none | `conformance/ocapn-conformance/README.md` | 6e3e0b65cb5d |
| `tests/op_abort.py` | next | deferred | none | `conformance/ocapn-conformance/README.md` | 6e3e0b65cb5d |
| `tests/op_deliver.py` | 1.0 | adopted | `zig build ocapn-conformance` | none | 56b1a38c429e |
| `tests/op_deliver.py` | next | adopted | `zig build ocapn-conformance-next` | none | 56b1a38c429e |
| `tests/op_gc.py` | 1.0 | adopted | `zig build ocapn-conformance` | none | e9964a64c977 |
| `tests/op_gc.py` | next | adopted | `zig build ocapn-conformance-next` | none | e9964a64c977 |
| `tests/op_listen.py` | 1.0 | adopted | `zig build ocapn-conformance` | none | 11bd8e93613a |
| `tests/op_listen.py` | next | adopted | `zig build ocapn-conformance-next` | none | 11bd8e93613a |
| `tests/op_start_session.py` | 1.0 | adopted | `zig build ocapn-conformance` | none | ea082c57606d |
| `tests/op_start_session.py` | next | deferred | none | `docs/planning/ocapn-crypto-version-handshake.md` | ea082c57606d |
| `tests/third_party_handoffs.py` | 1.0 | adopted | `zig build ocapn-conformance` | none | 4d0e346e7d32 |
| `tests/third_party_handoffs.py` | next | adopted | `zig build ocapn-conformance-next` | none | 4d0e346e7d32 |
| `utils/__init__.py` | 1.0 | adopted | `zig build ocapn-conformance` | none | 5bc573f9ff1a |
| `utils/__init__.py` | next | adopted | `zig build ocapn-conformance-next` | none | 5bc573f9ff1a |
| `utils/captp.py` | 1.0 | adopted | `zig build ocapn-conformance` | none | ebe62cf2c565 |
| `utils/captp.py` | next | adopted | `zig build ocapn-conformance-next` | none | ebe62cf2c565 |
| `utils/captp_types.py` | 1.0 | adopted | `zig build ocapn-conformance` | none | 84e9c845a99a |
| `utils/captp_types.py` | next | adopted | `zig build ocapn-conformance-next` | none | 84e9c845a99a |
| `utils/netstrings.py` | 1.0 | adopted | `zig build ocapn-conformance` | none | d267731875b3 |
| `utils/netstrings.py` | next | adopted | `zig build ocapn-conformance-next` | none | d267731875b3 |
| `utils/ocapn_uris.py` | 1.0 | adopted | `zig build ocapn-conformance` | none | 3455f8b30867 |
| `utils/ocapn_uris.py` | next | adopted | `zig build ocapn-conformance-next` | none | 3455f8b30867 |
| `utils/test_suite.py` | 1.0 | adopted | `zig build ocapn-conformance` | none | 72a2a5fa4eba |
| `utils/test_suite.py` | next | adopted | `zig build ocapn-conformance-next` | none | 72a2a5fa4eba |
