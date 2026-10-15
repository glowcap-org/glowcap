#lang racket/base
;; One independently loadable family from the Racket binding dogfood.

(require net/base64
         (only-in ffi/unsafe ctype-sizeof)
         racket/random
         racket/runtime-path
         "../../glowcap.rkt"
         "../../glowcap-tcp.rkt"
         "../../glowcap-inproc.rkt"
         "../../glowcap-onion.rkt"
         "../../glowcap-iroh.rkt"
         (combine-in "../../private/session.rkt"
                     "../../private/session/state.rkt"
                     "../../private/session/establish.rkt"
                     "../../private/session/close.rkt")
         (combine-in "../../private/host.rkt" "../../private/host/state.rkt")
         (only-in "../../private/iroh.rkt" iroh-endpoint-record-failure!)
         "../../private/locator.rkt"
         "../../private/async.rkt"
         "../../private/byte-channel.rkt"
         (only-in "../../private/finalizer-diagnostics.rkt"
                  record-runtime-failure! run-ffi-finalizer!)
         (only-in "../../private/ws-transport.rkt" ws-transport)
         (only-in "../../relay.rkt" relay-pump exn:fail:relay?
                  exn:fail:relay-primary exn:fail:relay-secondary)
         "../../private/pump.rkt"
         "../../private/action.rkt"
         (only-in "../../private/dial.rkt" retain-host-cleanup-failure!)
         "../../private/promise.rkt"
         "../../private/gc.rkt"
         "../../private/vat.rkt"
         "../../private/ffi-host.rkt"
         "../../private/ffi-ocapn.rkt"
         "../../private/ffi-shared.rkt"
         "../../private/errors.rkt"
         "../../private/constants.rkt"
         "../../private/abi-value.rkt"
         (only-in "../../private/loop.rkt"
                  open-driver-loop driver-loop-start! driver-loop-abort!
                  loop-background-failed!
                  driver-loop-has-transport?
                  loop-listen! loop-listener-ready! loop-listener-locator
                  loop-listener-close!)
         "../../private/ffi-parent.rkt"
         (only-in "../../private/value.rkt" make-ref/internal)
         "support.rkt"
         racket/tcp)

;; ── À-la-carte transports: one round-trip over each composable transport module ─
;; Each transport archive ships as its own composable module (`glowcap-tcp.rkt`,
;; `glowcap-inproc.rkt`) whose connections shuttle whole frames. These two
;; sections drive the *same* full deliver/serve/resolve round-trip between two
;; byte-fed Host sessions over each explicit netlayer's connections, proving a
;; Racket consumer composes the host tier with a transport à la carte exactly
;; as a C consumer links the archives. Each side is a real `session` (its
;; own node, vat, and keyed handshake); only the transport's (read, write) pair
;; differs, so the driving logic is shared.
;;
;; The exchange is single-threaded. Unlike Racket's own
;; scheduler-aware ports, these explicit C-ABI netlayers park the whole Racket
;; place for the duration of a foreign read or write, so two connections cannot
;; rendezvous across green threads in one place. The script therefore orders
;; every blocking read after the frame it waits for is already in flight: both
;; hellos leave before either side pumps its handshake, and each fetch/call leg
;; feeds exactly the frame the previous leg wrote.
(define (outer-frame-bytes frame)
  (bytes-append
   (string->bytes/utf-8 (format "~a:" (bytes-length frame)))
   frame))

