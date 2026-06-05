# reference/tests/ocapn-conformance/

End-to-end test scenario: run the [OCapN conformance suite](https://github.com/ocapn/ocapn-test-suite)
against an OCapN peer over `tcp-testing-only` (or `onion`).

This is a **scenario**, not an implementation. The suite itself is the
upstream submodule at [`upstream/`](upstream/); the wrapper here
(`pixi.toml`, `run.sh`) is pancake's invocation harness. The peer
under test lives elsewhere — by default
[`reference/implementations/goblins-peer/`](../../implementations/goblins-peer/)'s
`seven-caps-peer.rkt`; eventually a pancake conformance peer.

## Layout

```
ocapn-conformance/
├── README.md                  ← this file
├── pixi.toml                  ← pixi project manifest (deps + tasks)
├── pixi.lock                  ← committed lockfile pinning the conda env
├── run.sh                     ← thin wrapper for `pixi run <task>`
└── upstream/                  ← submodule → github.com/ocapn/ocapn-test-suite
```

The `upstream/` directory is the git submodule and is treated as
read-only. Wrapper bits (this README, `pixi.toml`, `run.sh`) live at
the parent so they survive submodule pin bumps.

## What the suite tests

The suite drives a target implementation via a closed list of named
test capabilities the implementation must register at known
swiss-nums. See [`upstream/README.md`](upstream/README.md) (after the
submodule is initialised) for the canonical descriptions; the short list:

| Cap                 | Swiss num                          | Exercises                                  |
| ------------------- | ---------------------------------- | ------------------------------------------ |
| Car Factory builder | `JadQ0++RzsD4M+40uLxTWVaVqM10DcBJ` | Bootstrap fetch + cap creation             |
| Car Factory         | (returned by builder)              | Sequence args + cap-result-list            |
| Car                 | (spawned by factory)               | Method dispatch + symbol args              |
| Echo GC             | `IO58l1laTyhcrgDKbEzFOO32MDd6zE5w` | Variadic args + GC of unreferenced returns |
| Greeter             | `VMDDd1voKWarCe2GvgLbxbVFysNzRPzx` | Cap-passing in args + promise-discard GC   |
| Promise resolver    | `IokCxYmMj04nos2JN1TDoY1bT8dXh6Lr` | `fulfill` / `break` shapes                 |
| Sturdyref enlivener | `gi02I1qghIwPiKGKleCQAOhpy3ZtYRpB` | Outbound dial + enliven                    |

Test categories, one Python module each (`upstream/tests/`):

- `op_start_session.py` — handshake (Ed25519-signed `op:start-session`,
  rejection of bad versions / sigs).
- `op_deliver.py` — message dispatch, cap-passing, answer-pos /
  resolve-me-desc semantics.
- `op_abort.py` — session teardown.
- `op_listen.py` — promise listening.
- `op_gc.py` — garbage collection of imports, exports, answers.
- `third_party_handoffs.py` — three-vat handoff (Carol → Alice → Bob)
  with `desc:sig-envelope` / `desc:handoff-give` / `desc:handoff-receive`.

## Running

### Against the goblins-peer seven-caps target (canonical sanity check)

```bash
# Terminal 1: long-running goblins peer with the 7 caps registered.
bash reference/implementations/goblins-peer/stack/run.sh seven-caps-peer

# Terminal 2: point the suite at the URL Terminal 1 printed.
bash reference/tests/ocapn-conformance/run.sh test \
    'ocapn://JadQ0++RzsD4M+40uLxTWVaVqM10DcBJ.tcp-testing-only?host=127.0.0.1&port=22045'
```

The suite passing here exercises (a) the suite itself, (b) our pixi
wrapper, (c) Spritely Goblins's CapTP, and (d) our `tcp-netlayer.rkt`.
A green run is the baseline; anything red is upstream / wrapper /
netlayer breakage, not pancake breakage.

**Don't expect 100% green.** No OCapN implementation passes the entire
suite cleanly today — the spec, the suite, and the implementations
co-evolve.

### Against a pancake conformance peer

> **Status: intentionally not interoperable.** The Python suite
> dials `ocapn://<designator>.tcp-testing-only?...`; pancake's
> production transports are `tcp-tls` / `tcp-tls-pinned` per
> ADR-0027
> § Conformance impact, with no `tcp-testing-only` equivalent.
> `pancake-conformance-peer` is a pancake↔pancake fixture and the
> Python suite cannot dial it.
>
> The Stage 4 closure achievement is preserved below as the
> contemporaneous benchmark. Pancake's *current* OCapN-conformance
> claim runs through three different axes — cross-impl byte
> fixtures at [`reference/tests/syrup-byte-fixtures-goblins/`](../syrup-byte-fixtures-goblins/),
> the pancake↔pancake conformance peer's behavioral coverage in
> [`crates/testing/pancake-conformance-peer/`](../../../crates/testing/pancake-conformance-peer/),
> and spec-adherence per [`docs/design/supported-operations.md`](../../../docs/design/supported-operations.md).
> Re-establishing Python-suite interop would require an
> implementation of `tcp-testing-only` (out of scope; the
> transport's unencrypted-by-design posture is the reason it was
> retired).

#### Scoreboard (Stage 4 close, 2026-05-14 — historical)

**22 of 24 suite tests passed against `pancake-conformance-peer`
deterministically across 5+ consecutive full-suite runs at Stage 4
close** (when pancake still spoke `tcp-testing-only`, before
ADR-0027
retired the transport).
The 2 remaining were documented suite-side issues needing upstream
PRs (`op_abort.test_abort_before_setup`,
`op_gc.test_gc_answer`).

| Module | Status |
| --- | --- |
| `tests.op_start_session.test_captp_remote_version` | ✅ pass |
| `tests.op_start_session.test_start_session_with_invalid_signature` | ✅ pass |
| `tests.op_start_session.test_start_session_with_invalid_version` | ✅ pass |
| `tests.op_start_session.test_crossed_hellos_mitigation_aborts_inbound` | ✅ pass — locator-keyed `CrossedHellosRegistry` per ADR-0018 (supersedes ADR-0016: detection on partner `acceptable_location`, byte-lower **PeerId** rule comparing OUR-outbound vs THEIR-outbound Public Identifiers, one-shot abort channel through new `AsyncEndpoint::shutdown` for clean writer-half flush). |
| `tests.op_start_session.test_crossed_hellos_mitigation_outbound_aborts` | ✅ pass — symmetric InboundLoses path through the same ADR-0018 substrate. |
| `tests.op_abort.test_abort_before_setup` | 🟡 pancake's wire behavior is correct; suite-side `assertRaises` tuple missing `BrokenPipeError`. Upstream PR: [`ocapn/ocapn-test-suite#37`](https://github.com/ocapn/ocapn-test-suite/pull/37) |
| `tests.op_deliver.test_send_deliver_no_answer_or_response` | ✅ pass — Greeter cap |
| `tests.op_deliver.test_deliver_with_resolver` | ✅ pass — Echo cap (V1_0 resolver-callback) |
| `tests.op_deliver.test_deliver_promise_pipeline` | ✅ pass — Car Factory family + answer-pos pipelining (runtime now requeues pipelined-on-resolved-Near onto `Peer::local_deliveries` for adapter dispatch) |
| `tests.op_deliver.test_promise_pipeline_with_break` | ✅ pass — pipelined-on-broken propagates the break through `resolve_me_desc` |
| `tests.op_listen.test_op_listen_to_promise_and_fulfill` | ✅ pass |
| `tests.op_listen.test_op_listen_to_promise_and_break` | ✅ pass |
| `tests.op_listen.test_op_listen_already_has_answer` | ✅ pass — Promise resolver caches resolution; listen-after-resolve fires immediately |
| `tests.op_gc.test_gc_export_emitted_single_object` | ✅ pass — session bumps inbound-deliver imports; conformance peer auto-emits `op:gc-exports` after each cap dispatch |
| `tests.op_gc.test_gc_export_with_multiple_refrences` | ✅ pass |
| `tests.op_gc.test_gc_export_with_multiple_refrences_in_different_messages` | ✅ pass |
| `tests.op_gc.test_gc_answer` | 🟡 suite-side `AttributeError: 'bool' object has no attribute 'to_syrup_record'`. Needs upstream PR. |
| `tests.third_party_handoffs.HandoffRemoteAsExporter.*` (4) | ✅ pass — Exporter dispatch wired through `pancake-tokio::peer::handoff` (`recognize_deposit_gift` / `recognize_withdraw_gift` / `validate_inbound_signed_receive`). Per-binary gift store + cross-session partner-pubkey lookup in `pancake-conformance-peer::handoff_store`; `HandoffSharedState` cloned-by-Arc into each `caps::SessionState`. Wait-deposit-then-withdraw uses an `mpsc::UnboundedSender` to fire parked vows from the depositing G↔E task into the waiting R↔E task. |
| `tests.third_party_handoffs.HandoffRemoteAsGifter.*` (1) | ✅ pass — Sturdyref enlivener cap grows a Gifter mode (triggered when `resolve_me_desc` is present): looks up the sturdyref's location in the per-binary `session_by_location` registry (`partner_acceptable_location`-keyed), drives that G↔E session via `CrossSessionRequest::FetchAndAwait` → `DepositGift`, builds + signs `HandoffGive` with the G↔E secret, fires the SignedGive rmd-callback back through THIS R↔G session via the connection's self-loopback `request_tx`. New `Peer::partner_acceptable_location` field is populated by `open_session_async` post-handshake. |
| `tests.third_party_handoffs.HandoffRemoteAsReciever.*` (2) | ✅ pass — Greeter cap recognizes `Argument::Handoff(Give(signed_give))`, validates `recipient_key`, spawns task that dials the Exporter, signs `desc:handoff-receive` with this session's R↔G secret (per spec § Checking the signature on the desc:handoff-receive — NOT the new e2r secret), populates `receiving_session` / `receiving_side` from the new e2r session, and sends `op:deliver bootstrap [Symbol("withdraw-gift"), …]`. |

The pipelined-on-resolved redirect (actor-model seam in
`Peer::local_deliveries`) and the answer-pos-0 spec-compatibility
relaxation (the OCapN spec and Goblins admit answer-pos 0) are
load-bearing for the `op_deliver.test_deliver_promise_pipeline`
family.

### Smoke / shell

```bash
bash reference/tests/ocapn-conformance/run.sh smoke   # confirm the env resolves
bash reference/tests/ocapn-conformance/run.sh shell   # Python REPL inside upstream/
```

The first invocation materializes the conda env into `./.pixi/`
(gitignored) — pinned Python 3.12, `cryptography>=42`, and `stem>=1.8`
from conda-forge, lockfile-tracked at `pixi.lock`. Install pixi with
`brew install pixi` or `curl -fsSL https://pixi.sh/install.sh | bash`.

## Refreshing the upstream pin

```bash
cd reference/tests/ocapn-conformance/upstream
git fetch
git checkout origin/HEAD                # or a specific tag / SHA
cd -
git add reference/tests/ocapn-conformance/upstream
git commit -m "reference/tests/ocapn-conformance: bump upstream pin"
```

`run.sh` and `pixi.toml` are pancake's; they don't change when the
submodule pin moves (unless upstream restructures).

## Posture

- **External code, read-only.** Apache 2.0 — see `upstream/LICENSE`.
- **pancake's docs gate skips this entire subtree** per
  [`reference/README.md`](../../README.md). Internal links inside
  the upstream files are not pancake's link gate to enforce.
- **No pancake substrate dependency.** Nothing in `crates/` knows this
  directory exists.

## Links

- [Upstream repository](https://github.com/ocapn/ocapn-test-suite)
- [`upstream/README.md`](upstream/README.md) — canonical suite docs (post-init)
- [`upstream/LICENSE`](upstream/LICENSE) — Apache 2.0 (post-init)
- [`../../implementations/goblins-peer/`](../../implementations/goblins-peer/) — the conformance target peer
- [`../../README.md`](../../README.md) — directory-level posture
- [`../../bootstrap-submodules.sh`](../../bootstrap-submodules.sh) — first-time setup
