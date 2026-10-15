#lang racket/base
;; Internal: the raw `ffi/unsafe` loader for libglowcap_net_transport_inproc.
;;
;; Nothing here is public; `../glowcap-inproc.rkt` is the ergonomic surface over
;; it. This loader opens ONLY the in-process transport archive (ADR-0059): it
;; carries the `glowcap_inproc_*` family plus its own thread-local last-error,
;; symbol-disjoint from libglowcap_ocapn and from the TCP archive. Requiring it
;; loads no other archive. The in-process netlayer is socket-free: two peers in
;; one process wired by pipes, so accept and the frame reads block the calling
;; thread; the generated `#:blocking?` marks keep the runtime GC-cooperative
;; during the park (they do not free the place's green threads: this one-call
;; surface is driven single-threaded).
;;
;; The bound functions and their out-cell wrappers are generated from the
;; archive's annotated symbol inventory (`ffi-inproc-gen.rkt`, `zig build
;; gen-binding-racket-ffi`); this module owns the prose and re-provides them.
(require ffi/unsafe
         "ffi-shared.rkt"
         "ffi-inproc-gen.rkt")
(provide (except-out (all-from-out "ffi-inproc-gen.rkt")
                     glowcap_inproc_connect*
                     glowcap_inproc_accept*
                     glowcap_inproc_conn_read_frame*
                     glowcap_inproc_conn_write_frame*
                     glowcap_inproc_listener_release*)
         glowcap_inproc_connect
         glowcap_inproc_accept
         glowcap_inproc_conn_read_frame
         glowcap_inproc_conn_write_frame
         glowcap_inproc_listener_release)

(define (glowcap_inproc_connect netlayer designator designator-len codec max-frame)
  (call/out _pointer #f
            (lambda (out)
              (call/without-diagnostic glowcap_inproc_connect*
                                       netlayer designator designator-len codec
                                       max-frame out))))

(define (glowcap_inproc_accept listener codec max-frame)
  (call/out _pointer #f
            (lambda (out)
              (call/without-diagnostic glowcap_inproc_accept*
                                       listener codec max-frame out))))

(define (glowcap_inproc_conn_read_frame conn frame)
  (call/without-diagnostic glowcap_inproc_conn_read_frame* conn frame))

(define (glowcap_inproc_conn_write_frame conn frame)
  (call/without-diagnostic glowcap_inproc_conn_write_frame* conn frame))

(define (glowcap_inproc_listener_release listener)
  (call/without-diagnostic glowcap_inproc_listener_release* listener))
