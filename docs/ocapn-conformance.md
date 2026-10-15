---
type: living
description: Every section of the pinned OCapN CapTP draft with the wire profile that speaks it, the check that proves it, and a fingerprint that fails the row when the text moves.
sources:
  - resource: /conformance/ocapn-spec/upstream/draft-specifications/CapTP Specification.md
  - resource: /tools/check/source_check/docs/ocapn_conformance.zig
---

# OCapN conformance manifest

glowcap implements the OCapN CapTP draft at one pinned commit of
`conformance/ocapn-spec/upstream`, read from
`draft-specifications/CapTP Specification.md`. The draft has no tagged
releases, so that commit is the reference for the V1.0 profile. For each
section of it, the table says which profile speaks the section as written and
which check proves it.

`zig build source-check` holds the table against the pinned file. It fails on
a section without a row, a row without a section, an evidence step that
`docs/build-steps.md` does not list, and a fingerprint that no longer matches
the section's text. Moving the pin therefore fails exactly the rows whose text
changed.

The table covers the second-level sections under Cryptography, The bootstrap
Object, Operations, and Descriptors. The hello and the cryptography it signs
are shared by both profiles, because a peer sends its hello before it knows
which profile the partner speaks
([ADR-0103](decisions/adr/ADR-0103-hello-carried-profile-offers.md)), so
those rows move only when a Goblins release speaks the new text. Every other
section can move in `glowcap-next` first. Merged text past the pin and the
work it implies are on [upstream watch](upstream-watch.md) and the
[roadmap](roadmap.md#ocapn-direction).

- **Section** is the draft heading, in code font when the draft writes it that
  way.
- **Profile** says which wire profile sends and accepts the section as the
  pinned text writes it: `1.0`, `next`, `both`, or `none`. A `none` row means
  glowcap follows pinned Goblins where it disagrees with the text, and
  [upstream watch](upstream-watch.md) names the disagreement.
- **Evidence** lists the build steps that exercise the section, each written
  as the command that runs it, then an optional committed fixture. `none`
  marks a gap.
- **Text** is the first 12 hex characters of the SHA-256 of the section's
  bytes, from its heading line up to the next line that starts a first- or
  second-level heading or the end of the file, without trailing newlines.
  After a pin bump, read each section the check names, confirm the Profile and
  Evidence cells still hold, and copy the new fingerprint from the message.

| Section | Profile | Evidence | Text |
| --- | --- | --- | --- |
| Public Key | both | `zig build ocapn-conformance`, `zig build goblins-interop` | 6e5e7a811469 |
| Public Identifier | both | `zig build ocapn-conformance`, `zig build goblins-interop` | 2132ca400439 |
| Session ID | both | `zig build ocapn-conformance`, `zig build goblins-interop` | 43ba3f2cb6e6 |
| Signature | both | `zig build oracle-check`, `zig build ocapn-conformance`, `test/oracle/corpus/desc_handoff_give_signed.bin` | c7cefd71b21b |
| `fetch` | both | `zig build ocapn-conformance`, `zig build goblins-interop` | 425140fdacea |
| `deposit-gift` | both | `zig build ocapn-conformance`, `zig build goblins-exporter` | 33610c512e08 |
| `withdraw-gift` | both | `zig build ocapn-conformance`, `zig build goblins-exporter`, `test/oracle/corpus/op_deliver_withdraw_gift.bin` | baef21b57d9f |
| `op:start-session` | both | `zig build oracle-check`, `zig build ocapn-conformance`, `zig build goblins-interop`, `test/oracle/corpus/op_start_session_v1_0.bin` | 5f16627d665c |
| `op:deliver` | 1.0 | `zig build oracle-check`, `zig build ocapn-conformance`, `zig build goblins-interop`, `test/oracle/corpus/op_deliver.bin` | e3f8cbfaa2cd |
| `op:abort` | both | `zig build oracle-check`, `zig build ocapn-conformance`, `test/oracle/corpus/op_abort.bin` | 74f1ff26a307 |
| `op:listen` | none | `zig build oracle-check`, `zig build ocapn-conformance`, `zig build ocapn-findings-check`, `test/oracle/corpus/op_listen_promise_target.bin` | 9c1d700a9ec3 |
| `op:get` | both | `zig build oracle-check`, `zig build goblins-interop`, `test/oracle/corpus/op_get.bin` | 6a30915dd692 |
| `op:index` | both | `zig build oracle-check`, `zig build goblins-interop`, `test/oracle/corpus/op_index.bin` | 05d41e7f9325 |
| `op:untag` | both | `zig build oracle-check`, `test/oracle/corpus/op_untag.bin` | 03ed0549f76a |
| `op:gc-exports` | both | `zig build oracle-check`, `zig build ocapn-conformance`, `zig build goblins-gc`, `test/oracle/corpus/op_gc_exports.bin` | ba257d22dbdb |
| `op:gc-answers` | both | `zig build oracle-check`, `zig build ocapn-conformance`, `zig build goblins-gc`, `test/oracle/corpus/op_gc_answers.bin` | 1cff19c14cf6 |
| `desc:import-object` | both | `zig build ocapn-conformance`, `zig build goblins-interop` | bd4c29950636 |
| `desc:import-promise` | both | `zig build ocapn-conformance`, `zig build goblins-interop` | e7bec9baf689 |
| `desc:export` | both | `zig build oracle-check`, `zig build ocapn-conformance`, `zig build goblins-interop` | 3774fe4d56d5 |
| `desc:answer` | both | `zig build ocapn-conformance`, `zig build goblins-interop` | aa0e37267eb1 |
| `desc:sig-envelope` | both | `zig build oracle-check`, `zig build ocapn-conformance`, `test/oracle/corpus/desc_handoff_give_signed.bin` | b7328dcfd45a |
| `desc:handoff-give` | both | `zig build oracle-check`, `zig build ocapn-conformance`, `zig build goblins-handoff`, `zig build goblins-gift`, `test/oracle/corpus/desc_handoff_give_signed.bin` | 4e783157af9c |
| `desc:handoff-receive` | both | `zig build oracle-check`, `zig build ocapn-conformance`, `zig build goblins-handoff`, `test/oracle/corpus/desc_handoff_receive_signed.bin` | ccd6bca5fecb |
