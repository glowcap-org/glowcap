#lang racket/base
;; pancake/inproc — the socket-free in-process transport for the Racket binding.
;;
;; Mirrors the à-la-carte archive split (ADR-0059): this module is
;; libpancake_net_transport_inproc's binding, the in-process sibling of the TCP
;; endpoints (`pancake-tcp.rkt`). Two sessions in one process are wired by
;; pipes, with no kernel transport and no file descriptors. Its private loader
;; (`private/ffi-inproc.rkt`) opens ONLY that archive, so requiring this module
;; links neither the TCP nor the iroh transport. It builds on the core value
;; and error machinery in `pancake.rkt` through the shared transport seam
;; (`private/seam.rkt`) — same frame layout, no shared symbol:
;;
;;   (require "pancake.rkt")
;;   (require "pancake-inproc.rkt")
;;
;;   (define nl (make-inproc-netlayer))
;;   (define lst (inproc-netlayer-listen nl "rendezvous"))
;;   (define cn (inproc-netlayer-connect nl "rendezvous"))
;;
;; A listener binds to a string designator — any opaque token, not a host:port —
;; and a dialer names that designator. The embedder shuttles whole frames over
;; the pipe exactly as with TCP. Blocking; in-process only.

(require ffi/unsafe
         "private/constants.rkt"
         "private/ffi-inproc.rkt"
         "private/seam.rkt")

(provide make-inproc-netlayer inproc-netlayer-release!
         inproc-netlayer-listen inproc-netlayer-connect
         inproc-listener-accept inproc-listener-release!
         inproc-endpoint-read-frame inproc-endpoint-write-frame! inproc-endpoint-release!
         inproc-last-error)

;; (inproc-last-error) -> the calling thread's last error message from the
;; in-process transport archive (`libpancake_net_transport_inproc`), or #f. The
;; transport keeps its own thread-local slot, so an inproc call's diagnostic is
;; read here and never from the ocapn family's `last-error`. Query the length
;; first (NULL buffer), then read.
(define (inproc-last-error) (read-last-error pancake_inproc_last_error))

;; Raise the shared typed `exn:fail:pancake` for a non-OK inproc code, reading
;; this archive's own last-error rather than the unrelated ocapn-family one.
(define (check/inproc code) (check-with code inproc-last-error))

(struct inproc-netlayer (handle) #:mutable)
(struct inproc-listener (handle) #:mutable)
(struct inproc-endpoint (handle) #:mutable)

;; A designator is any opaque token; accept a string and pass its bytes.
(define (designator-bytes designator)
  (if (bytes? designator) designator (string->bytes/utf-8 designator)))

(define (make-inproc-netlayer)
  (define-values (rc h) (pancake_inproc_netlayer_new))
  (check/inproc rc)
  (define nl (inproc-netlayer h))
  (register-finalizer nl (lambda (q) (inproc-netlayer-release! q)))
  nl)

(define (inproc-netlayer-release! nl)
  (when (inproc-netlayer-handle nl)
    (pancake_inproc_netlayer_release (inproc-netlayer-handle nl))
    (set-inproc-netlayer-handle! nl #f)))

(define (inproc-netlayer-listen nl designator)
  (define bs (designator-bytes designator))
  (define-values (rc h) (pancake_inproc_listen (inproc-netlayer-handle nl) (pin-immobile bs) (bytes-length bs)))
  (check/inproc rc)
  (define lst (inproc-listener h))
  (register-finalizer lst (lambda (q) (inproc-listener-release! q)))
  lst)

(define (inproc-netlayer-connect nl designator [codec 'syrup] [max-frame 4096])
  (define bs (designator-bytes designator))
  (define-values (rc h) (pancake_inproc_connect (inproc-netlayer-handle nl) (pin-immobile bs) (bytes-length bs) (codec-id codec) max-frame))
  (check/inproc rc)
  (define cn (inproc-endpoint h))
  (register-finalizer cn (lambda (q) (inproc-endpoint-release! q)))
  cn)

(define (inproc-listener-accept lst [codec 'syrup] [max-frame 4096])
  (define-values (rc h) (pancake_inproc_accept (inproc-listener-handle lst) (codec-id codec) max-frame))
  (check/inproc rc)
  (define cn (inproc-endpoint h))
  (register-finalizer cn (lambda (q) (inproc-endpoint-release! q)))
  cn)

(define (inproc-listener-release! lst)
  (when (inproc-listener-handle lst)
    (pancake_inproc_listener_release (inproc-listener-handle lst))
    (set-inproc-listener-handle! lst #f)))

;; Block for one whole frame's bytes, or `eof` on a graceful end of stream.
(define (inproc-endpoint-read-frame cn)
  (define mf (make-PancakeManagedFrame #f 0 0 #f #f))
  (define code (pancake_inproc_conn_read_frame (inproc-endpoint-handle cn) mf))
  (cond
    [(= code ERR-CLOSED) eof]
    [else
     (check/inproc code)
     (define out (bytes<-c (PancakeManagedFrame-bytes mf) (PancakeManagedFrame-len mf)))
     (pancake_managed_frame_release mf)
     out]))

(define (inproc-endpoint-write-frame! cn frame)
  (define buf (pin-immobile frame))
  (check/inproc (pancake_inproc_conn_write_frame (inproc-endpoint-handle cn) (make-PancakeFrame buf (bytes-length frame) FRAME-SHAPE-BYTE))))

(define (inproc-endpoint-release! cn)
  (when (inproc-endpoint-handle cn)
    (pancake_inproc_conn_release (inproc-endpoint-handle cn))
    (set-inproc-endpoint-handle! cn #f)))
