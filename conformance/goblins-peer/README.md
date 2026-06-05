# reference/implementations/goblins-peer/

> **Runtime.** Devcontainer-only. First task invocation lazy-installs
> Racket Minimal 8.16 + Spritely Goblins via
> [`tools/non-pixi-lazy-install/`](../../../tools/non-pixi-lazy-install/);
> cached in the `pancake-non-pixi-lazy-install` named volume.

A slim Spritely Goblins **OCapN peer** packaged for use from pancake.
Just enough Racket + Goblins to host an OCapN/CapTP peer pancake can
dial — over fake-intarwebs (in-process), over real TCP loopback, or as
a long-running peer registering the seven canonical conformance caps
the [`reference/tests/ocapn-conformance/`](../../tests/ocapn-conformance/)
suite expects.

This is **not** Spritely Goblins itself ([`reference/implementations/spritely-goblins/upstream/`](../spritely-goblins/) is the canonical
upstream); it's the small wrapper of demo + peer code pancake needs to
have a Goblins-shape peer reachable for interop work.

## Files

| File | What it does |
| --- | --- |
| `racket/tcp-netlayer.rkt` | Custom Spritely Goblins netlayer that speaks CapTP over real TCP sockets. `(ocapn-node 'tcp "host:port" #f)` addressing. Optional `#:trace` callback observes accept / connect events. |
| `racket/captp-demo.rkt` | Two Goblins peers in this process exchanging a real OCapN message via Spritely's CapTP, wired through `goblins/ocapn/netlayer/fake-intarwebs`. Proves the Goblins peer is CapTP-capable; replacing the netlayer is what swaps in a real network. |
| `racket/tcp-demo.rkt` | Same shape as `captp-demo.rkt` but uses `tcp-netlayer.rkt` — bytes flow through real TCP on `127.0.0.1` instead of an in-process pipe. Exits after a single roundtrip. |
| `racket/three-vat-demo.rkt` | Three real TCP peers (Alice, Bob, Carol), each on its own port. Proves OCapN three-party introduction empirically — instrumented netlayer asserts Carol dials Bob *directly* after Alice introduces them, with Alice out of the data path. The "OCapN exec" property. Exits after assertions. |
| `racket/seven-caps-peer.rkt` | **Long-running** peer registering the seven canonical conformance caps (Car Factory builder, Car Factory, Car, Echo GC, Greeter, Promise Resolver, Sturdyref Enlivener) at the swiss-nums [`reference/tests/ocapn-conformance/`](../../tests/ocapn-conformance/) expects. Adapted from upstream `spritely-goblins/upstream/misc/ocapn-test-suite.scm` (Apache 2.0) with the onion netlayer swapped for `tcp-netlayer.rkt` so loopback testing works without Tor. |
| `stack/run.sh` | Single-command launcher (no `cd` required); thin wrapper around `pixi run` against `stack/pixi.toml`. |
| `stack/pixi.toml` | pixi project manifest declaring the scenario's tasks (`seven-caps-peer`, `run`, `shell`). Tasks invoke `racket` natively against `../racket/`. |

## Adjacent directories (don't confuse)

| Looking for...                                                                                | Look here                                                                                                              |
| --------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| Spritely Goblins itself                                                                       | [`../spritely-goblins/upstream/`](../spritely-goblins/upstream/) (pinned via submodule)                                |
| KERI / signed-Episode / transparency-log accountability work that uses Goblins as a substrate | [`../accountability-on-goblins/`](../accountability-on-goblins/) (worked example *on top of* a Goblins-or-pancake peer) |
| The conformance suite that dials this peer                                                    | [`../../tests/ocapn-conformance/`](../../tests/ocapn-conformance/) (this directory is the *target*, not the suite)     |

## Running

```bash
bash reference/implementations/goblins-peer/stack/run.sh seven-caps-peer            # long-running conformance target

# Other demos — each exits after a single roundtrip / assertion run.
bash reference/implementations/goblins-peer/stack/run.sh run captp-demo.rkt         # in-process CapTP via fake-intarwebs
bash reference/implementations/goblins-peer/stack/run.sh run tcp-demo.rkt           # two-peer CapTP-over-TCP
bash reference/implementations/goblins-peer/stack/run.sh run three-vat-demo.rkt     # three-party introduction
```

To target the conformance suite at this peer:

```bash
# Terminal 1: start the long-running peer.
bash reference/implementations/goblins-peer/stack/run.sh seven-caps-peer

# Terminal 2: read the URL it printed, point the suite at it. Both
# processes share the devcontainer's localhost, so 127.0.0.1 reaches
# straight across.
bash reference/tests/ocapn-conformance/run.sh test \
    'ocapn://JadQ0++RzsD4M+40uLxTWVaVqM10DcBJ.tcp-testing-only?host=127.0.0.1&port=22045'
```

## How pancake uses this

- **As an interop target.** `pancake-codec-syrup` rides production netlayers (`tcp-tls`, `tcp-tls-pinned`, `iroh`); this peer is what pancake's interop tests dial. Goblins emits canonical OCapN bytes; if pancake parses them and replies bytes Goblins accepts, codec-level interop is real.
- **As the conformance-suite target** — the `seven-caps-peer.rkt` is the same shape Spritely uses; passing the suite against it is a sanity-check that the suite + our pixi/Docker wrapper + our TCP netlayer all compose correctly.
- **As a wire-shape lookup.** When `pancake-codec-syrup` needs to know "what does Goblins emit for op:start-session?" the answer is: run this peer with [`tcp-demo.rkt`](racket/tcp-demo.rkt), tcpdump the loopback, see the Syrup bytes.

## Posture

- **External code, lightly modified.** The `tcp-netlayer.rkt` and demos are pancake-authored on top of the Spritely Goblins API. `seven-caps-peer.rkt` is a port of upstream Spritely's reference under Apache 2.0.
- **Editable.** Demos are demos; modify, replace, extend without ceremony. The cap behaviors in `seven-caps-peer.rkt` must stay byte-for-byte compatible with the suite's expectations — change them only if the suite changes.
- **Not in pancake's link gate** — see [`reference/README.md`](../../README.md).

## Links

- [`stack/pixi.toml`](stack/pixi.toml) — pixi tasks
- [`../spritely-goblins/`](../spritely-goblins/) — upstream Goblins submodule
- [`../../tests/ocapn-conformance/`](../../tests/ocapn-conformance/) — the suite this peer is the target for
- [Spritely Institute — Goblins](https://spritely.institute/goblins/)
