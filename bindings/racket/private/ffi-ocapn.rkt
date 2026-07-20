#lang racket/base
;; Internal: the raw `ffi/unsafe` loader for libpancake_ocapn, the core archive.
;;
;; Nothing here is public. This surface binds the library-level `pancake_*`
;; family the binding consumes: the ABI version and per-thread last error, the
;; managed-frame release every archive's frames free through, the OCapN
;; locator URI grammar, and the exporter location-record encoder gifter
;; origination feeds. The wire itself rides the byte-fed host archive
;; (`ffi-driver.rkt`); the raw `pancake_peer_*` family stays a C-consumer
;; surface with no Racket wrapper. This loader opens ONLY libpancake_ocapn:
;; the universal base usable alone (ADR-0059). The transport archives have
;; their own loaders (`ffi-tcp.rkt`, `ffi-inproc.rkt`, `ffi-iroh.rkt`), each
;; opening only its own symbol-disjoint archive, so requiring the core pulls
;; in no transport.
;;
;; The bound functions and their out-cell wrappers are generated from the
;; archive's annotated symbol inventory (`ffi-ocapn-gen.rkt`, `zig build
;; gen-binding-racket-ffi`); this module owns the prose and re-provides them
;; together with the shared cstruct vocabulary. Out-params are fresh
;; caller-owned cells inside the generated wrappers.
(require "ffi-ocapn-gen.rkt"
         "ffi-shared.rkt")
;; Re-export the shared cstruct vocabulary so a module that requires this loader
;; has the layouts the bound functions read and write.
(provide (all-from-out "ffi-shared.rkt")
         (all-from-out "ffi-ocapn-gen.rkt"))
