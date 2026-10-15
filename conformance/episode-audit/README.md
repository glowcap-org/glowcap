# conformance/episode-audit

Audits the Episodes that the accountability-on-Goblins worked example
generates. The result is application-layer evidence for accountability adapter
design, not a reference for the glowcap wire protocol.

## Running

1. Generate accountability output:

   ```sh
   ( cd conformance/accountability-on-goblins && racket racket/kernel.rkt )
   ```

2. Audit it:

   ```sh
   bash conformance/episode-audit/run.sh
   ```

## Posture

- The audit reads `conformance/accountability-on-goblins/.data/`.
- `Episode` is host and application evidence. No glowcap layer owns Episode
  vocabulary, and the Zig protocol core stays free of it.
