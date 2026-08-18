#lang racket/base
;; Internal: the raw `ffi/unsafe` loader for libpancake_net_transport_inproc.
;;
;; Nothing here is public; `../pancake-inproc.rkt` is the ergonomic surface over
;; it. This loader opens ONLY the in-process transport archive (ADR-0059): it
;; carries the `pancake_inproc_*` family plus its own thread-local last-error,
;; symbol-disjoint from libpancake_ocapn and from the TCP archive. Requiring it
;; loads no other archive. The in-process netlayer is socket-free — two peers in
;; one process wired by pipes — so accept and the frame reads block the calling
;; thread; the generated `#:blocking?` marks keep the runtime GC-cooperative
;; during the park (they do not free the place's green threads — this one-call
;; surface is driven single-threaded).
;;
;; The bound functions and their out-cell wrappers are generated from the
;; archive's annotated symbol inventory (`ffi-inproc-gen.rkt`, `zig build
;; gen-binding-racket-ffi`); this module owns the prose and re-provides them.
(require ffi/unsafe
         "ffi-shared.rkt"
         "ffi-inproc-gen.rkt")
(provide (except-out (all-from-out "ffi-inproc-gen.rkt")
                     pancake_inproc_connect*
                     pancake_inproc_accept*
                     pancake_inproc_conn_read_frame*
                     pancake_inproc_conn_write_frame*
                     pancake_inproc_listener_release*)
         pancake_inproc_connect
         pancake_inproc_accept
         pancake_inproc_conn_read_frame
         pancake_inproc_conn_write_frame
         pancake_inproc_listener_release)

(define (pancake_inproc_connect netlayer designator designator-len codec max-frame)
  (call/out _pointer #f
            (lambda (out)
              (call/without-diagnostic pancake_inproc_connect*
                                       netlayer designator designator-len codec
                                       max-frame out))))

(define (pancake_inproc_accept listener codec max-frame)
  (call/out _pointer #f
            (lambda (out)
              (call/without-diagnostic pancake_inproc_accept*
                                       listener codec max-frame out))))

(define (pancake_inproc_conn_read_frame conn frame)
  (call/without-diagnostic pancake_inproc_conn_read_frame* conn frame))

(define (pancake_inproc_conn_write_frame conn frame)
  (call/without-diagnostic pancake_inproc_conn_write_frame* conn frame))

(define (pancake_inproc_listener_release listener)
  (call/without-diagnostic pancake_inproc_listener_release* listener))
