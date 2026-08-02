#lang racket/base
;; tcp-netlayer.rkt — a minimal TCP netlayer for Spritely Goblins's CapTP.
;;
;; Modeled after `goblins/ocapn/netlayer/fake-intarwebs.rkt`, but with
;; real `tcp-listen` / `tcp-connect` instead of an in-process pipe.
;; Provides `^tcp-netlayer` — spawn it with the local bind host+port,
;; pass the resulting netlayer to `spawn-mycapn`, and the Vat speaks
;; CapTP over TCP.
;;
;; Address scheme: `(ocapn-node 'tcp "host:port" #f)`. URL form
;; `ocapn://<host>:<port>.tcp`. Sturdyrefs are
;; `ocapn://<host>:<port>.tcp/s/<base64url-swiss-num>`.
;;
;; What this is for: pancake ↔ Goblins interop demo work. The netlayer
;; lives in the goblins-peer/ slim impl as the transport mechanism that
;; lets the Goblins Vat be a network peer pancake can dial. The
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
         goblins/ocapn/netlayer/utils/read-write-procs
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
;;   listen-host  — string passed to `tcp-listen`. Use "127.0.0.1" for
;;                  loopback-only, "0.0.0.0" for any interface.
;;   listen-port  — integer port to bind.
;;   announce-host — string used in the netlayer's advertised location
;;                   (what dialers will use to reach back). Often the
;;                   same as listen-host; differs when we bind 0.0.0.0
;;                   but want to advertise a specific external name.
;;
;; Optional `#:trace trace-fn` — a `(lambda (event . args) ...)`
;; called for each TCP-level event the netlayer observes:
;;
;;   (trace-fn 'accept self-location)
;;       — incoming connection accepted on our listening port
;;   (trace-fn 'connect self-location remote-location)
;;       — outbound connect_to dialing a remote peer
;;
;; The default no-ops. `three-vat-demo.rkt` uses it to observe whether
;; a third Vat dials a peer directly or routes via an introducer
;; (the load-bearing signal that OCapN three-party handoff actually
;; happens).
;; Optional `#:location-hints hints` — a value to advertise as the netlayer's
;; own location hints (e.g. a hash of route metadata). The contracted
;; `ocapn-node` constructor admits only #f-or-string hints, while the wire
;; unmarshaller builds nodes through the raw constructor and accepts the
;; draft's mapping shape; an advertised mapping hint must be exactly what a
;; decoded hello would hold, so the hinted location is built through the
;; unmarshaller's own constructor.
(define make-wire-ocapn-node (cdr unmarshall::ocapn-node))

(define (^tcp-netlayer _bcom
                       listen-host
                       listen-port
                       [announce-host listen-host]
                       #:trace [trace-fn void]
                       #:location-hints [location-hints #f])
  (define our-location
    (if location-hints
        (make-wire-ocapn-node 'tcp (format "~a:~a" announce-host listen-port) location-hints)
        (ocapn-node 'tcp (format "~a:~a" announce-host listen-port) #f)))

  ;; Channel that the listener thread pushes new (input-port . output-port)
  ;; pairs onto. The Goblins netlayer body reads from it via sync/pr.
  (define new-conn-ch (make-async-channel))

  ;; Background listener thread. Spritely's fake-intarwebs gets new
  ;; connections from a `network` actor; we get them from the OS via
  ;; `tcp-listen`/`tcp-accept`. The thread runs once `setup` is called
  ;; and lives for the netlayer's lifetime.
  ;;
  ;; `tcp-listen` runs here, on the caller's thread, not inside the thread
  ;; below: returning from `setup` then means the port is accepting. Binding
  ;; inside the thread made readiness a lie — a host could print `vat-ready`,
  ;; and a peer could be handed a locator naming this vat, before anything was
  ;; listening, so a dial raced the bind and failed with connection refused.
  ;; That is the whole of the intermittent handoff failure: a give named an
  ;; exporter whose listener had not bound yet.
  (define (start-tcp-listener)
    (define listener (tcp-listen listen-port 5 #t listen-host))
    (thread
     (lambda ()
       (let loop ()
         (define-values (in out) (tcp-accept listener))
         (trace-fn 'accept our-location)
         (async-channel-put new-conn-ch (vector in out))
         (loop)))))

  (define (register-captp-writer write-message)
    (set-box! interop-captp-writer write-message))

  (define (start-listening conn-establisher)
    (let listen-loop ()
      (on (sync/pr new-conn-ch)
          (match-lambda
            [(list (vector ip op))
             (define-values (read-message write-message)
               (read-write-procs ip op))
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

    ;; Pre-setup: waits for `setup` to start the listener thread and
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
             (read-write-procs in out))
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
