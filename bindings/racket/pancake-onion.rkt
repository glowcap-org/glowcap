#lang racket/base
;; pancake/onion — the Tor onion transport for the Racket binding.
;;
;; `onion` is the one netlayer the OCapN draft standardizes, and the one upstream
;; Spritely Goblins ships, so it is where a pancake peer and a Goblins vat meet on
;; ground neither invented. A locator is ocapn://<serviceid>.onion, and the
;; designator this module takes is that bare service id: 56 base32 characters with
;; no `.onion` suffix.
;;
;; pancake starts no Tor. A netlayer names where an already-running daemon listens
;; — its SOCKS endpoint to dial, its control endpoint to host — and never spawns,
;; supervises, or configures one. Each endpoint is an absolute Unix socket path or
;; a host:port. Omit the control endpoint and the netlayer can dial and cannot
;; host, which `onion-netlayer-listen` reports rather than pretending:
;;
;;   (require "pancake.rkt")
;;   (require "pancake-onion.rkt")
;;
;;   (define nl (make-onion-netlayer #:socks "/run/tor/socks"
;;                                   #:control "/run/tor/control"))
;;   (define lst (onion-netlayer-listen nl))
;;   (printf "ocapn://~a.onion\n" (onion-listener-service-id lst))
;;
;; Two limits are worth reading before relying on this, and both are ADR-0108
;; decisions rather than implementation details. A service id is an ADDRESS, not
;; an identity: Tor proves the far end of the circuit holds the key the address
;; encodes, but the CapTP peer is whoever holds the local endpoint that service
;; forwards to. And an accepted circuit carries no client identity at all, because
;; Tor tells a hidden service nothing about who dialed it, so a partner's claimed
;; location on that side is unverified.
;;
;; Every call that reaches Tor parks the calling thread for as long as a circuit
;; takes, which is seconds. Both handles hand back the socket they sit on through
;; `onion-listener-readiness-fd` and `onion-connection-readiness-fd`, so a caller
;; with its own loop can `sync` on it and only accept or read when that will
;; return. An onion connection is an ordinary socket, which is why a real
;; descriptor is available here.
;;
;; That park stops the whole place, not one thread. Marking a foreign call
;; `#:blocking?` keeps the collector cooperative during it; it does not hand the
;; scheduler to another Racket thread. So a program that must keep serving while a
;; circuit is being built waits on the readiness descriptor instead of calling
;; through, or puts the blocking call in a place of its own.

(require ffi/unsafe
         ffi/unsafe/port
         "private/constants.rkt"
         "private/ffi-onion.rkt"
         "private/ffi-shared.rkt"
         (only-in "private/loop.rkt" driver-loop-add-provider!)
         "private/native-parent.rkt"
         "private/seam.rkt")

(provide make-onion-netlayer onion-install-provider! onion-netlayer-release!
         onion-netlayer-listen onion-netlayer-connect
         onion-listener-accept onion-listener-release!
         onion-listener-service-id onion-listener-service-key
         onion-listener-wait onion-listener-readiness-fd
         onion-connection-read-frame onion-connection-write-frame! onion-connection-release!
         onion-connection-readiness-fd
         onion-last-error
         AUTH-NONE AUTH-COOKIE AUTH-PASSWORD SERVICE-ID-LENGTH)

;; An unauthenticated control endpoint, which is what a Unix control socket with
;; no authentication gives and what upstream Goblins assumes.
(define AUTH-NONE 0)
;; Authenticate with the bytes of the file CookieAuthFile names, which the
;; transport sends as hexadecimal. The common default on a distribution's Tor.
(define AUTH-COOKIE 1)
;; Authenticate with the cleartext of a HashedControlPassword setup.
(define AUTH-PASSWORD 2)

;; A version 3 onion service id is always exactly this many characters.
(define SERVICE-ID-LENGTH 56)
(define SERVICE-KEY-CAP 256)

;; (onion-last-error) -> the calling thread's last error message from the onion
;; transport archive, or #f. The transport keeps its own thread-local slot, so an
;; onion call's diagnostic is read here and never from the ocapn family's
;; `last-error`.
(define (onion-last-error) (read-last-error pancake_onion_last_error))

;; Raise the shared typed `exn:fail:pancake` for a non-OK onion code, reading this
;; archive's own last-error rather than the unrelated ocapn-family one.
(define (check/onion code) (check-with code onion-last-error))

(struct onion-netlayer (owner))
(struct onion-listener (handle service-id service-key fd accept-gate closing netlayer) #:mutable)
(struct onion-connection (handle read-gate write-gate netlayer) #:mutable)

(define (onion-netlayer-forget! nl child)
  (native-parent-forget! (onion-netlayer-owner nl) child))

(define (as-bytes value)
  (cond [(not value) #""]
        [(bytes? value) value]
        [else (string->bytes/utf-8 value)]))

;; Build the config and call the constructor with every buffer pinned for the
;; duration. The netlayer copies the text it needs, so the pins are only wanted
;; across this one call.
(define (new-onion-handle socks control auth-kind auth-secret service-key forward)
  (define socks-bs (as-bytes socks))
  (define control-bs (as-bytes control))
  (define secret-bs (as-bytes auth-secret))
  (define key-bs (as-bytes service-key))
  (define forward-bs (as-bytes forward))
  (define (ptr bs) (if (zero? (bytes-length bs)) #f (pin-immobile bs)))
  (define cfg
    (make-PancakeOnionConfig (ptr socks-bs) (bytes-length socks-bs)
                             (ptr control-bs) (bytes-length control-bs)
                             auth-kind
                             (ptr secret-bs) (bytes-length secret-bs)
                             (ptr key-bs) (bytes-length key-bs)
                             (ptr forward-bs) (bytes-length forward-bs)))
  (define-values (rc h) (pancake_onion_netlayer_new cfg))
  (check/onion rc)
  h)

(define (make-onion-netlayer #:socks socks
                             #:control [control #f]
                             #:auth-kind [auth-kind AUTH-NONE]
                             #:auth-secret [auth-secret #f]
                             #:service-key [service-key #f]
                             #:forward [forward #f])
  (define h
    (new-onion-handle socks control auth-kind auth-secret service-key forward))
  (define nl
    (onion-netlayer
     (make-native-parent h pancake_onion_netlayer_release
                         pancake_onion_netlayer_shutdown)))
  (register-finalizer nl (lambda (q) (onion-netlayer-release! q)))
  nl)

;; Install one configured onion package into a native driver. Registration
;; retains the package before the constructor reference is released; shutdown
;; remains the driver's responsibility through that retained lease.
(define (onion-install-provider! lp
                                 #:socks socks
                                 #:control [control #f]
                                 #:auth-kind [auth-kind AUTH-NONE]
                                 #:auth-secret [auth-secret #f]
                                 #:service-key [service-key #f]
                                 #:forward [forward #f])
  (define h
    (new-onion-handle socks control auth-kind auth-secret service-key forward))
  (dynamic-wind
   void
   (lambda ()
     (define package (make-PancakeTransportProvider 0 0 #f 0 #f #f #f))
     (check/onion (pancake_onion_transport_provider h package))
     (driver-loop-add-provider! lp package))
   (lambda () (pancake_onion_netlayer_release h))))

(define (onion-netlayer-release! nl)
  (native-parent-release!
   (onion-netlayer-owner nl)
   (lambda (child)
     (cond [(onion-listener? child) (onion-listener-release! child)]
           [(onion-connection? child) (onion-connection-release! child)]))))

;; Ask Tor for an onion service and bind its local end. Requires a control
;; endpoint; without one this raises rather than reporting a service nothing could
;; reach.
(define (onion-netlayer-listen nl)
  ;; Immobile out blocks rather than Racket bytestrings: this call is blocking, so
  ;; the collector may run and move a bytestring while Tor answers.
  (define id-buf (out-immobile SERVICE-ID-LENGTH))
  (define key-buf (out-immobile SERVICE-KEY-CAP))
  (define lst
    (native-parent-open-child
     (onion-netlayer-owner nl) 'onion-netlayer-listen
     (lambda (parent-handle)
       (define-values (rc id-len key-len h)
         (pancake_onion_listen parent-handle id-buf SERVICE-ID-LENGTH
                               key-buf SERVICE-KEY-CAP))
       (check/onion rc)
       (define-values (fd-rc fd) (pancake_onion_listener_readiness_fd h))
       (with-handlers ([exn? (lambda (e) (pancake_onion_listener_release h) (raise e))])
         (check/onion fd-rc))
       (onion-listener h
                       (bytes->string/utf-8 (bytes<-c id-buf id-len))
                       (bytes<-c key-buf key-len)
                       fd
                       (make-semaphore 1)
                       (make-semaphore 0)
                       nl))
     onion-listener-release!))
  (register-finalizer lst (lambda (q) (onion-listener-release! q)))
  lst)

;; Dial the onion service `service-id` through the configured Tor. One that is not
;; a well-formed version 3 address is refused before any socket opens.
(define (onion-netlayer-connect nl service-id [codec 'syrup] [max-frame 4096])
  (define bs (as-bytes service-id))
  (define cn
    (native-parent-open-child
     (onion-netlayer-owner nl) 'onion-netlayer-connect
     (lambda (parent-handle)
       (define-values (rc h)
         (pancake_onion_connect parent-handle (pin-immobile bs) (bytes-length bs)
                                (codec-id codec) max-frame))
       (check/onion rc)
       (onion-connection h (make-semaphore 1) (make-semaphore 1) nl))
     onion-connection-release!))
  (register-finalizer cn (lambda (q) (onion-connection-release! q)))
  cn)

;; Block until Tor forwards a circuit to this service. The partner's claimed
;; location is unverified here: Tor tells a hidden service nothing about who
;; dialed it.
(define (onion-listener-accept lst [codec 'syrup] [max-frame 4096])
  (call-with-semaphore
   (onion-listener-accept-gate lst)
   (lambda ()
     ;; Readiness plus accept has one consumer. A sibling accepter parks as a
     ;; green thread instead of entering C on an edge another accepter spent.
     (define fd (onion-listener-readiness-fd/locked lst))
     (define ready (unsafe-file-descriptor->semaphore fd 'read))
     (unless ready (error 'onion-listener-accept "onion listener fd ~a is not pollable" fd))
     (define outcome
       (sync (handle-evt ready (lambda (_) 'ready))
             (handle-evt (semaphore-peek-evt (onion-listener-closing lst))
                         (lambda (_) 'closing))))
     (when (eq? outcome 'closing)
       (error 'onion-listener-accept "listener is closed"))
     (define-values (rc h)
       (pancake_onion_accept (onion-listener-handle lst) (codec-id codec) max-frame))
     (check/onion rc)
     (define nl (onion-listener-netlayer lst))
     (define cn
       (native-parent-adopt-or-release!
        (onion-netlayer-owner nl)
        (onion-connection h (make-semaphore 1) (make-semaphore 1) nl)
        onion-connection-release!
        'onion-listener-accept))
     (register-finalizer cn (lambda (q) (onion-connection-release! q)))
     cn)))

;; Wait up to `timeout-ms` for `onion-listener-accept` to be able to make
;; progress. #f on timeout. Lets an accept loop check a stop flag instead of
;; parking, without closing the listener from another thread.
(define (onion-listener-wait lst timeout-ms)
  (call-with-semaphore
   (onion-listener-accept-gate lst)
   (lambda ()
     (define h (onion-listener-handle lst))
     (unless h (error 'onion-listener-wait "listener is closed"))
     (define-values (rc ready) (pancake_onion_listener_wait h timeout-ms))
     (check/onion rc)
     (not (zero? ready)))))

;; The descriptor this listener's circuits arrive on. This is what keeps a caller
;; with its own loop off the blocking path: watch it, and accept only once it is
;; readable. Owned by the listener; do not close it.
(define (onion-listener-readiness-fd lst)
  (call-with-semaphore
   (onion-listener-accept-gate lst)
   (lambda () (onion-listener-readiness-fd/locked lst))))

;; The listener's fd and native handle are retired under the accept gate. Keep
;; the unchecked read private so accept/release can use it while already holding
;; that non-recursive gate without re-entering it.
(define (onion-listener-readiness-fd/locked lst)
  (or (onion-listener-fd lst)
      (error 'onion-listener-readiness-fd "listener is closed")))

;; The descriptor this connection's bytes flow over. Same contract as the
;; listener's.
(define (onion-connection-readiness-fd cn)
  (call-with-semaphore
   (onion-connection-read-gate cn)
   (lambda ()
     (define h (onion-connection-handle cn))
     (unless h (error 'onion-connection-readiness-fd "connection is closed"))
     (define-values (rc fd) (pancake_onion_conn_readiness_fd h))
     (check/onion rc)
     fd)))

(define (onion-listener-release! lst)
  (when (onion-listener-handle lst)
    (semaphore-post (onion-listener-closing lst))
    ;; A readiness edge is advisory. If an accept entered C after observing it,
    ;; shutdown is what makes release able to join that lease before freeing the
    ;; listener. The call is idempotent, so racing releases remain harmless.
    (pancake_onion_listener_shutdown (onion-listener-handle lst))
    (call-with-semaphore
     (onion-listener-accept-gate lst)
     (lambda ()
       (when (onion-listener-handle lst)
         (unsafe-file-descriptor->semaphore (onion-listener-readiness-fd/locked lst) 'remove)
         (pancake_onion_listener_release (onion-listener-handle lst))
         (set-onion-listener-handle! lst #f)
         (set-onion-listener-fd! lst #f)
         (onion-netlayer-forget! (onion-listener-netlayer lst) lst))))))

;; Block for one whole frame's bytes, or `eof` on a graceful end of stream. Prefer
;; watching `onion-connection-readiness-fd` first; this parks when nothing has
;; arrived.
(define (onion-connection-read-frame cn)
  (call-with-semaphore
   (onion-connection-read-gate cn)
   (lambda ()
     (define h (onion-connection-handle cn))
     (unless h (error 'onion-connection-read-frame "connection is closed"))
     (define mf (make-PancakeManagedFrame #f 0 0 #f #f))
     (define code (pancake_onion_conn_read_frame h mf))
     (cond
       [(= code ERR-CLOSED) eof]
       [else
        (check/onion code)
        (dynamic-wind
         void
         (lambda ()
           (bytes<-c (PancakeManagedFrame-bytes mf) (PancakeManagedFrame-len mf)))
         (lambda () (pancake_managed_frame_release mf)))]))))

(define (onion-connection-write-frame! cn frame)
  (call-with-semaphore
   (onion-connection-write-gate cn)
   (lambda ()
     (define h (onion-connection-handle cn))
     (unless h (error 'onion-connection-write-frame! "connection is closed"))
     (define buf (pin-immobile frame))
     (check/onion (pancake_onion_conn_write_frame
                   h (make-PancakeFrame buf (bytes-length frame) FRAME-SHAPE-BYTE))))))

(define (onion-connection-release! cn)
  (when (onion-connection-handle cn)
    ;; Shutdown interrupts either full-duplex half. Release then takes both gates,
    ;; proving no native call can still touch the payload it is about to free.
    (pancake_onion_conn_shutdown (onion-connection-handle cn))
    (call-with-semaphore
     (onion-connection-read-gate cn)
     (lambda ()
       (call-with-semaphore
        (onion-connection-write-gate cn)
        (lambda ()
          (when (onion-connection-handle cn)
            (pancake_onion_conn_release (onion-connection-handle cn))
            (set-onion-connection-handle! cn #f)
            (onion-netlayer-forget! (onion-connection-netlayer cn) cn))))))))
