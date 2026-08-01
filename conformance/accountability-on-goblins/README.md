# conformance/accountability-on-goblins

Worked accountability application on Spritely Goblins: KERI-anchored identity,
signed invocation Episodes, and a local transparency log over Episode hashes. It
is plain Racket on top of Goblins; it does not modify Spritely Goblins and it is
not part of pancake's protocol core.

## Why It Lives Here

This application is external conformance pressure for the kind of host software
pancake supports; the worked application
[`accountability-on-pancake/`](../../apps/accountability-on-pancake/)
runs the same shape on pancake itself. It exercises three concerns above CapTP:

1. networked capability invocation;
2. identity material bound to a peer;
3. an observation point that emits a signed Episode for each invocation.

This implementation uses Goblins for the runtime. Pancake's core remains
codec-neutral CapTP; the pancake port in `apps/accountability-on-pancake/` wraps the
caller-owned `Peer` boundary rather than pushing Episode/KERI vocabulary into
the protocol core.

## Files

| File                                           | Role                                          |
| ---------------------------------------------- | --------------------------------------------- |
| `racket/kernel.rkt`                            | Single-process accountability loop.           |
| `racket/accountable-three-vat-demo.rkt`        | Three-peer introduction with signed Episodes. |
| `racket/audit.rkt`                             | Racket-side audit of generated Episodes.      |
| `racket/identity.rkt`                          | KERI primitives in Racket.                    |
| `racket/episode.rkt`                           | Episode emission.                             |
| `racket/log.rkt`                               | Local transparency log.                       |
| [`racket/doc/KERNEL.md`](racket/doc/KERNEL.md) | Human-readable kernel walkthrough.            |

## Generated State

`.data/` (written by the kernel and three-vat demos) and `racket/tests/.data/`
(written by `raco test`) are runtime outputs. If fixture data is committed for a
scenario, it must be named as a fixture in that scenario's docs; ordinary demo
output should stay generated state.

The initial commit landed one round of that output before the rule above was
written, so twenty KERI secret keys (`.data/keys/*.sk`) and their key event
logs are in the repository's history. They are demo material the kernel
generated on one machine, they hold authority over nothing outside these
scenarios, and nothing needs rotating. They are named here rather than quietly
dropped, because a reader who finds key material in a project that publishes a
security policy deserves to be told what it is instead of discovering it.
Regenerate the tree by running the kernel demo below; the directory is ignored
now, so a fresh run stays out of the index.

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

- Devcontainer-only: Racket/Goblins and crypto libraries come from the committed
  devcontainer.
- Editable worked example: change it when it stops teaching the right boundary.
- Not in `zig build check`: it informs design and external conformance pressure,
  but does not gate pancake's protocol core.
