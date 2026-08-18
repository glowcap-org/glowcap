#lang racket/base
;; Internal: the raw `ffi/unsafe` loader for libpancake_net_transport_tcp.
;;
;; Nothing here is public; `../pancake-tcp.rkt` is the ergonomic surface over it.
;; This loader opens ONLY the TCP transport archive (ADR-0059): it carries the
;; `pancake_tcp_*` family plus its own thread-local last-error, symbol-disjoint
;; from libpancake_ocapn. Requiring it loads no other archive, a program that
;; never touches TCP never links it. The `_fun` signatures name the shared frame
;; cstructs from `ffi-shared.rkt`, which the TCP and core archives agree on by
;; layout; reading a frame back through `pancake_managed_frame_release` is a core
;; call, so the public module reaches that through the core seam, not here.
;;
;; The bound functions and their out-cell wrappers are generated from the
;; archive's annotated symbol inventory (`ffi-tcp-gen.rkt`, `zig build
;; gen-binding-racket-ffi`); this module owns the prose and re-provides them.
;; connect/accept/read/write park the calling thread on the socket; the
;; generated `#:blocking?` marks keep the runtime GC-cooperative during the
;; park (they do not free the place's green threads — this one-call surface
;; is driven single-threaded). Netlayer shutdown cancels a connect owned by a
;; different native thread before parent release joins it.
(require ffi/unsafe
         "ffi-shared.rkt"
         "ffi-tcp-gen.rkt")
(provide (except-out (all-from-out "ffi-tcp-gen.rkt")
                     pancake_tcp_connect*
                     pancake_tcp_accept*
                     pancake_tcp_conn_read_frame*
                     pancake_tcp_conn_write_frame*
                     pancake_tcp_conn_release*)
         pancake_tcp_connect
         pancake_tcp_accept
         pancake_tcp_conn_read_frame
         pancake_tcp_conn_write_frame
         pancake_tcp_conn_release)

(define (pancake_tcp_connect netlayer host host-len port options codec max-frame)
  (call/out _pointer #f
            (lambda (out)
              (call/without-diagnostic pancake_tcp_connect*
                                       netlayer host host-len port options codec
                                       max-frame out))))

(define (pancake_tcp_accept listener options codec max-frame)
  (call/out _pointer #f
            (lambda (out)
              (call/without-diagnostic pancake_tcp_accept*
                                       listener options codec max-frame out))))

(define (pancake_tcp_conn_read_frame conn frame)
  (call/without-diagnostic pancake_tcp_conn_read_frame* conn frame))

(define (pancake_tcp_conn_write_frame conn frame)
  (call/without-diagnostic pancake_tcp_conn_write_frame* conn frame))

(define (pancake_tcp_conn_release conn)
  (call/without-diagnostic pancake_tcp_conn_release* conn))