(define (connection-transport read-frame write-frame!)
  ;; The host pump writes byte-stream frames as two chunks: the canonical
  ;; outer length prefix, then the bare codec frame. Explicit C connections take
  ;; and return that bare frame as one unit. Keep the representation change at
  ;; this composition boundary, and verify the pump's pair before discarding
  ;; its prefix.
  (define pending-prefix #f)
  (define (write-chunk! chunk)
    (cond
      [pending-prefix
       (define expected
         (string->bytes/utf-8 (format "~a:" (bytes-length chunk))))
       (unless (bytes=? pending-prefix expected)
         (error 'connection-transport "non-canonical outer frame prefix"))
       (set! pending-prefix #f)
       (write-frame! chunk)]
      [else (set! pending-prefix chunk)]))
  (define (flush!)
    (when pending-prefix
      (error 'connection-transport "outer frame ended before its body")))
  (async-transport
   write-chunk!
   flush!
   (lambda (_wake)
     (define frame (read-frame))
     (if (eof-object? frame)
         eof
         (outer-frame-bytes frame)))
   void))

;; The minting half of `session-fetch`, without its blocking pump: queue the
;; bootstrap fetch, register the vow so the drain can route its completion,
;; and flush; the caller shuttles the frames and reads the vow's state.
(define (scripted-fetch! c name)
  (define m (session-host c))
  (with-host-drain m
    (lambda ()
      (define nb (string->bytes/utf-8 name))
      (define-values (rc id)
        (glowcap_host_session_fetch (session-ptr c) (pin-immobile nb) (bytes-length nb)))
      (check/host rc)
      (define fresh (adopt-minted-vow! m c id #f #f))
      ;; The drain parks the fetch deliver on the connection's pending-writes
      ;; FIFO; `with-host-drain` runs the write once the lock releases, like
      ;; every drain.
      (values (drain-host-actions! m) fresh))))

;; Read one whole frame off the connection and feed its bytes (the feed drains,
;; so a reply this frame provokes is written back through the same transport).
(define (feed-next! c read-frame)
  (feed-bytes! c (outer-frame-bytes (read-frame))))

(define (transport-counter-roundtrip client-read client-write! server-read server-write!)
  (define chost (make-fresh-host))
  (define shost (make-fresh-host))
  ;; Both hellos leave before either side pumps, so neither establish blocks.
  (define client-session (open-dialed-over chost "tcp" (tcp-address-designator "127.0.0.1" 1)
                                        (connection-transport client-read client-write!)))
  (drain-host! chost)  ; the dialer's signed op:start-session is in flight
  (define server-session (open-accepted-over shost "tcp" (tcp-address-designator "127.0.0.1" 1)
                                          (connection-transport server-read server-write!)
                                          #:designator-scheme DESIGNATOR-SCHEME-ADDRESS))
  (drain-host! shost)  ; the acceptor's hello crosses it
  ;; #f: no handshake bound. Both hellos are already in the paired in-memory
  ;; transports, so each pump reads a frame that is waiting for it.
  (run-handshake! server-session #f)
  (run-handshake! client-session #f)
  ;; Publish, fetch, call: deliver, serve, resolve, one leg at a time.
  (session-publish server-session "counter" ^counter 10)
  (define fetched (scripted-fetch! client-session "counter"))
  (feed-next! server-session server-read)   ; the bootstrap fetch deliver
  (feed-next! client-session client-read)   ; its resolution settles the fetch
  (expect (and (pair? (session-vow-state fetched)) (eq? 'ok (car (session-vow-state fetched))))
          "transport: the scripted fetch fulfilled")
  (define counter-ref (cdr (session-vow-state fetched)))
  (expect (ref? counter-ref) "transport: fetched a capability")
  ;; Explicitly retire the consumed fetch question and serve its deterministic
  ;; GC frame before the next scripted leg. A finalizer is not an ordering
  ;; primitive, and this harness reads one whole frame at a time.
  (release-vow! fetched)
  (feed-next! server-session server-read)
  (feed-next! client-session client-read)
  (define vow (session-far-send client-session counter-ref 'add '(5) #t))
  (drain-host! chost)                    ; the deliver leaves
  (feed-next! server-session server-read)   ; the served turn runs, the resolve leaves
  (feed-next! client-session client-read)   ; the resolve settles the vow
  (define settled (session-vow-state vow))
  (session-close! client-session)
  (session-close! server-session)
  (if (and (pair? settled) (eq? 'ok (car settled)))
      (cdr settled)
      settled))

;; libglowcap_net_transport_inproc: the socket-free netlayer. A listener binds a
;; string designator; a dialer names it. The listener adds only a wake descriptor
;; so a Racket green thread can park without freezing the place.
(define inproc-nl (make-inproc-netlayer))
(define inproc-lst (inproc-netlayer-listen inproc-nl "smoke-rendezvous"))
(define inproc-accept-started (make-semaphore 0))
(define inproc-accepted (make-channel))
(define inproc-accept-thread
  (thread (lambda ()
            (semaphore-post inproc-accept-started)
            (channel-put inproc-accepted (inproc-listener-accept inproc-lst)))))
(semaphore-wait inproc-accept-started)
;; If accept entered the blocking C call directly, this connect could never run:
;; both are green threads in this place. The readiness gate parks only accepter.
(define inproc-client (inproc-netlayer-connect inproc-nl "smoke-rendezvous"))
(define inproc-server (channel-get inproc-accepted))
(define inproc-total
  (transport-counter-roundtrip
   (lambda () (inproc-connection-read-frame inproc-client))
   (lambda (f) (inproc-connection-write-frame! inproc-client f))
   (lambda () (inproc-connection-read-frame inproc-server))
   (lambda (f) (inproc-connection-write-frame! inproc-server f))))
(expect (equal? 15 inproc-total)
        (format "inproc: counter.add(5) expected 15 over the socket-free netlayer, got ~a"
                inproc-total))
(inproc-netlayer-release! inproc-nl)
;; Netlayer release owns its borrowed children; their explicit releases remain
;; idempotent and must never touch the backend that is now gone.
(inproc-connection-release! inproc-client)
(inproc-connection-release! inproc-server)
(inproc-listener-release! inproc-lst)

(printf "racket zig-smoke OK: drove OCapN over the socket-free in-process netlayer\n")

;; libglowcap_net_transport_tcp: the explicit C-ABI TCP netlayer (cleartext,
;; loopback-grade). Same round-trip over real sockets, proving the tcp module
;; composes with the host tier just as inproc does, a different archive, one core.
(define tcp-nl (make-netlayer))
(define tcp-lst (netlayer-listen tcp-nl "127.0.0.1" 0))
(define tcp-port (listener-port tcp-lst))
(define tcp-accept-started (make-semaphore 0))
(define tcp-accepted (make-channel))
(define tcp-accept-thread
  (thread (lambda ()
            (semaphore-post tcp-accept-started)
            (channel-put tcp-accepted (listener-accept tcp-lst)))))
(semaphore-wait tcp-accept-started)
(define tcp-client (netlayer-connect tcp-nl "127.0.0.1" tcp-port))
(define tcp-server (channel-get tcp-accepted))
(define tcp-total
  (transport-counter-roundtrip
   (lambda () (connection-read-frame tcp-client))
   (lambda (f) (connection-write-frame! tcp-client f))
   (lambda () (connection-read-frame tcp-server))
   (lambda (f) (connection-write-frame! tcp-server f))))
(expect (equal? 15 tcp-total) "tcp netlayer: counter.add(5) round-tripped to 15 over the C-ABI TCP transport")
(netlayer-release! tcp-nl)
(connection-release! tcp-client)
(connection-release! tcp-server)
(listener-release! tcp-lst)

(printf "racket zig-smoke OK: drove OCapN over the C-ABI TCP netlayer\n")
;; libglowcap_net_transport_onion: the one netlayer the OCapN draft standardizes,
;; reached through a Tor daemon the deployment runs. There is no Tor here, so a
;; fake control endpoint on loopback answers the exact requests glowcap sends. The
;; bytes those requests must contain are pinned on the Zig side against the pinned
;; Spritely Goblins netlayer and the upstream OCapN suite; this proves the Racket
;; surface reaches them and reads the answers back.
(define onion-service-id "wy46gxdweyqn5m7ntzwlxinhdia2jjanlsh37gxklwhfec7yxqr4k3qd")
(define onion-service-key #"ED25519-V3:c3RvcmVk")

;; The fake daemon runs as a child process, and that is not incidental. A foreign
;; call marked `#:blocking?` tells the Racket runtime the call may block, so the
;; collector stays cooperative; it does not hand the scheduler to another Racket
;; thread. Every green thread in this place stops for the whole call. Since
;; `onion-netlayer-listen` and `onion-listener-accept` each wait on an answer from
;; the daemon, a daemon written as a thread beside them would be waiting for a
;; scheduler that cannot run until it replies. `zig-smoke-fake-tor.rkt` carries the
;; same note where the daemon lives.
(define-runtime-path fake-tor-path "../../zig-smoke-fake-tor.rkt")

;; The SOCKS endpoint for the sections that never dial: an absolute Unix socket
;; path, which is the other form `make-onion-netlayer` accepts and the one a
;; distribution's Tor offers. Nothing is bound there, so a section that
;; reached it would fail rather than quietly connect somewhere.
(define absent-socks "/run/glowcap-smoke/absent.socks")

;; The first record in `seen` matching `rx`, or #f. Records accumulate newest-first.
(define (seen-line seen rx)
  (for/first ([line (in-list (reverse (unbox seen)))] #:when (regexp-match rx line))
    line))

;; Wait for a record matching `rx`, so a test never races the daemon. Raises rather
;; than returning #f: an absent record means the daemon never saw the request, which
;; is a failure to report and not a value to compare against.
(define (await-record seen rx)
  (let loop ([tries 500])
    (cond [(seen-line seen rx) => (lambda (line) (cadr (regexp-match rx line)))]
          [(zero? tries) (error 'await-record "no record matching ~a arrived" rx)]
          [else (sleep 0.01) (loop (sub1 tries))])))

;; The running Racket, resolved to an absolute path. `exec-file` is how it was
;; invoked, which on a PATH launch is the bare name `subprocess` cannot exec.
(define racket-exe
  (let ([named (find-system-path 'exec-file)])
    (or (find-executable-path named)
        (error 'start-fake-tor "cannot locate the racket executable ~a" named))))

;; Start the fake daemon and return its two endpoints, the box its records
;; accumulate in, and a thunk that stops it.
(define (start-fake-tor)
  (define-values (proc pout pin perr)
    (subprocess #f #f (current-error-port)
                racket-exe "-y" (path->string fake-tor-path)))
  (close-output-port pin)
  (define seen (box '()))
  ;; Drains the daemon's stdout so a full pipe can never stall it. This thread is
  ;; stopped for the duration of every blocking onion call, which is why the records
  ;; it collects are only ever read between them.
  (thread (lambda ()
            (let loop ()
              (define line (read-line pout 'any))
              (unless (eof-object? line)
                (set-box! seen (cons line (unbox seen)))
                (loop)))))
  (values (await-record seen #rx"^control (.*)$")
          (await-record seen #rx"^socks (.*)$")
          seen
          (lambda () (subprocess-kill proc #t))))

;; The generic driver retains the package callback context after the onion
;; constructor reference is dropped by the transport-owned installer.
(let ()
  (define-values (control _socks seen stop!) (start-fake-tor))
  (define lp (open-driver-loop #:wire-buffer-bytes 1024 #:max-pending-opens 8))
  (dynamic-wind
   void
   (lambda ()
     (onion-install-provider! lp #:socks absent-socks #:control control)
     (expect (driver-loop-has-transport? lp "onion")
             "onion: the generic driver registered the provider package")
     (define listener (loop-listen! lp "onion" ""))
     (driver-loop-start! lp)
     (set! listener (loop-listener-ready! listener))
     (define loc (loop-listener-locator lp listener))
     (expect (string=? (locator-transport loc) "onion")
             "onion: the retained provider reports its transport")
     (expect (string=? (locator-designator loc) onion-service-id)
             "onion: the retained provider reports the service Tor named")
     (loop-listener-close! lp listener)
     (expect (equal? "AUTHENTICATE" (await-record seen #rx"^line (AUTHENTICATE.*)$"))
             "onion: provider-backed listen reached the configured daemon"))
   (lambda ()
     (driver-loop-abort! lp)
     (stop!))))

;; The high-level onion listener is only a provider package plus the generic
;; driver server. Its URI comes from the driver's canonical locator, while the
;; opaque restoration bytes become a Tor service key only in the onion module.
(let ()
  (define-values (control _socks _seen stop!) (start-fake-tor))
  (define server
    (listen-onion #:socks absent-socks #:control control))
  (expect (onion-server? server)
          "onion server: high-level listener has the transport-owned type")
  (expect (string=? (onion-server-service-id server) onion-service-id)
          "onion server: service id comes from the driver locator")
  (expect (string=? (onion-server-uri server)
                    (format-peer-uri "onion" onion-service-id))
          "onion server: URI is the driver's canonical locator")
  (expect (bytes=? (onion-server-service-key server) onion-service-key)
          "onion server: restoration state is interpreted as the Tor service key")
  (define parked-result (make-channel))
  (define parked-accept
    (thread
     (lambda ()
       (channel-put parked-result
                    (with-handlers ([exn? values])
                      (onion-server-accept server)
                      'accepted)))))
  (sleep 0.02)
  (onion-server-close! server)
  (expect (exn? (sync/timeout 2 parked-result))
          "onion server: close wakes a parked high-level accept")
  (thread-wait parked-accept)
  (stop!))

(printf "racket zig-smoke OK: high-level onion listening uses the generic driver server\n")

;; The dial half of the same composition: `connect-onion` composes the
;; provider, admits the dial through the generic loop, and projects the
;; provider's connect failure as the typed refusal. The SOCKS endpoint is the
;; absent path, so the provider's dial fails at once and nothing here waits on
;; a real Tor.
(let ()
  (define-values (control _socks _seen stop!) (start-fake-tor))
  (define failure
    (with-handlers ([exn:fail:glowcap? values])
      (connect-onion (onion-locator onion-service-id)
                     #:socks absent-socks
                     #:control control)
      'connected))
  (expect (exn:fail:glowcap? failure)
          "onion connect: an unreachable SOCKS endpoint is a typed dial refusal")
  (stop!))

(printf "racket zig-smoke OK: connect-onion admits its dial and reports the typed refusal\n")

;; Closing a listener before its resident setup starts cancels the pending
;; FFI operation and settles the Racket event; it must not leave a waiter
;; parked forever or call the driver's close path a second time.
(let ()
  (define-values (control _socks _seen stop!) (start-fake-tor))
  (define lp (open-driver-loop))
  (dynamic-wind
   void
   (lambda ()
     (onion-install-provider! lp #:socks absent-socks #:control control)
     (define listener (loop-listen! lp "onion" ""))
     (loop-listener-close! lp listener)
     (expect (exn? (sync/timeout 1 listener))
             "onion: closing pending listener settles its setup event"))
   (lambda ()
     (driver-loop-abort! lp)
     (stop!))))

(printf "racket zig-smoke OK: pending listener close cancels and settles exactly once\n")

;; Supplying a Host keeps it caller-owned even though the listener adopts it
;; into a newly created driver loop.
(let ()
  (define-values (control _socks _seen stop!) (start-fake-tor))
  (define host (make-fresh-host))
  (define server (listen-onion #:socks absent-socks #:control control #:host host))
  (expect (eq? host (onion-server-host server))
          "onion server: supplied Host wrapper is preserved")
  (onion-server-close! server)
  (expect (not (unbox (host-released? host)))
          "onion server: closing a supplied-Host listener does not release Host")
  (host-close! host)
  (stop!))

;; Drive one `listen` against the fake daemon and report the AUTHENTICATE line it
;; saw. Recording the credential is the point: every other assertion here uses an
;; unauthenticated endpoint, where a mapping that sent no credential at all would
;; look exactly like success.
(define (authenticate-line-for auth-kind secret)
  (define-values (control _socks seen stop!) (start-fake-tor))
  (define nl (make-onion-netlayer #:socks absent-socks
                                  #:control control
                                  #:auth-kind auth-kind
                                  #:auth-secret secret))
  (onion-listener-release! (onion-netlayer-listen nl))
  (onion-netlayer-release! nl)
  (begin0 (await-record seen #rx"^line (AUTHENTICATE.*)$")
          (stop!)))

;; Hosting reports the id the daemon named and the key that restores it, and the
;; readiness descriptor is the live accept socket rather than merely a number.
(let ()
  (define-values (control _socks seen stop!) (start-fake-tor))
  (define nl (make-onion-netlayer #:socks absent-socks #:control control))
  (define lst (onion-netlayer-listen nl))
  (expect (equal? onion-service-id (onion-listener-service-id lst))
          "onion: the listener published the service id the daemon named")
  (expect (equal? onion-service-key (onion-listener-service-key lst))
          "onion: the listener reported the key that restores the same address")
  (define fd (onion-listener-readiness-fd lst))
  (expect (>= fd 0) "onion: the listener handed back a readiness descriptor")
  ;; Nothing has dialed, so the wait expires rather than parking.
  (expect (not (onion-listener-wait lst 1))
          "onion: readiness reports not-ready before any circuit arrives")

  ;; Release owns cancellation as well as storage. A green thread parked before
  ;; FFI accept must wake and retire before the listener payload is freed.
  (define parked-result (make-channel))
  (define parked-listener (onion-netlayer-listen nl))
  (define parked-accept
    (thread
     (lambda ()
       (channel-put
        parked-result
        (with-handlers ([exn:fail? values])
          (onion-listener-accept parked-listener)
          'accepted)))))
  (sleep 0.02)
  (onion-listener-release! parked-listener)
  (expect (exn:fail? (sync/timeout 2 parked-result))
          "onion: listener release wakes a parked accept")
  (thread-wait parked-accept)

  ;; Ask the daemon what forward target the ADD_ONION named, then stand in for Tor
  ;; forwarding a circuit to it.
  (define forward-target (await-record seen #rx"^line ADD_ONION.*PORT=[0-9]+,(.*)$"))
  (define parts (regexp-match #rx"^(.*):([0-9]+)$" forward-target))
  (define-values (cin cout)
    (tcp-connect (cadr parts) (string->number (caddr parts))))
  ;; Now readiness reports arrival, so accept returns instead of parking.
  (expect (onion-listener-wait lst 2000)
          "onion: readiness reports the arriving circuit on the same descriptor")
  (define accepted (onion-listener-accept lst))
  (expect (>= (onion-connection-readiness-fd accepted) 0)
          "onion: the accepted connection has its own readiness descriptor")
  (onion-connection-release! accepted)
  (close-input-port cin)
  (close-output-port cout)
  ;; Releasing the owner retires children before its std.Io backend.
  (onion-netlayer-release! nl)
  (expect (with-handlers ([exn:fail? (lambda (_) #t)])
            (onion-listener-readiness-fd lst) #f)
          "onion: netlayer release closed its live listener first")
  (onion-listener-release! lst) ; idempotent after owner-driven release
  (stop!))

;; The dial half: a circuit carries a framed message. What reaches the wire is the
;; frame inside its netstring envelope, a Syrup byte string whose length prefix the
;; reader strips again.
(let ()
  (define-values (_control socks seen stop!) (start-fake-tor))
  (define nl (make-onion-netlayer #:socks socks))
  (define cn (onion-netlayer-connect nl onion-service-id))
  (onion-connection-write-frame! cn #"<8'op:abort3\"bye>")
  (expect (equal? "17:<8'op:abort3\"bye>" (await-record seen #rx"^wrote (.*)$"))
          "onion: a dial carried a framed message over the circuit")
  (onion-connection-release! cn)
  (onion-netlayer-release! nl)
  (stop!))

;; Each credential form reaches the daemon as itself.
(expect (equal? "AUTHENTICATE" (authenticate-line-for AUTH-NONE #f))
        "onion: an unauthenticated control endpoint gets the bare keyword")
(expect (equal? "AUTHENTICATE 00010fff"
                (authenticate-line-for AUTH-COOKIE (bytes 0 1 15 255)))
        "onion: a cookie travels as hexadecimal")
(expect (equal? "AUTHENTICATE \"hunter2\""
                (authenticate-line-for AUTH-PASSWORD "hunter2"))
        "onion: a password travels as a quoted string")

;; A dial-only netlayer can reach out and cannot host.
(let ()
  (define nl (make-onion-netlayer #:socks absent-socks))
  (expect (with-handlers ([exn:fail? (lambda (_) #t)])
            (onion-netlayer-listen nl) #f)
          "onion: a dial-only netlayer refuses to host")
  ;; A designator that is not a well-formed version 3 address is refused before any
  ;; socket opens, so this is an argument fault rather than a dial failure.
  (expect (with-handlers ([exn:fail? (lambda (_) #t)])
            (onion-netlayer-connect nl "not-an-onion-address") #f)
          "onion: a malformed designator is refused before dialing")
  (onion-netlayer-release! nl))
