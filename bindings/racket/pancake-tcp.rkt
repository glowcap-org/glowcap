#lang racket/base
;; pancake/tcp — the blocking TCP transport for the pancake Racket binding.
;;
;; Mirrors the à-la-carte archive split (ADR-0059): this module is
;; libpancake_net_transport_tcp's binding, the explicit netlayer/listener/endpoint
;; handles for cleartext, loopback-grade TCP. Its private loader
;; (`private/ffi-tcp.rkt`) opens ONLY that archive, so requiring this module
;; never links a transport you do not use. It builds on the core peer and value
;; machinery in `pancake.rkt` through the shared transport seam
;; (`private/seam.rkt`) — they share the `PancakeContext` pointer and frame
;; layout but no symbol — so a TCP consumer composes the two:
;;
;;   (require "pancake.rkt")
;;   (require "pancake-tcp.rkt")
;;
;;   (define nl (make-netlayer))
;;   (define lst (netlayer-listen nl "127.0.0.1" 0))
;;   (define cn (netlayer-connect nl "127.0.0.1" (listener-port lst)))
;;   (endpoint-write-frame! cn frame) ; the host owns the peer and shuttles frames
;;
;; This is the explicit blocking handle for the I/O backend: the host reads a
;; frame, feeds it to its peer, steps, takes outbound frames, and writes them
;; back. The async, scheduler-friendly path over Racket's own ports lives in the
;; core's `async-connection` / `connect` / `listen`; this module is the direct
;; C-ABI netlayer beneath it.

(require ffi/unsafe
         "private/constants.rkt"
         "private/ffi-tcp.rkt"
         "private/seam.rkt")

(provide make-netlayer netlayer-release! netlayer-listen netlayer-connect
         listener-port listener-accept listener-release!
         endpoint-read-frame endpoint-write-frame! endpoint-release!
         tcp-last-error)

;; (tcp-last-error) -> the calling thread's last error message from the TCP
;; transport archive (`libpancake_net_transport_tcp`), or #f. The transport keeps
;; its own thread-local slot, so a tcp call's diagnostic is read here and never
;; from the ocapn family's `last-error`. Query the length first (NULL buffer),
;; then read.
(define (tcp-last-error)
  (define len (pancake_tcp_last_error #f 0))
  (cond
    [(zero? len) #f]
    [else
     (define buf (make-bytes (+ len 1)))
     (define written (pancake_tcp_last_error buf (+ len 1)))
     (bytes->string/utf-8 (subbytes buf 0 (min written len)) #\uFFFD)]))

;; Raise the shared typed `exn:fail:pancake` for a non-OK tcp code, reading this
;; archive's own last-error rather than the unrelated ocapn-family one.
(define (check/tcp code) (check-with code tcp-last-error))

(struct netlayer (handle) #:mutable)
(struct listener (handle) #:mutable)
(struct endpoint (handle) #:mutable)

(define (make-netlayer)
  (define-values (rc h) (pancake_tcp_netlayer_new))
  (check/tcp rc)
  (define nl (netlayer h))
  (register-finalizer nl (lambda (q) (netlayer-release! q)))
  nl)

(define (netlayer-release! nl)
  (when (netlayer-handle nl)
    (pancake_tcp_netlayer_release (netlayer-handle nl))
    (set-netlayer-handle! nl #f)))

(define (netlayer-listen nl host [port 0])
  (define bs (string->bytes/utf-8 host))
  (define-values (rc h) (pancake_tcp_listen (netlayer-handle nl) (pin-immobile bs) (bytes-length bs) port))
  (check/tcp rc)
  (define lst (listener h))
  (register-finalizer lst (lambda (q) (listener-release! q)))
  lst)

(define (netlayer-connect nl host port [codec 'syrup] [max-frame 4096])
  (define bs (string->bytes/utf-8 host))
  (define-values (rc h) (pancake_tcp_connect (netlayer-handle nl) (pin-immobile bs) (bytes-length bs) port (codec-id codec) max-frame))
  (check/tcp rc)
  (define cn (endpoint h))
  (register-finalizer cn (lambda (q) (endpoint-release! q)))
  cn)

(define (listener-port lst)
  (define-values (rc port) (pancake_tcp_listener_port (listener-handle lst)))
  (check/tcp rc)
  port)

(define (listener-accept lst [codec 'syrup] [max-frame 4096])
  (define-values (rc h) (pancake_tcp_accept (listener-handle lst) (codec-id codec) max-frame))
  (check/tcp rc)
  (define cn (endpoint h))
  (register-finalizer cn (lambda (q) (endpoint-release! q)))
  cn)

(define (listener-release! lst)
  (when (listener-handle lst)
    (pancake_tcp_listener_release (listener-handle lst))
    (set-listener-handle! lst #f)))

(define (endpoint-read-frame cn)
  (define mf (make-PancakeManagedFrame #f 0 0 #f #f))
  (check/tcp (pancake_tcp_conn_read_frame (endpoint-handle cn) mf))
  (define out (bytes<-c (PancakeManagedFrame-bytes mf) (PancakeManagedFrame-len mf)))
  (pancake_managed_frame_release mf)
  out)

(define (endpoint-write-frame! cn frame)
  (define buf (pin-immobile frame))
  (check/tcp (pancake_tcp_conn_write_frame (endpoint-handle cn) (make-PancakeFrame buf (bytes-length frame) FRAME-SHAPE-BYTE))))

(define (endpoint-release! cn)
  (when (endpoint-handle cn)
    (pancake_tcp_conn_release (endpoint-handle cn))
    (set-endpoint-handle! cn #f)))
