#lang racket/base
;; tcp-netlayer.rkt: a minimal TCP netlayer for Spritely Goblins's CapTP.
;;
;; Modeled after `goblins/ocapn/netlayer/fake-intarwebs.rkt`, but with
;; real `tcp-listen` / `tcp-connect` instead of an in-process pipe.
;; Provides `^tcp-netlayer`, spawn it with the local bind host+port,
;; pass the resulting netlayer to `spawn-mycapn`, and the Vat speaks
;; CapTP over TCP.
;;
;; Address scheme: `(ocapn-node 'tcp "host:port" #f)`. URL form
;; `ocapn://<host>:<port>.tcp`. Sturdyrefs are
;; `ocapn://<host>:<port>.tcp/s/<base64url-swiss-num>`.
;;
;; What this is for: glowcap ↔ Goblins interop demo work. The netlayer
;; lives in the goblins-peer/ slim impl as the transport mechanism that
;; lets the Goblins Vat be a network peer glowcap can dial. The
;; accountability-on-goblins/ impl reuses it for cross-Vat demos via
;; relative-path require.
;;
;; What this is NOT:
;; - Production-grade. No TLS, no auth at the netlayer (CapTP's own
;;   session keys cover authenticity, but bytes on the wire are clear).
;; - Full Spritely netlayer: no graceful shutdown, no reconnect-on-loss,
;;   minimal error reporting. Good enough for a localhost demo.

(require goblins
         goblins/actor-lib/methods
         goblins/actor-lib/sync-pr
         goblins/ocapn/structs-urls
         (submod goblins/ocapn/structs-urls marshall)
         "captp-message-procs.rkt"
         "session-trace.rkt"
         racket/async-channel
         racket/match
         racket/tcp
         racket/string)

(provide ^tcp-netlayer)

