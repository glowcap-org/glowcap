# conformance/ocapn-conformance

Native wrapper for the upstream
[OCapN test suite](https://github.com/ocapn/ocapn-test-suite). The suite lives
in the `upstream/` submodule; this directory owns only the invocation wrapper.

## Setup

Initialize submodules once:

```sh
bash conformance/bootstrap-submodules.sh
```

The wrapper runs through `uv`; no pixi or conda environment is part of this
repo's current flow.

## Running

Start a target peer, then point the suite at the OCapN URL it prints. For the
bundled Goblins target:

```sh
# Terminal 1
bash conformance/goblins-peer/run.sh seven-caps-peer

# Terminal 2
bash conformance/ocapn-conformance/run.sh test \
  'ocapn://JadQ0++RzsD4M+40uLxTWVaVqM10DcBJ.tcp-testing-only?host=127.0.0.1&port=22045'
```

Useful wrapper checks:

```sh
bash conformance/ocapn-conformance/run.sh smoke
bash conformance/ocapn-conformance/run.sh shell
```

## What This Proves

The suite is external conformance pressure. A green run against
`goblins-peer/` proves the upstream suite, the native wrapper, the slim Goblins
target, and its testing TCP netlayer compose. It is not the `zig build check`
gate and it is not the semantic oracle for Zig code by itself.

Pancake's in-tree gate remains `zig build oracle-check` / `zig build check`.
Those gates cover the checked protocol scenarios and pancake-authored Syrup
fixtures consumed by the Zig implementation.

## Posture

- `upstream/` is read-only. Bump the submodule pin; do not edit it in place.
- `run.sh` is pancake-owned and should stay a thin native wrapper.
- `tcp-testing-only` is a conformance/testing transport, not a production
  transport claim.
