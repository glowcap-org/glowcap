#lang racket/base
;; glowcap/onion — the Tor onion transport for the Racket binding.
;;
;; `onion` is the one netlayer the OCapN draft standardizes, and the one upstream
;; Spritely Goblins ships, so it is where a glowcap peer and a Goblins vat meet on
;; ground neither invented. A locator is ocapn://<serviceid>.onion, and the
;; designator this module takes is that bare service id: 56 base32 characters with
;; no `.onion` suffix.
;;
;; glowcap starts no Tor. A netlayer names where an already-running daemon listens
;; — its SOCKS endpoint to dial, its control endpoint to host — and never spawns,
;; supervises, or configures one. Each endpoint is an absolute Unix socket path or
;; a host:port. Omit the control endpoint and the netlayer can dial and cannot
;; host, which `onion-netlayer-listen` reports rather than pretending:
;;
;;   (require "glowcap.rkt")
;;   (require "glowcap-onion.rkt")
;;
;;   (define nl (make-onion-netlayer #:socks "/run/tor/socks"
;;                                   #:control "/run/tor/control"))
;;   (define lst (onion-netlayer-listen nl))
;;   (printf "ocapn://~a.onion\n" (onion-listener-service-id lst))
;;
;; A CapTP application uses the driver-backed surface instead:
;;
;;   (define server (listen-onion #:socks "/run/tor/socks"
;;                                #:control "/run/tor/control"))
;;   (printf "~a\n" (onion-server-uri server))
;;   (define session (onion-server-accept server))
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
         racket/lazy-require
         "private/constants.rkt"
         (only-in "private/abi-value.rkt" DEFAULT-CODEC-SYMBOL)
         "private/ffi-onion.rkt"
         "private/ffi-shared.rkt"
         "private/locator.rkt"
         "private/native-parent.rkt"
         "private/finalizer-diagnostics.rkt"
         "private/seam.rkt"
         "private/transport.rkt")

(lazy-require
 ["private/host/state.rkt" (host-loop-of)]
 ["private/listen-loop.rkt" (listen-loop-profile resolve-host-profile)]
 ["private/loop.rkt"
  (open-driver-loop
   driver-loop-start!
   driver-loop-abort!
   driver-loop-add-provider!
   loop-connect-session
   loop-listener-restoration-state
   loop-server-locator
   loop-server-host
   loop-server-accept
   loop-server-close!)])

(provide onion-locator onion-provider onion-connector
         make-onion-netlayer onion-install-provider! onion-netlayer-release!
         listen-onion connect-onion
         onion-server?
         onion-server-host onion-server-locator onion-server-service-id onion-server-uri
         onion-server-service-key onion-server-accept onion-server-close!
         (struct-out failure-event) take-runtime-failures!
         onion-netlayer-listen onion-netlayer-connect
         onion-listener-accept onion-listener-release!
         onion-listener-service-id onion-listener-service-key
         onion-listener-wait onion-listener-readiness-fd
         onion-connection-read-frame onion-connection-write-frame! onion-connection-release!
         onion-connection-readiness-fd
         onion-last-error
         AUTH-NONE AUTH-COOKIE AUTH-PASSWORD SERVICE-ID-LENGTH)

;; An unauthenticated control endpoint, the form a Unix control socket with no
;; authentication gives and the one upstream Goblins assumes.
(define AUTH-NONE ONION-AUTH-NONE)
;; Authenticate with the bytes of the file CookieAuthFile names, which the
;; transport sends as hexadecimal. The common default on a distribution's Tor.
(define AUTH-COOKIE ONION-AUTH-COOKIE)
;; Authenticate with the cleartext of a HashedControlPassword setup.
(define AUTH-PASSWORD ONION-AUTH-PASSWORD)

;; A version 3 onion service id is always exactly this many characters.
(define SERVICE-ID-LENGTH ONION-SERVICE-ID-LEN)
(define SERVICE-KEY-CAP ONION-SERVICE-KEY-CAP)

(define (onion-locator service-id)
  (locator TRANSPORT-ONION service-id (hash) 'boolean-false))

;; (onion-last-error) -> the calling thread's last error message from the onion
;; transport archive, or #f. The transport keeps its own thread-local slot, so an
;; onion call's diagnostic is read here and never from the ocapn family's
;; `last-error`.
(define (onion-last-error) (read-last-error glowcap_onion_last_error))

;; Raise the shared typed `exn:fail:glowcap` for a non-OK onion code, reading this
;; archive's own last-error rather than the unrelated ocapn-family one.
(define (check/onion code) (check-with code onion-last-error))

(struct onion-netlayer (owner))
(struct onion-listener (handle service-id service-key fd accept-gate closing netlayer) #:mutable)
(struct onion-connection (handle read-gate write-gate netlayer) #:mutable)

;; The high-level server is a view over the generic loop server. It owns no
;; second listener queue or session table; the loop server remains the sole
;; authority for admission, accepted handles, and loop retirement.
(struct onion-server (inner restoration-key) #:transparent)

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
  (define pins
    (list (ptr socks-bs) (ptr control-bs) (ptr secret-bs)
          (ptr key-bs) (ptr forward-bs)))
  (define cfg
    (make-GlowcapOnionConfig (car pins) (bytes-length socks-bs)
                             (cadr pins) (bytes-length control-bs)
                             auth-kind
                             (caddr pins) (bytes-length secret-bs)
                             (cadddr pins) (bytes-length key-bs)
                             (list-ref pins 4) (bytes-length forward-bs)))
  (define-values (rc h) (glowcap_onion_netlayer_new cfg))
  ;; The config cstruct is retained as the call's argument, but it carries
  ;; only the pins' raw addresses; the sink keeps every pinned buffer live
  ;; for the whole blocking constructor.
  (void/reference-sink pins)
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
     (make-native-parent h (lambda (raw) (check/onion (glowcap_onion_netlayer_release raw)))
                         glowcap_onion_netlayer_shutdown)))
  (register-finalizer
   nl
   (lambda (q) (run-native-finalizer! "onion-netlayer.finalize" (lambda () (onion-netlayer-release! q)) #:layer 'transport)))
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
     (define package (make-GlowcapTransportProvider 0 0 #f 0 #f #f #f #f))
     (check/onion (glowcap_onion_transport_provider h package))
     (driver-loop-add-provider! lp package))
   (lambda () (check/onion (glowcap_onion_netlayer_release h)))))

(define (onion-provider #:socks socks
                        #:control [control #f]
                        #:auth-kind [auth-kind AUTH-NONE]
                        #:auth-secret [auth-secret #f]
                        #:service-key [service-key #f]
                        #:forward [forward #f])
  (make-driver-provider
   (lambda (lp _host)
     (onion-install-provider! lp
                              #:socks socks
                              #:control control
                              #:auth-kind auth-kind
                              #:auth-secret auth-secret
                              #:service-key service-key
                              #:forward forward))))

;; The raw onion resident exposes complete frames. Adapt its readiness edge to
;; the byte-fed Session seam and keep the netlayer parent alive until the
;; session closes. This is an explicit opt-in connector; generic `connect`
;; never loads Tor or guesses an onion authority.
(define (onion-connector #:socks socks
                         #:control [control #f]
                         #:auth-kind [auth-kind AUTH-NONE]
                         #:auth-secret [auth-secret #f]
                         #:service-key [service-key #f]
                         #:forward [forward #f])
  (make-byte-connector
   (list TRANSPORT-ONION)
   (lambda (m loc handshake-timeout-ms)
     (define nl #f)
     (define cn #f)
     (define (close!)
       (when cn (onion-connection-release! cn) (set! cn #f))
       (when nl (onion-netlayer-release! nl) (set! nl #f)))
     (with-handlers ([(lambda (_) #t) (lambda (e) (close!) (raise e))])
       (set! nl (make-onion-netlayer #:socks socks #:control control
                                     #:auth-kind auth-kind #:auth-secret auth-secret
                                     #:service-key service-key #:forward forward))
       (set! cn (onion-netlayer-connect nl (locator-designator loc)))
       (define transport
         (async-transport
          (lambda (frame) (onion-connection-write-frame! cn frame))
          void
          (lambda (wake-evt)
            (define fd (onion-connection-readiness-fd cn))
            (define ready (unsafe-file-descriptor->semaphore fd 'read))
            (unless ready (error 'onion-connector "connection fd ~a is not pollable" fd))
            (define event (sync ready wake-evt))
            (if (eq? event wake-evt)
                'woke
                (onion-connection-read-frame cn)))
          close!))
       (establish-dialed-locator-session
        m loc transport
        #:handshake-timeout-ms handshake-timeout-ms)))))

;; Host CapTP through an onion service using the generic driver listener. The
;; onion package owns only provider composition and the interpretation of its
;; restoration bytes; the driver owns the canonical locator and accepted
;; Session handles, and the shared listener spine owns the loop, its Host
;; profile, and the setup rollback. A service id is an address, so the
;; listener keeps no durable seed. `#:codec`, `#:captp-version`, `#:features`,
;; and `#:options` are the TCP listeners' keywords: each is honored exactly or
;; refused, and the onion provider defines no per-listen options, so any value
;; other than an empty one is refused as the listener opens.
(define (listen-onion #:socks socks
                      #:control [control #f]
                      #:auth-kind [auth-kind AUTH-NONE]
                      #:auth-secret [auth-secret #f]
                      #:service-key [service-key #f]
                      #:forward [forward #f]
                      #:codec [codec #f]
                      #:captp-version [captp-version #f]
                      #:features [features #f]
                      #:time-travel? [time-travel? #f]
                      #:host [shared-host #f]
                      #:options [options #f])
  (define key #f)
  (define server
    (listen-loop-profile 'listen-onion TRANSPORT-ONION ""
                         #:identity? #f
                         #:seed #f #:codec codec #:captp-version captp-version
                         #:features features #:options options
                         #:host shared-host #:time-travel? time-travel?
                         #:install (lambda (lp)
                                     (onion-install-provider! lp
                                                              #:socks socks
                                                              #:control control
                                                              #:auth-kind auth-kind
                                                              #:auth-secret auth-secret
                                                              #:service-key service-key
                                                              #:forward forward))
                         #:after-ready
                         (lambda (lp listener)
                           (set! key (loop-listener-restoration-state lp listener)))))
  (onion-server server (bytes->immutable-bytes key)))

(define (onion-server-host s)
  (loop-server-host (onion-server-inner s)))

(define (onion-server-service-key s)
  (bytes-copy (onion-server-restoration-key s)))

(define (onion-server-locator s)
  (loop-server-locator (onion-server-inner s)))

(define (onion-server-service-id s)
  (locator-designator (onion-server-locator s)))

(define (onion-server-uri s)
  (format-locator-uri (onion-server-locator s)))

(define (onion-server-accept s)
  (loop-server-accept (onion-server-inner s)))

(define (onion-server-close! s)
  (loop-server-close! (onion-server-inner s)))

;; Dial an onion service through the same package composition as `listen-onion`.
;; The full provider configuration is accepted so a caller-owned Host can reuse
;; the exact Tor authority its listener already installed. Without `#:host`
;; the minted loop belongs to the returned session's Host, so
;; `(host-close! (session-host s))` is what retires it.
(define (connect-onion partner
                       #:socks socks
                       #:control [control #f]
                       #:auth-kind [auth-kind AUTH-NONE]
                       #:auth-secret [auth-secret #f]
                       #:service-key [service-key #f]
                       #:forward [forward #f]
                       #:codec [codec #f]
                       #:captp-version [captp-version #f]
                       #:features [features #f]
                       #:host [shared-host #f])
  (unless (locator? partner)
    (raise-argument-error 'connect-onion "locator?" partner))
  ;; The same profile rule the listeners use: an explicit value that differs
  ;; from a supplied Host's is refused, and an omitted one is the Host's, else
  ;; the generated default.
  (define-values (loop-codec loop-captp-version loop-features)
    (resolve-host-profile 'connect-onion shared-host codec captp-version features))
  (define lp
    (if (and shared-host (host-loop-of shared-host))
        (host-loop-of shared-host)
        (open-driver-loop #:host shared-host
                          #:codec loop-codec
                          #:captp-version loop-captp-version
                          #:features loop-features)))
  (with-handlers ([(lambda (_) #t)
                   (lambda (e)
                     (when (not shared-host) (driver-loop-abort! lp))
                     (raise e))])
    (onion-install-provider! lp
                             #:socks socks
                             #:control control
                             #:auth-kind auth-kind
                             #:auth-secret auth-secret
                             #:service-key service-key
                             #:forward forward)
    (driver-loop-start! lp)
    (loop-connect-session lp partner)))

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
         (glowcap_onion_listen parent-handle id-buf SERVICE-ID-LENGTH
                               key-buf SERVICE-KEY-CAP))
       (check/onion rc)
       (define-values (fd-rc fd) (glowcap_onion_listener_readiness_fd h))
       (with-handlers
           ([exn?
             (lambda (e)
               (define cleanup
                 (with-handlers ([exn? values])
                   (check/onion (glowcap_onion_listener_release h))
                   #f))
               (raise (if cleanup (retain-cleanup-failure e cleanup) e)))])
         (check/onion fd-rc))
       (onion-listener h
                       (bytes->string/utf-8 (bytes<-c id-buf id-len))
                       (bytes<-c key-buf key-len)
                       fd
                       (make-semaphore 1)
                       (make-semaphore 0)
                       nl))
     onion-listener-release!))
  (register-finalizer
   lst
   (lambda (q) (run-native-finalizer! "onion-listener.finalize" (lambda () (onion-listener-release! q)) #:layer 'transport)))
  lst)

;; Dial the onion service `service-id` through the configured Tor. One that is not
;; a well-formed version 3 address is refused before any socket opens.
(define (onion-netlayer-connect nl service-id [codec DEFAULT-CODEC-SYMBOL]
                                [max-frame RAW-TRANSPORT-DEFAULT-FRAME-CAP])
  (define bs (as-bytes service-id))
  (define cn
    (native-parent-open-child
     (onion-netlayer-owner nl) 'onion-netlayer-connect
     (lambda (parent-handle)
       (define-values (rc h)
         (glowcap_onion_connect parent-handle (pin-immobile bs) (bytes-length bs)
                                (codec-id codec) max-frame))
       (check/onion rc)
       (onion-connection h (make-semaphore 1) (make-semaphore 1) nl))
     onion-connection-release!))
  (register-finalizer
   cn
   (lambda (q) (run-native-finalizer! "onion-connection.finalize" (lambda () (onion-connection-release! q)) #:layer 'transport)))
  cn)

;; Block until Tor forwards a circuit to this service. The partner's claimed
;; location is unverified here: Tor tells a hidden service nothing about who
;; dialed it.
(define (onion-listener-accept lst [codec DEFAULT-CODEC-SYMBOL]
                               [max-frame RAW-TRANSPORT-DEFAULT-FRAME-CAP])
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
       (glowcap_onion_accept (onion-listener-handle lst) (codec-id codec) max-frame))
     (check/onion rc)
     (define nl (onion-listener-netlayer lst))
     (define cn
       (native-parent-adopt-or-release!
        (onion-netlayer-owner nl)
        (onion-connection h (make-semaphore 1) (make-semaphore 1) nl)
        onion-connection-release!
        'onion-listener-accept))
     (register-finalizer
      cn
      (lambda (q) (run-native-finalizer! "onion-connection.finalize" (lambda () (onion-connection-release! q)) #:layer 'transport)))
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
     (define-values (rc ready) (glowcap_onion_listener_wait h timeout-ms))
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
     (define-values (rc fd) (glowcap_onion_conn_readiness_fd h))
     (check/onion rc)
     fd)))

(define (onion-listener-release! lst)
  (when (onion-listener-handle lst)
    (semaphore-post (onion-listener-closing lst))
    ;; A readiness edge is advisory. If an accept entered C after observing it,
    ;; shutdown is what makes release able to join that lease before freeing the
    ;; listener. The call is idempotent, so racing releases remain harmless.
    (glowcap_onion_listener_shutdown (onion-listener-handle lst))
    (call-with-semaphore
     (onion-listener-accept-gate lst)
     (lambda ()
       (when (onion-listener-handle lst)
         (unsafe-file-descriptor->semaphore (onion-listener-readiness-fd/locked lst) 'remove)
         (define release-code (glowcap_onion_listener_release (onion-listener-handle lst)))
         (set-onion-listener-handle! lst #f)
         (set-onion-listener-fd! lst #f)
         (onion-netlayer-forget! (onion-listener-netlayer lst) lst)
         (check/onion release-code))))))

;; Block for one whole frame's bytes, or `eof` on a graceful end of stream. Prefer
;; watching `onion-connection-readiness-fd` first; this parks when nothing has
;; arrived.
(define (onion-connection-read-frame cn)
  (call-with-semaphore
   (onion-connection-read-gate cn)
   (lambda ()
     (define h (onion-connection-handle cn))
     (unless h (error 'onion-connection-read-frame "connection is closed"))
     (define mf (make-GlowcapManagedFrame #f 0 0 #f (make-vector 8 0)))
     (define code (glowcap_onion_conn_read_frame h mf))
     (cond
       [(= code ERR-CLOSED) eof]
       [else
        (check/onion code)
        (dynamic-wind
         void
         (lambda ()
           (bytes<-c (GlowcapManagedFrame-bytes mf) (GlowcapManagedFrame-len mf)))
         (lambda () (glowcap_managed_frame_release mf)))]))))

(define (onion-connection-write-frame! cn frame)
  (call-with-semaphore
   (onion-connection-write-gate cn)
   (lambda ()
     (define h (onion-connection-handle cn))
     (unless h (error 'onion-connection-write-frame! "connection is closed"))
     (define buf (pin-immobile frame))
     (define rc (glowcap_onion_conn_write_frame
                 h (make-GlowcapFrame buf (bytes-length frame) FRAME-SHAPE-BYTE)))
     ;; The frame cstruct is retained as the call's argument, but it carries
     ;; only `buf`'s raw address; the sink keeps the pinned payload live for
     ;; the whole blocking write.
     (void/reference-sink buf)
     (check/onion rc))))

(define (onion-connection-release! cn)
  (when (onion-connection-handle cn)
    ;; Shutdown interrupts either full-duplex half. Release then takes both gates,
    ;; proving no native call can still touch the payload it is about to free.
    (define shutdown-failure #f)
    (define release-failure #f)
    (with-handlers ([(lambda (_) #t)
                     (lambda (raised) (set! shutdown-failure raised))])
      (check/onion (glowcap_onion_conn_shutdown (onion-connection-handle cn))))
    (call-with-semaphore
     (onion-connection-read-gate cn)
     (lambda ()
       (call-with-semaphore
        (onion-connection-write-gate cn)
        (lambda ()
          (when (onion-connection-handle cn)
            (with-handlers ([(lambda (_) #t)
                             (lambda (raised) (set! release-failure raised))])
              (check/onion (glowcap_onion_conn_release (onion-connection-handle cn))))
            (set-onion-connection-handle! cn #f)
            (onion-netlayer-forget! (onion-connection-netlayer cn) cn))))))
    (raise-retained-failures shutdown-failure release-failure)))
