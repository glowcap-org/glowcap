#lang racket/base
;; Internal: the raw `ffi/unsafe` loader for libpancake_net_transport_inproc.
;;
;; Nothing here is public; `../pancake-inproc.rkt` is the ergonomic surface over
;; it. This loader opens ONLY the in-process transport archive (ADR-0059): it
;; carries the `pancake_inproc_*` family plus its own thread-local last-error,
;; symbol-disjoint from libpancake_ocapn and from the TCP archive. Requiring it
;; loads no other archive. The in-process netlayer is socket-free — two peers in
;; one process wired by pipes — so accept and the frame reads block the calling
;; thread; `#:blocking? #t` lets the Racket scheduler and GC run while one parks,
;; so other green threads keep going. The `_fun` signatures name the shared frame
;; cstructs from `ffi-shared.rkt`.
;;
;; Out-params are fresh caller-owned cells inside the public wrappers.
(require ffi/unsafe
         ffi/unsafe/define
         "ffi-shared.rkt"
         "lib-resolve.rkt")
(provide (except-out (all-defined-out)
                     pancake_inproc_netlayer_new*
                     pancake_inproc_connect*
                     pancake_inproc_listen*
                     pancake_inproc_accept*))

(define inproc-lib (open-pancake-archive "pancake_net_transport_inproc"))

(define-ffi-definer define-pancake-inproc inproc-lib)
;; The in-process transport archive carries the `pancake_inproc_*` family plus
;; its own thread-local last-error, read through `pancake_inproc_last_error`.
(define-pancake-inproc pancake_inproc_last_error (_fun _pointer _size -> _size))
(define-pancake-inproc pancake_inproc_netlayer_new*
  (_fun _pointer -> _int32)
  #:c-id pancake_inproc_netlayer_new)
(define pancake_inproc_netlayer_new (wrap-out1 pancake_inproc_netlayer_new* _pointer #f))
(define-pancake-inproc pancake_inproc_netlayer_release (_fun _pointer -> _void))
;; connect/accept/read/write may park the calling thread on the in-process
;; pipes, so #:blocking? keeps the rest of the place running while one waits.
(define-pancake-inproc pancake_inproc_connect*
  (_fun #:blocking? #t _pointer _pointer _size _uint32 _size _pointer -> _int32)
  #:c-id pancake_inproc_connect)
(define pancake_inproc_connect (wrap-out1 pancake_inproc_connect* _pointer #f))
(define-pancake-inproc pancake_inproc_listen*
  (_fun _pointer _pointer _size _pointer -> _int32)
  #:c-id pancake_inproc_listen)
(define pancake_inproc_listen (wrap-out1 pancake_inproc_listen* _pointer #f))
(define-pancake-inproc pancake_inproc_accept*
  (_fun #:blocking? #t _pointer _uint32 _size _pointer -> _int32)
  #:c-id pancake_inproc_accept)
(define pancake_inproc_accept (wrap-out1 pancake_inproc_accept* _pointer #f))
(define-pancake-inproc pancake_inproc_conn_read_frame
  (_fun #:blocking? #t _pointer _PancakeManagedFrame-pointer -> _int32))
(define-pancake-inproc pancake_inproc_conn_write_frame
  (_fun #:blocking? #t _pointer _PancakeFrame-pointer -> _int32))
(define-pancake-inproc pancake_inproc_conn_release (_fun _pointer -> _void))
(define-pancake-inproc pancake_inproc_listener_release (_fun _pointer -> _void))
