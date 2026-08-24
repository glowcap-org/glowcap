#lang racket/base
;; pancake/tcp — the blocking TCP transport for the pancake Racket binding.
;;
;; Mirrors the à-la-carte archive split (ADR-0059): this module is
;; libpancake_net_transport_tcp's binding, the explicit netlayer/listener/connection
;; handles for cleartext, loopback-grade TCP. Its private loader
;; (`private/ffi-tcp.rkt`) opens ONLY that archive, so requiring this module
;; never links a transport you do not use. It builds on the core value and
;; error machinery in `pancake.rkt` through the shared transport seam
;; (`private/seam.rkt`) — they share the frame layout but no symbol — so a TCP
;; consumer composes the two:
;;
;;   (require "pancake.rkt")
;;   (require "pancake-tcp.rkt")
;;
;;   (define nl (make-netlayer))
;;   (define lst (netlayer-listen nl "127.0.0.1" 0))
;;   (define cn (netlayer-connect nl "127.0.0.1" (listener-port lst)))
;;   (connection-write-frame! cn frame) ; the embedder shuttles whole frames
;;
;; This is the explicit blocking handle for the I/O backend: the embedder reads
;; a frame, feeds it to its byte-fed connection, and writes what the feed
;; drains back. The scheduler-friendly application path composes `tcp-provider`
;; or `tcp-connector` into a Runtime; this module also exposes the direct C-ABI
;; netlayer beneath it.

(require ffi/unsafe
         ffi/unsafe/port
         "private/constants.rkt"
         "private/ffi-tcp.rkt"
         "private/finalizer-diagnostics.rkt"
         "private/locator.rkt"
         "private/socket-address.rkt"
         "private/tcp-config.rkt"
         (only-in "private/tcp-provider.rkt"
                  tcp-provider tcp-connector)
         (only-in "private/tcp-listen.rkt"
                  server? server-host server-locator server-uri server-port
                  server-close! accept listen listen-keyed-tcp listen-noise-tcp)
         "private/native-parent.rkt"
         "private/seam.rkt")

(provide tcp-address-designator tcp-locator keyed-tcp-locator noise-tcp-locator
         tcp-provider tcp-connector
         make-tcp-keepalive (struct-out tcp-keepalive)
         make-tcp-stream-options (struct-out tcp-stream-options)
         make-tcp-config (struct-out tcp-config)
         make-tcp-options
         server? server-host server-locator server-uri server-port server-close!
         accept listen listen-keyed-tcp listen-noise-tcp
         make-netlayer netlayer-release! netlayer-listen netlayer-connect
         listener-port listener-readiness-fd listener-accept listener-release!
         connection-read-frame connection-write-frame! connection-release!
         tcp-last-error)

