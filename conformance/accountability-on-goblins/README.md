# conformance/accountability-on-goblins

Worked accountability application on Spritely Goblins: KERI-anchored identity,
signed invocation Episodes, and a local transparency log over Episode hashes. It
is plain Racket on top of Goblins, leaves Spritely Goblins unmodified, and is
not part of glowcap's protocol core.

## Why it lives here

This application is an external check on the kind of host software
glowcap supports. The worked application
[`accountability-on-glowcap/`](../../apps/accountability-on-glowcap/)
runs the same shape on glowcap itself. It exercises three concerns above CapTP:

1. networked capability invocation
2. identity material bound to a peer
3. an observation point that emits a signed Episode for each invocation.

This implementation uses Goblins for the runtime. glowcap's core is
codec-neutral CapTP. The glowcap port in `apps/accountability-on-glowcap/` wraps the
caller-owned `Peer` boundary and keeps Episode/KERI vocabulary out of the
protocol core.

## Files

| File                                           | Role                                          |
| ---------------------------------------------- | --------------------------------------------- |
| `racket/kernel.rkt`                            | Single-process accountability loop.           |
| `racket/accountable-three-vat-demo.rkt`        | Three-peer introduction with signed Episodes. |
| `racket/audit.rkt`                             | Racket-side audit of generated Episodes.      |
| `racket/identity.rkt`                          | KERI primitives in Racket.                    |
| `racket/episode.rkt`                           | Episode emission.                             |
| `racket/log.rkt`                               | Local transparency log.                       |
| `racket/shapes/episode.ttl`                    | SHACL shape naming every property an Episode carries. Nothing validates against it. |
| [`racket/doc/KERNEL.md`](racket/doc/KERNEL.md) | Human-readable kernel walkthrough.            |

## Generated State

`.data/` (written by the kernel and three-vat demos) and `racket/tests/.data/`
(written by `raco test`) are runtime outputs. Fixture data committed for a
scenario is named as a fixture in that scenario's docs. Ordinary demo output
stays generated state.

Twenty KERI secret keys (`.data/keys/*.sk`) and their key event logs remain in
the repository's history, from one round of output committed before this rule
existed. The kernel generated them on one machine as demo material. They hold
authority over nothing outside these scenarios, and nothing needs rotating. The
working tree carries none of it: both directories are ignored, and the kernel
demo below regenerates them.

## Running

The kernel writes `.data/` to the current directory, and the audit and keri
scenarios read `conformance/accountability-on-goblins/.data/`, so run the
generators from the app directory (the subshells below keep your shell at the
repo root):

```sh
# 8-step kernel demo.
( cd conformance/accountability-on-goblins && racket racket/kernel.rkt )

# Rackunit tests.
raco test conformance/accountability-on-goblins/racket/tests/kernel-test.rkt

# Three-party introduction + signed Episodes.
( cd conformance/accountability-on-goblins && racket racket/accountable-three-vat-demo.rkt )
```

Verify outputs with sibling scenarios:

```sh
bash conformance/episode-audit/run.sh
bash conformance/keri-conformance/run.sh --fixture sample-kel
```

## Posture

- Racket, Goblins, and the crypto libraries come from the committed
  devcontainer, so it runs only there.
- It is a worked example: change it when it stops teaching the right boundary.
- It is not in `zig build check`. It informs design and gates nothing in
  glowcap's protocol core.
