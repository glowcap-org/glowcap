#lang racket/base
;; Internal: the raw `ffi/unsafe` loader for libpancake_net_transport_onion.
;;
;; Nothing here is public; `../pancake-onion.rkt` is the ergonomic surface over
;; it. This loader opens ONLY the onion transport archive (ADR-0059): it carries
;; the `pancake_onion_*` family plus its own thread-local last-error,
;; symbol-disjoint from libpancake_ocapn and from the other transports.
;; Requiring it loads no other archive.
;;
;; The onion netlayer reaches a Tor daemon the deployment already runs, so its
;; dial and accept park the calling thread for as long as a circuit takes, which
;; is seconds rather than milliseconds. The generated `#:blocking?` marks keep
;; the runtime GC-cooperative during that park. The readiness rows carry no mark
;; because they return at once: park on the descriptor they hand back and the
;; blocking rows are only entered when they will return. Netlayer shutdown is
;; the owner-level cancellation edge for a connect or listen already inside Tor.
;;
;; The bound functions and their out-cell wrappers are generated from the
;; archive's annotated symbol inventory (`ffi-onion-gen.rkt`, `zig build
;; gen-binding-racket-ffi`); this module owns the prose and re-provides them.
(require "ffi-onion-gen.rkt")
(provide (all-from-out "ffi-onion-gen.rkt"))