;; Latest CapTP write proc for the active session (interop-only). Updated when
;; a connection hands `write-message` to mycapn.
(define interop-captp-writer (box #f))

;; Constructor for a TCP netlayer.
;;
;;   listen-host: string passed to `tcp-listen`. Use "127.0.0.1" for
;;                  loopback-only, "0.0.0.0" for any interface.
;;   listen-port: integer port to bind.
;;   announce-host: string used in the netlayer's advertised location
;;                   (what dialers will use to reach back). Often the
;;                   same as listen-host; differs when we bind 0.0.0.0
;;                   but want to advertise a specific external name.
;;
;; Optional `#:trace trace-fn`, a `(lambda (event . args) ...)`
;; called for each TCP-level event the netlayer observes:
;;
;;   (trace-fn 'accept self-location)
;;       ,  incoming connection accepted on our listening port
;;   (trace-fn 'connect self-location remote-location)
;;       ,  outbound connect_to dialing a remote peer
;;
;; The default no-ops. `three-vat-demo.rkt` uses it to observe whether
;; a third Vat dials a peer directly or routes via an introducer
;; (the essential signal that OCapN three-party handoff
;; happens).
;; Optional `#:location-hints hints`, a value to advertise as the netlayer's
;; own location hints (e.g. a hash of route metadata). The contracted
;; `ocapn-node` constructor admits only #f-or-string hints, while the wire
;; unmarshaller builds nodes through the raw constructor and accepts the
;; draft's mapping shape; an advertised mapping hint must be exactly what a
;; decoded hello would hold, so the hinted location is built through the
;; unmarshaller's own constructor.
;;
;; Optional `#:session-trace sink`, a `(lambda (event handle info) ...)` called
;; with the CapTP session facts this netlayer observes at the wire:
;;
;;   (sink 'open handle info)
;;       ,  a session finished its handshake. `info` is an immutable hash
;;         carrying `'transport`, `'our-designator`, `'partner-designator`,
;;         `'session-id`, `'captp-version`, `'codec` and
;;         `'durable-provenance`.
;;   (sink 'close handle #f)
;;       ,  that session ended. Only sessions whose open was reported.
;;
;; `handle` is this netlayer's own name for the session and is meaningful to
;; nobody else; a sink that publishes correlates on the Session ID in `info`,
;; which both ends of the session derive alike. The default is #f, and with no
;; sink the wire path is untouched.
;;
;; Optional `#:interop-message-sink sink`, test-only observation of decoded
;; inbound CapTP records before this netlayer hands them to Goblins. This is not
;; an application API; it exists so glowcap's interop probes can prove a
;; canonical Goblins-written frame caused the partner's semantic response even
;; where the pinned Goblins release has no public API for creating that request.
;; `#:interop-outbound-message-sink` is the symmetric hook: it observes decoded
;; outbound records before encoding, so a probe can refer to a Goblins-allocated
;; wire name without guessing the allocator's current position.
(define make-wire-ocapn-node (cdr unmarshall::ocapn-node))

(define (^tcp-netlayer _bcom
                       listen-host
                       listen-port
                       [announce-host listen-host]
                       #:trace [trace-fn void]
                       #:location-hints [location-hints #f]
                       #:session-trace [session-trace #f]
                       #:interop-message-sink [interop-message-sink #f]
                       #:interop-outbound-message-sink [interop-outbound-message-sink #f])
  ;; The bind happens here, on the caller's thread, so returning from the
  ;; constructor means the port is listening and a dial lands in its backlog.
  ;; Anything later, `setup`, the accept thread below, leaves a window where a
  ;; host has printed `vat-ready` and a peer has been handed a locator naming
  ;; this vat while nothing is bound, and the dial fails with connection
  ;; refused. It is also the only place the ephemeral port below can be read.
  (define listener (tcp-listen listen-port 5 #t listen-host))

  ;; The port the OS bound. `listen-port` may be 0, which asks for an ephemeral
  ;; one, and the announced location has to name the port a dialer can reach.
  (define bound-port
    (let-values ([(_host port _remote-host _remote-port) (tcp-addresses listener #t)])
      port))

  ;; What this netlayer calls itself. A `tcp` locator's designator is the
  ;; address a peer dials to reach it, and this netlayer carries one peer per
  ;; socket, so the designator names the peer as much as the route: a session
  ;; trace reports it as this vat's own endpoint, and a partner reaching this
  ;; vat reaches it by the same string. It is a claim rather than a proof. An
  ;; address is not a key, and nothing on this path authenticates a durable
  ;; name, which is why a session opened over it reports its provenance as
  ;; unauthenticated.
  (define our-designator (format "~a:~a" announce-host bound-port))
  (define our-location
    (if location-hints
        (make-wire-ocapn-node 'tcp our-designator location-hints)
        (ocapn-node 'tcp our-designator #f)))

  ;; Channel that the accept thread pushes new (input-port . output-port)
  ;; pairs onto. The Goblins netlayer body reads from it via sync/pr.
  (define new-conn-ch (make-async-channel))

  ;; Background accept thread. Spritely's fake-intarwebs gets new connections
  ;; from a `network` actor; we take them from the OS with `tcp-accept` on the
  ;; listener the constructor already bound. The thread starts when `setup` is
  ;; called and lives for the netlayer's lifetime; until then a dialer waits in
  ;; the backlog rather than being refused.
  (define (start-tcp-listener)
    (thread
     (lambda ()
       (let loop ()
         (define-values (in out) (tcp-accept listener))
         (trace-fn 'accept our-location)
         (async-channel-put new-conn-ch (vector in out))
         (loop)))))

  ;; The message procs one connection runs on, traced when a sink was given.
  ;; A `tcp` locator designates a socket address rather than a key, and nothing
  ;; on this path authenticates a durable name, so every session over it reports
  ;; its provenance as unauthenticated whatever the partner claims.
  (define (connection-procs in out)
    (define-values (read-message write-message) (captp-message-procs in out))
    (define (observed-read-message unmarshallers)
      (define msg (read-message unmarshallers))
      (when (and interop-message-sink (not (eof-object? msg)))
        (interop-message-sink msg))
      msg)
    (define (observed-write-message msg marshallers)
      (when interop-outbound-message-sink
        (interop-outbound-message-sink msg))
      (write-message msg marshallers))
    (if session-trace
        (traced-message-procs observed-read-message observed-write-message session-trace
                              #:transport "tcp"
                              #:our-designator our-designator
                              #:provenance (lambda (_claimed) provenance-unauthenticated))
        (values observed-read-message observed-write-message)))

  (define (register-captp-writer write-message)
    (set-box! interop-captp-writer write-message))

  (define (start-listening conn-establisher)
    (let listen-loop ()
      (on (sync/pr new-conn-ch)
          (match-lambda
            [(list (vector ip op))
             (define-values (read-message write-message)
               (connection-procs ip op))
             (register-captp-writer write-message)
             (<- conn-establisher read-message write-message #f)])
          #:finally listen-loop)))

  (define (split-host-port designator)
    (define parts (string-split designator ":"))
    (case (length parts)
      [(2) (values (car parts) (string->number (cadr parts)))]
      [else (error '^tcp-netlayer "expected host:port designator, got ~v" designator)]))

  (define (^netlayer bcom)
    (define base-beh
      (methods
       [(netlayer-name) 'tcp]
       [(our-location) our-location]))

    ;; Pre-setup: waits for `setup` to start the accept thread and
    ;; transition into the ready behavior.
    (define pre-setup-beh
      (methods
       #:extends base-beh
       [(setup conn-establisher)
        (start-tcp-listener)
        (start-listening conn-establisher)
        (bcom (ready-beh conn-establisher))]))

    (define (ready-beh conn-establisher)
      (methods
       #:extends base-beh
       [(self-location? loc)
        (same-node-location? our-location loc)]
       [(connect-to remote-node)
        ;; Dial by transport + designator alone. Hints are route advice this
        ;; netlayer does not need, and a node decoded off the wire can carry
        ;; mapping-shaped hints (the unmarshaller uses the raw constructor),
        ;; so the dial neither pins the empty-`#f` spelling nor reads the
        ;; hints field through the contracted accessor.
        (match remote-node
          [(? (lambda (n) (and (ocapn-node? n)
                               (eq? (ocapn-node-transport n) 'tcp))))
           (define designator (ocapn-node-designator remote-node))
           (trace-fn 'connect our-location remote-node)
           (define-values (host port) (split-host-port designator))
           (define-values (in out) (tcp-connect host port))
           (define-values (read-message write-message)
             (connection-procs in out))
           (register-captp-writer write-message)
           (<- conn-establisher read-message write-message remote-node)])]
       ;; Interop-only: write a CapTP record on the active session. Used when
       ;; Goblins lacks an outbound projection API but the wire op is canonical.
       [(interop-send msg marshallers)
        (match (unbox interop-captp-writer)
          [#f (error '^tcp-netlayer "no active CapTP writer for interop-send")]
          [write-message (write-message msg marshallers)])]))

    pre-setup-beh)

  (spawn ^netlayer))