(define (tcp-locator host port)
  (locator TRANSPORT-TCP (tcp-address-designator host port) (hash) 'boolean-false))

(define (keyed-tcp-locator designator host port)
  (locator TRANSPORT-KEYED-TCP designator
           (hash HINT-DIRECT-ADDRESSES (tcp-address-designator host port)) 'map))

(define (noise-tcp-locator designator host port)
  (locator TRANSPORT-NOISE-TCP designator
           (hash HINT-DIRECT-ADDRESSES (tcp-address-designator host port)) 'map))

;; (tcp-last-error) -> the calling thread's last error message from the TCP
;; transport archive (`libpancake_net_transport_tcp`), or #f. The transport keeps
;; its own thread-local slot, so a tcp call's diagnostic is read here and never
;; from the ocapn family's `last-error`. Query the length first (NULL buffer),
;; then read.
(define (tcp-last-error) (read-last-error pancake_tcp_last_error))

;; Raise the shared typed `exn:fail:pancake` for a non-OK tcp code, reading this
;; archive's own last-error rather than the unrelated ocapn-family one.
(define (check/tcp code) (check-with code tcp-last-error))

(struct netlayer (owner))
(struct listener (handle fd accept-gate closing netlayer) #:mutable)
(struct connection (handle read-gate write-gate netlayer) #:mutable)

(define (netlayer-forget! nl child)
  (native-parent-forget! (netlayer-owner nl) child))

(define (make-netlayer [config (make-tcp-config)])
  (define-values (rc h) (pancake_tcp_netlayer_new (tcp-config->c config)))
  (check/tcp rc)
  (define nl
    (netlayer
     (make-native-parent h pancake_tcp_netlayer_release
                         pancake_tcp_netlayer_shutdown)))
  (register-finalizer nl (lambda (q) (netlayer-release! q)))
  nl)

(define (netlayer-release! nl)
  (native-parent-release!
   (netlayer-owner nl)
   (lambda (child)
     (cond [(listener? child) (listener-release! child)]
           [(connection? child) (connection-release! child)]))))

(define (netlayer-listen nl host [port 0])
  (define bs (string->bytes/utf-8 host))
  (define lst
    (native-parent-open-child
     (netlayer-owner nl) 'netlayer-listen
     (lambda (parent-handle)
       (define-values (rc h)
         (pancake_tcp_listen parent-handle (pin-immobile bs) (bytes-length bs) port))
       (check/tcp rc)
       (define-values (fd-rc fd) (pancake_tcp_listener_readiness_fd h))
       (with-handlers ([exn? (lambda (e) (pancake_tcp_listener_release h) (raise e))])
         (check/tcp fd-rc))
       (listener h fd (make-semaphore 1) (make-semaphore 0) nl))
     listener-release!))
  (register-finalizer lst (lambda (q) (listener-release! q)))
  lst)

(define (netlayer-connect nl host port [codec 'syrup] [max-frame RAW-TRANSPORT-DEFAULT-FRAME-CAP]
                          #:options [options #f])
  (define bs (string->bytes/utf-8 host))
  (define cn
    (native-parent-open-child
     (netlayer-owner nl) 'netlayer-connect
     (lambda (parent-handle)
       (define-values (rc h)
         (pancake_tcp_connect parent-handle (pin-immobile bs) (bytes-length bs)
                              port (optional-tcp-stream-options->c options)
                              (codec-id codec) max-frame))
       (check/tcp rc)
       (connection h (make-semaphore 1) (make-semaphore 1) nl))
     connection-release!))
  (register-finalizer
   cn
   (lambda (q)
     (run-native-finalizer! "tcp-connection.finalize"
                            (lambda () (connection-release! q))
                            #:layer 'transport)))
  cn)

(define (listener-port lst)
  (define-values (rc port) (pancake_tcp_listener_port (listener-handle lst)))
  (check/tcp rc)
  port)

(define (listener-readiness-fd lst)
  (or (listener-fd lst) (error 'listener-readiness-fd "listener is closed")))

(define (listener-accept lst [codec 'syrup] [max-frame RAW-TRANSPORT-DEFAULT-FRAME-CAP]
                         #:options [options #f])
  (call-with-semaphore
   (listener-accept-gate lst)
   (lambda ()
     ;; Register the real listener fd with rktio before entering the blocking FFI
     ;; call. The gate makes readiness plus accept one indivisible consumer
     ;; operation: sibling accepters park as green threads and re-arm after this
     ;; accept, so none enters C on readiness another accepter already consumed.
     (define fd (listener-readiness-fd lst))
     (define ready (unsafe-file-descriptor->semaphore fd 'read))
     (unless ready (error 'listener-accept "TCP listener fd ~a is not pollable" fd))
     (define outcome
       (sync (handle-evt ready (lambda (_) 'ready))
             (handle-evt (semaphore-peek-evt (listener-closing lst))
                         (lambda (_) 'closing))))
     (when (eq? outcome 'closing)
       (error 'listener-accept "listener is closed"))
     (define-values (rc h)
       (pancake_tcp_accept (listener-handle lst)
                           (optional-tcp-stream-options->c options)
                           (codec-id codec) max-frame))
     (check/tcp rc)
     (define nl (listener-netlayer lst))
     (define cn
       (native-parent-adopt-or-release!
        (netlayer-owner nl)
        (connection h (make-semaphore 1) (make-semaphore 1) nl)
        connection-release!
        'listener-accept))
     (register-finalizer
      cn
      (lambda (q)
        (run-native-finalizer! "tcp-connection.finalize"
                               (lambda () (connection-release! q))
                               #:layer 'transport)))
     cn)))

(define (listener-release! lst)
  (when (listener-handle lst)
    ;; Wake an accepter parked on readiness, then take the same gate that owns
    ;; readiness + native accept. Native release can therefore never free the
    ;; listener under an in-flight blocking FFI call.
    (semaphore-post (listener-closing lst))
    (pancake_tcp_listener_shutdown (listener-handle lst))
    (call-with-semaphore
     (listener-accept-gate lst)
     (lambda ()
       (when (listener-handle lst)
         ;; rktio registrations are per descriptor and re-armed by each 'read
         ;; call. Remove the registration before native release closes the
         ;; borrowed fd.
         (unsafe-file-descriptor->semaphore (listener-readiness-fd lst) 'remove)
         (pancake_tcp_listener_release (listener-handle lst))
         (set-listener-handle! lst #f)
         (set-listener-fd! lst #f)
         (netlayer-forget! (listener-netlayer lst) lst))))))

(define (connection-read-frame cn)
  (call-with-semaphore
   (connection-read-gate cn)
   (lambda ()
     (define h (connection-handle cn))
     (unless h (error 'connection-read-frame "connection is closed"))
     (define mf (make-PancakeManagedFrame #f 0 0 #f (make-vector 8 0)))
     (check/tcp (pancake_tcp_conn_read_frame h mf))
     (dynamic-wind
      void
      (lambda ()
        (bytes<-c (PancakeManagedFrame-bytes mf) (PancakeManagedFrame-len mf)))
      (lambda () (pancake_managed_frame_release mf))))))

(define (connection-write-frame! cn frame)
  (call-with-semaphore
   (connection-write-gate cn)
   (lambda ()
     (define h (connection-handle cn))
     (unless h (error 'connection-write-frame! "connection is closed"))
     (define buf (pin-immobile frame))
     (define rc (pancake_tcp_conn_write_frame h (make-PancakeFrame buf (bytes-length frame) FRAME-SHAPE-BYTE)))
     ;; The frame cstruct is retained as the call's argument, but it carries
     ;; only `buf`'s raw address; the sink keeps the pinned payload live for
     ;; the whole blocking write.
     (void/reference-sink buf)
     (check/tcp rc))))

(define (connection-release! cn)
  (when (connection-handle cn)
    (define shutdown-failure #f)
    (define release-failure #f)
    (with-handlers ([(lambda (_) #t)
                     (lambda (raised) (set! shutdown-failure raised))])
      (check/tcp (pancake_tcp_conn_shutdown (connection-handle cn))))
    (call-with-semaphore
     (connection-read-gate cn)
     (lambda ()
       (call-with-semaphore
        (connection-write-gate cn)
        (lambda ()
          (when (connection-handle cn)
            (with-handlers ([(lambda (_) #t)
                             (lambda (raised) (set! release-failure raised))])
              (check/tcp (pancake_tcp_conn_release (connection-handle cn))))
            (set-connection-handle! cn #f)
            (netlayer-forget! (connection-netlayer cn) cn))))))
    (raise-retained-failures shutdown-failure release-failure)))
