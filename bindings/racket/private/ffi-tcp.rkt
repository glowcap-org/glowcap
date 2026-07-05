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
(require ffi/unsafe
         ffi/unsafe/define
         racket/runtime-path
         "ffi-shared.rkt")
(provide (all-defined-out))

(define-runtime-path tcp-lib-path "../../../zig-out/lib/libpancake_net_transport_tcp")
(define tcp-lib (pancake-ffi-lib "pancake_net_transport_tcp" (path->string tcp-lib-path)))

(define-ffi-definer define-pancake-tcp tcp-lib)
;; The TCP transport archive carries the `pancake_tcp_*` family plus its own
;; thread-local last-error: a tcp call's diagnostic is read through
;; `pancake_tcp_last_error`, never the ocapn family's `pancake_last_error`.
(define-pancake-tcp pancake_tcp_last_error (_fun _pointer _size -> _size))
(define-pancake-tcp pancake_tcp_netlayer_new (_fun (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-pancake-tcp pancake_tcp_netlayer_release (_fun _pointer -> _void))
;; connect/accept/read/write park the calling thread on the socket, so
;; #:blocking? lets the Racket scheduler and GC run while one waits, other
;; green threads keep going instead of the place freezing.
(define-pancake-tcp pancake_tcp_connect
  (_fun #:blocking? #t _pointer _pointer _size _uint16 _uint32 _size (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-pancake-tcp pancake_tcp_listen
  (_fun _pointer _pointer _size _uint16 (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-pancake-tcp pancake_tcp_listener_port
  (_fun _pointer (out : (_ptr o _uint16)) -> (r : _int32) -> (values r out)))
(define-pancake-tcp pancake_tcp_accept
  (_fun #:blocking? #t _pointer _uint32 _size (out : (_ptr o _pointer)) -> (r : _int32) -> (values r out)))
(define-pancake-tcp pancake_tcp_conn_read_frame (_fun #:blocking? #t _pointer _PancakeManagedFrame-pointer -> _int32))
(define-pancake-tcp pancake_tcp_conn_write_frame (_fun #:blocking? #t _pointer _PancakeFrame-pointer -> _int32))
(define-pancake-tcp pancake_tcp_conn_release (_fun _pointer -> _void))
(define-pancake-tcp pancake_tcp_listener_release (_fun _pointer -> _void))
