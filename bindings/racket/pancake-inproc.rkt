#lang racket/base
;; pancake/inproc — the socket-free in-process transport for the Racket binding.
;;
;; Mirrors the à-la-carte archive split (ADR-0059): this module is
;; libpancake_net_transport_inproc's binding, the in-process sibling of the TCP
;; connections (`pancake-tcp.rkt`). Two sessions in one process are wired by
;; pipes, with no kernel transport. The listener exposes a wake descriptor for
;; scheduler integration; no application bytes flow through it. Its private loader
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
         ffi/unsafe/port
         "private/constants.rkt"
         "private/ffi-inproc.rkt"
         "private/finalizer-diagnostics.rkt"
         "private/locator.rkt"
         "private/native-parent.rkt"
         "private/seam.rkt"
         "private/transport.rkt")

(provide inproc-locator inproc-connector
         make-inproc-netlayer inproc-netlayer-release!
         inproc-netlayer-listen inproc-netlayer-connect
         inproc-listener-readiness-fd inproc-listener-accept inproc-listener-release!
         inproc-connection-read-frame inproc-connection-write-frame! inproc-connection-release!
         inproc-last-error)

(define (inproc-locator designator)
  (locator TRANSPORT-INPROC designator (hash) 'boolean-false))

;; (inproc-last-error) -> the calling thread's last error message from the
;; in-process transport archive (`libpancake_net_transport_inproc`), or #f. The
;; transport keeps its own thread-local slot, so an inproc call's diagnostic is
;; read here and never from the ocapn family's `last-error`. Query the length
;; first (NULL buffer), then read.
(define (inproc-last-error) (read-last-error pancake_inproc_last_error))

;; Raise the shared typed `exn:fail:pancake` for a non-OK inproc code, reading
;; this archive's own last-error rather than the unrelated ocapn-family one.
(define (check/inproc code) (check-with code inproc-last-error))

(struct inproc-netlayer (owner))
(struct inproc-listener (handle fd accept-gate closing netlayer) #:mutable)
(struct inproc-connection (handle read-gate write-gate netlayer) #:mutable)

(define (inproc-netlayer-forget! nl child)
  (native-parent-forget! (inproc-netlayer-owner nl) child))

;; A designator is any opaque token; accept a string and pass its bytes.
(define (designator-bytes designator)
  (if (bytes? designator) designator (string->bytes/utf-8 designator)))

(define (make-inproc-netlayer)
  (define-values (rc h) (pancake_inproc_netlayer_new))
  (check/inproc rc)
  (define nl (inproc-netlayer (make-native-parent h pancake_inproc_netlayer_release)))
  (register-finalizer nl (lambda (q) (inproc-netlayer-release! q)))
  nl)

(define (inproc-connector)
  (make-byte-connector
   (list TRANSPORT-INPROC)
   (lambda (m loc handshake-timeout-ms)
     (define nl (make-inproc-netlayer))
     (define cn #f)
     (define (close!)
       (when cn (inproc-connection-release! cn) (set! cn #f))
       (inproc-netlayer-release! nl))
     (with-handlers ([(lambda (_) #t) (lambda (e) (close!) (raise e))])
       (set! cn (inproc-netlayer-connect nl (locator-designator loc)))
       (define transport
         (async-transport
          (lambda (frame) (inproc-connection-write-frame! cn frame))
          void
          (lambda (_wake-evt) (inproc-connection-read-frame cn))
          close!))
       (establish-dialed-locator-session
        m loc transport
        #:handshake-timeout-ms handshake-timeout-ms)))))

(define (inproc-netlayer-release! nl)
  (native-parent-release!
   (inproc-netlayer-owner nl)
   (lambda (child)
     (cond [(inproc-listener? child) (inproc-listener-release! child)]
           [(inproc-connection? child) (inproc-connection-release! child)]))))

(define (inproc-netlayer-listen nl designator)
  (define bs (designator-bytes designator))
  (define lst
    (native-parent-open-child
     (inproc-netlayer-owner nl) 'inproc-netlayer-listen
     (lambda (parent-handle)
       (define-values (rc h)
         (pancake_inproc_listen parent-handle (pin-immobile bs) (bytes-length bs)))
       (check/inproc rc)
       (define-values (fd-rc fd) (pancake_inproc_listener_readiness_fd h))
       (with-handlers
           ([exn?
             (lambda (e)
               (define cleanup
                 (with-handlers ([exn? values])
                   (check/inproc (pancake_inproc_listener_release h))
                   #f))
               (raise (if cleanup (retain-cleanup-failure e cleanup) e)))])
         (check/inproc fd-rc))
       (inproc-listener h fd (make-semaphore 1) (make-semaphore 0) nl))
     inproc-listener-release!))
  (register-finalizer
   lst
   (lambda (q)
     (run-native-finalizer! "inproc-listener.finalize"
                            (lambda () (inproc-listener-release! q))
                            #:layer 'transport)))
  lst)

(define (inproc-netlayer-connect nl designator [codec 'syrup] [max-frame 4096])
  (define bs (designator-bytes designator))
  (define cn
    (native-parent-open-child
     (inproc-netlayer-owner nl) 'inproc-netlayer-connect
     (lambda (parent-handle)
       (define-values (rc h)
         (pancake_inproc_connect parent-handle (pin-immobile bs) (bytes-length bs)
                                 (codec-id codec) max-frame))
       (check/inproc rc)
       (inproc-connection h (make-semaphore 1) (make-semaphore 1) nl))
     inproc-connection-release!))
  (register-finalizer cn (lambda (q) (inproc-connection-release! q)))
  cn)

(define (inproc-listener-accept lst [codec 'syrup] [max-frame 4096])
  (call-with-semaphore
   (inproc-listener-accept-gate lst)
   (lambda ()
     ;; The listener exposes a wake channel for this otherwise fd-less transport.
     ;; The gate makes readiness plus accept one indivisible consumer operation:
     ;; a sibling accepter parks here and re-arms readiness after this one, so it
     ;; can never enter the blocking FFI call on a readiness edge already spent.
     (define fd (inproc-listener-readiness-fd lst))
     (define ready (unsafe-file-descriptor->semaphore fd 'read))
     (unless ready (error 'inproc-listener-accept "inproc listener fd ~a is not pollable" fd))
     (define outcome
       (sync (handle-evt ready (lambda (_) 'ready))
             (handle-evt (semaphore-peek-evt (inproc-listener-closing lst))
                         (lambda (_) 'closing))))
     (when (eq? outcome 'closing)
       (error 'inproc-listener-accept "listener is closed"))
     (define-values (rc h) (pancake_inproc_accept (inproc-listener-handle lst) (codec-id codec) max-frame))
     (check/inproc rc)
     (define nl (inproc-listener-netlayer lst))
     (define cn
       (native-parent-adopt-or-release!
        (inproc-netlayer-owner nl)
        (inproc-connection h (make-semaphore 1) (make-semaphore 1) nl)
        inproc-connection-release!
        'inproc-listener-accept))
     (register-finalizer cn (lambda (q) (inproc-connection-release! q)))
     cn)))

(define (inproc-listener-readiness-fd lst)
  (or (inproc-listener-fd lst) (error 'inproc-listener-readiness-fd "listener is closed")))

(define (inproc-listener-release! lst)
  (when (inproc-listener-handle lst)
    (semaphore-post (inproc-listener-closing lst))
    (pancake_inproc_listener_shutdown (inproc-listener-handle lst))
    (call-with-semaphore
     (inproc-listener-accept-gate lst)
     (lambda ()
       (when (inproc-listener-handle lst)
         (unsafe-file-descriptor->semaphore (inproc-listener-readiness-fd lst) 'remove)
         (define release-code (pancake_inproc_listener_release (inproc-listener-handle lst)))
         (set-inproc-listener-handle! lst #f)
         (set-inproc-listener-fd! lst #f)
         (inproc-netlayer-forget! (inproc-listener-netlayer lst) lst)
         (check/inproc release-code))))))

;; Block for one whole frame's bytes, or `eof` on a graceful end of stream.
(define (inproc-connection-read-frame cn)
  (call-with-semaphore
   (inproc-connection-read-gate cn)
   (lambda ()
     (define h (inproc-connection-handle cn))
     (unless h (error 'inproc-connection-read-frame "connection is closed"))
     (define mf (make-PancakeManagedFrame #f 0 0 #f #f))
     (define code (pancake_inproc_conn_read_frame h mf))
     (cond
       [(= code ERR-CLOSED) eof]
       [else
        (check/inproc code)
        (dynamic-wind
         void
         (lambda ()
           (bytes<-c (PancakeManagedFrame-bytes mf) (PancakeManagedFrame-len mf)))
         (lambda () (pancake_managed_frame_release mf)))]))))

(define (inproc-connection-write-frame! cn frame)
  (call-with-semaphore
   (inproc-connection-write-gate cn)
   (lambda ()
     (define h (inproc-connection-handle cn))
     (unless h (error 'inproc-connection-write-frame! "connection is closed"))
     (define buf (pin-immobile frame))
     (check/inproc (pancake_inproc_conn_write_frame h (make-PancakeFrame buf (bytes-length frame) FRAME-SHAPE-BYTE))))))

(define (inproc-connection-release! cn)
  (when (inproc-connection-handle cn)
    (pancake_inproc_conn_shutdown (inproc-connection-handle cn))
    (call-with-semaphore
     (inproc-connection-read-gate cn)
     (lambda ()
       (call-with-semaphore
        (inproc-connection-write-gate cn)
        (lambda ()
          (when (inproc-connection-handle cn)
            (pancake_inproc_conn_release (inproc-connection-handle cn))
            (set-inproc-connection-handle! cn #f)
            (inproc-netlayer-forget! (inproc-connection-netlayer cn) cn))))))))
