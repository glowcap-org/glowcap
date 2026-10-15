#lang racket/base
;; Public WebRTC composition over the signaling exchanges in `runtime.rkt`.
;;
;; A WebRTC dial is one signaling exchange the application carries itself.
;; The provider hands the application an offer and a target naming the peer and
;; takes back an answer and candidates. A WebRTC listen is the same exchange
;; the other way round: the application hands each inbound offer to the server
;; and carries the answer back. Nothing here picks a signaling service.

(require "../constants.rkt"
         "../listen-loop.rkt"
         "../locator.rkt"
         "../seam.rkt"
         "../server-verbs.rkt"
         "../transport.rkt"
         "netlayer.rkt"
         "runtime.rkt")

(provide webrtc-locator
         webrtc-ice-server (rename-out [ice-server? webrtc-ice-server?])
         webrtc-config webrtc-config?
         make-webrtc-signaling webrtc-signaling?
         (struct-out webrtc-target)
         webrtc-provider
         listen-webrtc webrtc-server?
         webrtc-server-host webrtc-server-locator webrtc-server-uri
         webrtc-server-designator webrtc-server-accept webrtc-server-close!
         webrtc-server-provide-offer! webrtc-server-fail-exchange!)

(define (webrtc-locator designator)
  (unless (and (string? designator) (positive? (string-length designator)))
    (raise-argument-error 'webrtc-locator "non-empty string" designator))
  (locator TRANSPORT-WEBRTC designator (hash) 'boolean-false))

;; One STUN or TURN server. `username` and `credential` are both empty for a
;; STUN server and both set for a TURN server.
(define (webrtc-ice-server urls #:username [username ""] #:credential [credential ""])
  (unless (and (list? urls) (pair? urls) (andmap string? urls))
    (raise-argument-error 'webrtc-ice-server "non-empty (listof string?)" urls))
  (unless (and (string? username) (string? credential))
    (raise-argument-error 'webrtc-ice-server "string? for #:username and #:credential"
                          (list username credential)))
  (ice-server urls username credential))

;; The default has no ICE servers, so only host candidates are gathered, and
;; leaves loopback addresses out. `#:include-loopback-candidates?` offers them
;; too, for two peers on one machine.
(struct config-record (ice-servers loopback?) #:transparent)
(define (webrtc-config #:ice-servers [ice-servers '()]
                       #:include-loopback-candidates? [loopback? #f])
  (unless (and (list? ice-servers) (andmap ice-server? ice-servers))
    (raise-argument-error 'webrtc-config "(listof webrtc-ice-server?)" ice-servers))
  (config-record ice-servers (and loopback? #t)))
(define (webrtc-config? v) (config-record? v))

;; The four procedures carry signaling for both directions, and a program that
;; only dials or only answers still supplies all four. Each takes the exchange
;; id first, the exact integer the library minted for that dial or accept. The
;; calls that open an exchange's route, `#:offer`, `#:answer`, and
;; `#:on-candidate`, also take its `webrtc-target`. `#:candidate` takes only the
;; id. `#:offer` returns the SDP answer to a dial's offer.
;; `#:answer` carries the SDP answer to an inbound offer back to the offerer,
;; and raising refuses that offer. It runs inside `webrtc-server-provide-offer!`
;; in atomic mode, so it must return without waiting. Hand the answer to a
;; thread that sends it. `#:candidate` carries one local ICE candidate as JSON
;; text. `#:on-candidate` subscribes to the far peer's candidates for one
;; exchange and returns a thunk that ends the subscription. The far peer may
;; trickle candidates before the subscription exists, so the application
;; buffers what arrives for an exchange until its sink does. Signaling routes
;; by exchange id, so a dial to a peer and that peer's own offer run side by
;; side as two exchanges.
;;
;; A dial runs `#:on-candidate` and then `#:offer` on one thread, then
;; `#:candidate` for each local candidate. An accept runs `#:answer` inside
;; `webrtc-server-provide-offer!`, then `#:on-candidate` on a thread of its own,
;; then `#:candidate` for each local candidate.
(define (make-webrtc-signaling #:offer offer #:answer answer
                               #:candidate candidate #:on-candidate on-candidate)
  (for ([proc (in-list (list offer answer candidate on-candidate))])
    (unless (procedure? proc)
      (raise-argument-error 'make-webrtc-signaling "procedure?" proc)))
  (signaling offer answer candidate on-candidate))
(define (webrtc-signaling? v) (signaling? v))

;; Put the application's signaling on `lp` as one WebRTC netlayer. The provider
;; and the listener install through here, so they cannot differ.
(define (install-netlayer! lp config sig)
  (webrtc-adopt-loop! lp (config-record-ice-servers config) (config-record-loopback? config) sig))

(define (check-signaling+config who sig config)
  (unless (signaling? sig)
    (raise-argument-error who "webrtc-signaling?" sig))
  (unless (config-record? config)
    (raise-argument-error who "webrtc-config?" config)))

;; The provider dials every `webrtc` locator by running the application's
;; signaling. A dial whose answer never arrives fails at the handshake
;; deadline. A signaling procedure that raises records its error on the Host
;; and gives the dial up, so it fails at the driver's next step. A Host that
;; should also answer offers uses `listen-webrtc` instead.
(define (webrtc-provider sig [config (webrtc-config)])
  (check-signaling+config 'webrtc-provider sig config)
  (make-driver-provider
   (lambda (lp host) (void (install-netlayer! lp config sig)))))

;; A Host answering WebRTC offers. `callbacks` holds the application's two
;; verbs, and `loop-server` owns the listener, the accept handshake, and every
;; accepted session.
(struct webrtc-server (loop-server callbacks))

;; Compose a WebRTC netlayer into a Host, open its listener, and advertise it.
;; A WebRTC peer is reachable only as its key, so the designator is the Host's
;; own and the identity comes from the same rule every keyed listener uses:
;; `#:seed` restores a key, `#:host` shares an existing Host's, and with neither
;; the key is new. The keywords are the other listeners', each honored exactly
;; or refused. The same netlayer dials, so a Runtime that adopts the server's
;; Host with no further provider connects to a `webrtc-locator` through it.
(define (listen-webrtc sig [config (webrtc-config)]
                       #:seed [seed #f] #:host [host #f]
                       #:codec [codec #f] #:captp-version [captp-version #f]
                       #:features [features #f])
  (check-signaling+config 'listen-webrtc sig config)
  (define callbacks #f)
  (define server
    ;; An empty designator asks the library for the Host's own key.
    (listen-loop-profile 'listen-webrtc TRANSPORT-WEBRTC ""
                         #:identity? #t
                         #:seed seed #:codec codec #:captp-version captp-version
                         #:features features #:options #f
                         #:host host #:time-travel? #f
                         #:install (lambda (lp)
                                     (set! callbacks (install-netlayer! lp config sig)))))
  (webrtc-server server callbacks))

(define (webrtc-server-host s) (server-host (webrtc-server-loop-server s)))
(define (webrtc-server-locator s) (server-locator (webrtc-server-loop-server s)))
(define (webrtc-server-uri s) (server-uri (webrtc-server-loop-server s)))
(define (webrtc-server-designator s) (locator-designator (webrtc-server-locator s)))
(define (webrtc-server-accept s) (accept (webrtc-server-loop-server s)))
(define (webrtc-server-close! s) (server-close! (webrtc-server-loop-server s)))

;; Hand in an SDP offer from the peer whose designator is `designator`. The
;; library answers through the signaling's `#:answer` before this returns, and
;; the exchange id names the accept for `webrtc-server-fail-exchange!`. A raise
;; means no exchange started: the listener is closed, the offerer's key is not a
;; key, too many accepts are in
;; flight, or the signaling refused the answer. An accept has no deadline of its
;; own, so one whose offerer goes quiet holds its place until the application
;; gives it up.
(define (webrtc-server-provide-offer! s designator sdp)
  (unless (string? designator)
    (raise-argument-error 'webrtc-server-provide-offer! "string?" designator))
  (unless (string? sdp)
    (raise-argument-error 'webrtc-server-provide-offer! "string?" sdp))
  ((exchange-callbacks-provide-offer (webrtc-server-callbacks s)) designator sdp))

;; Give up the accept `exchange` because its signaling broke or its offerer
;; went quiet. It ends without a session and its candidate subscription ends. A
;; raise means no such accept is in progress or its channel already opened, and
;; nothing changed.
(define (webrtc-server-fail-exchange! s exchange)
  (unless (exact-nonnegative-integer? exchange)
    (raise-argument-error 'webrtc-server-fail-exchange! "exact-nonnegative-integer?" exchange))
  ((exchange-callbacks-fail-exchange (webrtc-server-callbacks s)) exchange))

(module+ test
  (require rackunit
           (only-in "../errors.rkt" exn:fail:glowcap? exn:fail:glowcap-code)
           (only-in "../host.rkt" make-host host-close!))
  (define sig
    (make-webrtc-signaling #:offer (lambda (x d s) "")
                           #:answer void
                           #:candidate void
                           #:on-candidate (lambda (x d sink) void)))
  (check-equal? (locator-transport (webrtc-locator "ab")) TRANSPORT-WEBRTC)
  (check-equal? (locator-designator (webrtc-locator "ab")) "ab")
  (check-exn exn:fail:contract? (lambda () (webrtc-locator "")))
  (check-true (webrtc-signaling? sig))
  (check-exn exn:fail:contract?
             (lambda ()
               (make-webrtc-signaling #:offer 1 #:answer void #:candidate void
                                      #:on-candidate (lambda (x d sink) void))))
  (define stun (webrtc-ice-server '("stun:stun.example.test:3478")))
  (check-true (ice-server? stun))
  (check-exn exn:fail:contract? (lambda () (webrtc-ice-server '())))
  (check-true (webrtc-config? (webrtc-config #:ice-servers (list stun))))
  (check-exn exn:fail:contract? (lambda () (webrtc-config #:ice-servers '(1))))
  (check-true (config-record-loopback? (webrtc-config #:include-loopback-candidates? #t)))
  (check-false (config-record-loopback? (webrtc-config)))
  ;; Building a provider opens no library: it is a value until a loop installs it.
  (check-true (driver-provider? (webrtc-provider sig)))
  (check-exn exn:fail:contract? (lambda () (webrtc-provider 'nope)))
  (check-exn exn:fail:contract? (lambda () (listen-webrtc 'nope)))
  ;; A listener refuses a bad identity before it opens anything.
  (define (refusal-code thunk)
    (with-handlers ([exn:fail:glowcap? exn:fail:glowcap-code])
      (thunk)
      #f))
  (check-equal? (refusal-code (lambda () (listen-webrtc sig #:seed (make-bytes 16 1))))
                ERR-INVALID-ARGUMENT)
  (let ([host (make-host (make-bytes 32 1))])
    (check-equal? (refusal-code (lambda () (listen-webrtc sig #:seed (make-bytes 32 2) #:host host)))
                  ERR-INVALID-ARGUMENT)
    ;; Even the Host's own seed is refused beside it.
    (check-equal? (refusal-code (lambda () (listen-webrtc sig #:seed (make-bytes 32 1) #:host host)))
                  ERR-INVALID-ARGUMENT)
    (host-close! host)))
