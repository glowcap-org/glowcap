#lang racket/base
;; iroh-netlayer.rkt: an iroh netlayer for Spritely Goblins's CapTP, over
;; glowcap's iroh transport.
;;
;; A netlayer is a byte-stream provider plus a locator. CapTP is transport
;; agnostic, so this changes nothing about the protocol a Goblins vat speaks: the
;; vat goes on running its own CapTP, marshalling its own Syrup records, keeping
;; its own session keys. What changes is what carries those bytes. Where
;; `tcp-netlayer.rkt` hands the vat a cleartext socket, this hands it an
;; encrypted QUIC connection to an endpoint identified by an Ed25519 key, opened
;; through the glowcap Racket binding's iroh byte-channel surface.
;;
;; Address scheme: `(ocapn-node 'iroh <endpoint-id> hints)`, where the endpoint id
;; is the 64 lowercase hex digits of the endpoint's Ed25519 public key and the
;; hints carry `"direct-addresses"`, the comma-separated socket addresses a
;; relay-less dialer needs. That is the same spelling glowcap signs and dials, so
;; a Goblins vat and a glowcap peer name one endpoint the same way.
;;
;; Provide `^iroh-netlayer`, spawn it with a reachability posture, pass the
;; resulting netlayer to `spawn-mycapn`, and the vat speaks CapTP over iroh.
;;
;; What this is for: glowcap ↔ Goblins interop over an encrypted transport. It is
;; the sibling of `tcp-netlayer.rkt`, and the two differ only in what moves the
;; bytes and in what a session over them can accurately claim to have proved.
;;
;; What this is NOT:
;; - Full Spritely netlayer: no graceful shutdown, no reconnect-on-loss, minimal
;;   error reporting. A connection's handle is released when the endpoint is,
;;   which for a driver process is at exit. Good enough for an interop bracket.
;; - A second CapTP. The adapter holds a hello's iroh claim to the QUIC
;;   identity before Goblins sees it. Goblins owns signature verification and
;;   protocol state. Accepted records pass through unchanged.

(require goblins
         goblins/actor-lib/methods
         goblins/actor-lib/sync-pr
         goblins/ocapn/structs-urls
         (submod goblins/ocapn/structs-urls marshall)
         "captp-message-procs.rkt"
         "session-trace.rkt"
         (only-in "../../../bindings/racket/glowcap-iroh.rkt"
                  open-iroh-endpoint make-iroh-config
                  iroh-endpoint-node-id iroh-endpoint-direct-addresses
                  iroh-endpoint-accept iroh-endpoint-dial iroh-endpoint-close!
                  byte-channel byte-channel-read byte-channel-write
                  byte-channel-verified-remote byte-channel-close!)
         racket/async-channel
         racket/match)

(provide ^iroh-netlayer)

;; The locator hint naming an endpoint's directly dialable socket addresses. The
;; name is glowcap's `model.transport.hint_direct_addresses` and the iroh C ABI's
;; documented hint; spelling it differently would leave a dialer with nothing to
;; dial.
(define direct-addresses-hint "direct-addresses")

;; How many bytes of inbound stream may sit between the connection and the vat's
;; CapTP reader. Past it the reading pump stops draining the connection, the
;; sidecar's own bounded buffer fills, and QUIC flow control slows the partner,
;; so a vat that stops reading pushes back rather than growing.
(define inbound-buffer-bytes 65536)

(define make-wire-ocapn-node (cdr unmarshall::ocapn-node))

;; The `direct-addresses` hint of a node decoded off the wire, or "" when it
;; carries none. A node's hints are `#f` when empty and a mapping otherwise (the
;; unmarshaller builds nodes through the raw constructor, so the contracted
;; accessor is not used), and a discovery-posture partner legitimately publishes
;; none, so anything that is not a mapping with that key reads as no hint.
(define (node-direct-addresses node)
  (define hints (vector-ref (struct->vector node) 3))
  (define value (and (hash? hints) (hash-ref hints direct-addresses-hint #f)))
  (cond
    [(string? value) value]
    [(bytes? value) (bytes->string/utf-8 value)]
    [else ""]))

;; What a connection proves about the durable name a partner's hello claims.
;; `verified-remote` is the endpoint id QUIC authenticated for the far end of
;; this channel, in either direction, or #f when nothing proved one. A claim
;; naming that id is the transport's own word. Any other claim is unproven,
;; including the claim of a peer whose bytes a relay carries under the relay's
;; own key, because the channel's far end and the CapTP partner are then
;; different nodes.
(define ((transport-proof-provenance verified-remote) claimed)
  (if (and verified-remote (equal? claimed verified-remote))
      provenance-authenticated-transport
      provenance-unauthenticated))

;; Which hellos reach Goblins. Goblins files each session under the hello's
;; claimed locator and does not check that locator against its netlayer.
;;
;; - An iroh claim names an iroh durable identity, so it must name the endpoint
;;   QUIC authenticated. It may advertise new routing hints. A claim naming any
;;   other endpoint closes only this channel and returns EOF to Goblins'
;;   ordinary close path, and that hello never reaches telemetry or dispatch.
;; - A claim on another transport is a route this channel cannot prove, such as
;;   a browser's locator arriving through a byte relay. It reaches Goblins and
;;   is traced with the provenance above. Goblins then files the session under
;;   that unproven name, as it does for every session over its tcp netlayer.
;; - A hello whose location is not a node is refused.
(define (admitted-claim? location verified-remote)
  (and (ocapn-node? location)
       (or (not (eq? (ocapn-node-transport location) 'iroh))
           (and verified-remote
                (equal? (ocapn-node-designator location) verified-remote)))))

(define (identity-bound-message-procs read-message write-message
                                      verified-remote close!
                                      our-designator session-trace)
  (define refused? #f)
  (define (read-bound unmarshallers)
    (define msg (if refused? eof (read-message unmarshallers)))
    (define fields (and (struct? msg) (struct->vector msg)))
    (cond
      [(and fields (eq? (vector-ref fields 0) 'struct:op:start-session))
       (define location (and (= (vector-length fields) 5) (vector-ref fields 3)))
       (if (admitted-claim? location verified-remote)
           msg
           (begin (set! refused? #t) (close!) eof))]
      [else msg]))
  (if session-trace
      (traced-message-procs read-bound write-message session-trace
                            #:transport "iroh"
                            #:our-designator our-designator
                            #:provenance (transport-proof-provenance verified-remote))
      (values read-bound write-message)))

;; Goblins reads and writes CapTP through Racket ports, while the transport under
;; it is a byte channel: a blocking read that answers the next chunk or eof, and
;; a write that sends one. This is the whole of the adaptation, and each half is
;; shaped by what the layer above it does.
;;
;; Reading: `syrup-read` parses a record straight off the port, a few bytes at a
;; time, and blocks between records. A pipe is exactly that port, so one pump
;; thread moves each chunk the connection produces into the pipe and the vat's
;; reader sees an ordinary Racket input port with correct blocking, peeking and
;; end-of-file. The pipe's bound is what carries backpressure back to the partner.
;;
;; Writing: `syrup-write` also writes a few bytes at a time and then flushes, so
;; sending each of those to the connection would put a QUIC write behind every
;; length prefix. The output port accumulates instead and sends on the flush that
;; `captp-message-procs` performs at the end of every message, which makes one wire
;; write per CapTP message. Nothing else writes to this port, so the accumulator
;; is touched by the vat's one writer thread alone.
(define (channel-ports ch)
  (define-values (from-partner to-reader) (make-pipe inbound-buffer-bytes))
  (thread
   (lambda ()
     (let pump ()
       (define chunk
         (with-handlers ([(lambda (_) #t) (lambda (_) eof)]) ((byte-channel-read ch))))
       (cond
         [(eof-object? chunk) (close-output-port to-reader)]
         [else (write-bytes chunk to-reader) (pump)]))))

  (define pending (open-output-bytes))
  (define (send-pending!)
    (define chunk (get-output-bytes pending #t))
    (when (positive? (bytes-length chunk)) ((byte-channel-write ch) chunk)))
  (define to-partner
    (make-output-port
     'iroh
     always-evt
     ;; Racket asks for a flush by calling with an empty range; every other call
     ;; is bytes to accumulate, and reporting them all written is accurate because
     ;; the accumulator cannot refuse them.
     (lambda (bs start end non-block? breakable?)
       (cond
         [(= start end) (send-pending!) 0]
         [else (write-bytes bs pending start end) (- end start)]))
     (lambda () (send-pending!))))

  (values from-partner to-partner))

;; Constructor for an iroh netlayer.
;;
;;   reachability: how this endpoint becomes reachable, one of the binding's
;;                  IROH-REACH-* postures. Required, with no default: a peer
;;                  states how it is reachable and the binding never guesses.
;;                  `IROH-REACH-DIRECT` is the loopback and LAN posture, where a
;;                  dialer needs the direct-address hints this netlayer
;;                  advertises; a discovery posture resolves an endpoint id
;;                  without them.
;;
;; Optional `#:seed bytes`, the 32-byte Ed25519 secret behind the endpoint. It
;; is the vat's durable name, not a tuning knob: an `iroh` locator's designator
;; IS this key, so a vat that draws a fresh one is a different peer after every
;; restart and no sturdyref naming it survives. Omitting it draws a fresh random
;; key, as both scripts in this directory do, because a driver's vat lives
;; for one run.
;;
;; Optional `#:advertise-direct-addresses procedure` maps the bound address
;; list to the advertised routing advice. Called for each location
;; query, so fixtures can change advice while existing sessions retain their
;; signed snapshot. The default advertises the endpoint's bound addresses.
;;
;; Optional `#:session-trace sink`, a `(lambda (event handle info) ...)` called
;; with the CapTP session facts this netlayer observes at the wire. The shape and
;; the fields are `session-trace.rkt`'s.
(define (^iroh-netlayer _bcom
                        reachability
                        #:seed [seed #f]
                        #:advertise-direct-addresses [advertise-direct-addresses values]
                        #:session-trace [session-trace #f])
  ;; The endpoint binds here, on the caller's thread, so returning from the
  ;; constructor means it is reachable and its node id can be read and published.
  ;; Anything later leaves a window where a host has announced a locator naming
  ;; this vat while nothing answers at it.
  (define endpoint (open-iroh-endpoint (make-iroh-config reachability) seed))

  ;; What this netlayer calls itself. An `iroh` locator's designator is the
  ;; endpoint's Ed25519 public key, so unlike a socket address it names the peer
  ;; rather than a route to it: QUIC will not complete a handshake with anyone
  ;; else. The direct addresses ride as hints, which is route advice rather than
  ;; identity: a partner that reaches this endpoint by some other path still
  ;; reaches the same key.
  (define our-designator (iroh-endpoint-node-id endpoint))
  (define our-direct-addresses (iroh-endpoint-direct-addresses endpoint))
  (define (our-location)
    (define addresses (advertise-direct-addresses our-direct-addresses))
    (if (positive? (string-length addresses))
        (make-wire-ocapn-node 'iroh our-designator
                              (hash direct-addresses-hint addresses))
        (ocapn-node 'iroh our-designator #f)))

  ;; Channel that the accept thread pushes new connections onto, read by the
  ;; netlayer body through `sync/pr`, as in `tcp-netlayer.rkt`.
  (define new-conn-ch (make-async-channel))

  (define accept-thread #f)
  (define (start-accept-thread)
    (set! accept-thread
     (thread
     (lambda ()
       (let loop ()
         (async-channel-put new-conn-ch (iroh-endpoint-accept endpoint))
         (loop))))))

  ;; The message procs one connection runs on, traced when a sink was given.
  (define (connection-procs ch)
    (define-values (in out) (channel-ports ch))
    (define-values (read-message write-message) (captp-message-procs in out))
    (identity-bound-message-procs read-message write-message
                                  (byte-channel-verified-remote ch)
                                  (byte-channel-close! ch)
                                  our-designator session-trace))

  (define (start-listening conn-establisher)
    (let listen-loop ()
      (on (sync/pr new-conn-ch)
          (match-lambda
            [(list ch)
             (define-values (read-message write-message) (connection-procs ch))
             (<- conn-establisher read-message write-message #f)])
          #:finally listen-loop)))

  (define (^netlayer bcom)
    (define base-beh
      (methods
       [(netlayer-name) 'iroh]
       [(our-location) (our-location)]
       ;; Leave the wire politely: closing the endpoint sends every open
       ;; connection its close frame, so a partner learns this vat is gone
       ;; instead of waiting out an idle timeout. The accept thread stops
       ;; first so it never sees the closed endpoint.
       [(shutdown)
        (when accept-thread (kill-thread accept-thread))
        (iroh-endpoint-close! endpoint)]))

    ;; Pre-setup: waits for `setup` to start accepting and transition into the
    ;; ready behavior.
    (define pre-setup-beh
      (methods
       #:extends base-beh
       [(setup conn-establisher)
        (start-accept-thread)
        (start-listening conn-establisher)
        (bcom (ready-beh conn-establisher))]))

    (define (ready-beh conn-establisher)
      (methods
       #:extends base-beh
       [(self-location? loc)
        (same-node-location? (our-location) loc)]
       [(connect-to remote-node)
        ;; Dial by transport, designator and direct-address hint. The dial runs
        ;; on the vat's own thread, as `tcp-netlayer.rkt`'s `tcp-connect` does;
        ;; on loopback under the Direct posture it is a QUIC handshake to an
        ;; address already in hand.
        (match remote-node
          [(? (lambda (n) (and (ocapn-node? n)
                               (eq? (ocapn-node-transport n) 'iroh))))
           (define designator (ocapn-node-designator remote-node))
           (define ch
             (iroh-endpoint-dial endpoint designator (node-direct-addresses remote-node)))
           (define-values (read-message write-message) (connection-procs ch))
           (<- conn-establisher read-message write-message remote-node)])]))

    pre-setup-beh)

  (spawn ^netlayer))

(module+ test
  (require rackunit
           racket/async-channel
           (submod goblins/ocapn/structs-urls marshall))

  ;; A self-signed hello cannot borrow another iroh endpoint's identity. Test
  ;; the exact wrapper installed on both accepted and dialed channels, including
  ;; the no-telemetry path, which must enforce the same identity check.
  (struct op:start-session (version key location signature) #:transparent)
  (for* ([traced? '(#f #t)]
         [case (list (cons "attacker" (ocapn-node 'iroh "victim" #f))
                     (cons #f (ocapn-node 'iroh "victim" #f))
                     (cons "attacker" 'not-a-node))])
    (define claimed (cdr case))
    (define closed 0)
    (define events '())
    (define reads 0)
    (define-values (read-bound write-bound)
      (identity-bound-message-procs
       (lambda (_)
         (set! reads (add1 reads))
         (op:start-session "1.0" '(public-key attacker) claimed 'signature))
       (lambda (_msg _marshallers) (void))
       (car case) (lambda () (set! closed (add1 closed))) "ours"
       (and traced? (lambda (event _handle _info) (set! events (cons event events))))))
    (write-bound (op:start-session "1.0" '(public-key ours)
                                   (ocapn-node 'iroh "ours" #f) 'signature) '())
    (check-eq? (read-bound '()) eof "spoofed hello must not reach Goblins")
    (check-eq? (read-bound '()) eof "a refused channel stays closed")
    (check-equal? closed 1)
    (check-equal? reads 1)
    (check-equal? events '() "a rejected identity is never reported as an open session"))
  (let ()
    (define location (make-wire-ocapn-node 'iroh "victim" (hash "direct-addresses" "new")))
    (define hello (op:start-session "1.0" '(public-key victim) location 'signature))
    (define-values (read-bound _write-bound)
      (identity-bound-message-procs
       (lambda (_) hello) void "victim"
       (lambda () (error 'identity-test "closed an authenticated endpoint")) "ours" #f))
    (check-eq? (read-bound '()) hello "routing hints do not change endpoint identity"))

  ;; An admitted hello reaches Goblins and is traced with what the channel
  ;; proved about its claim. A relay dials with its own key, so a browser's
  ;; locator carried through it is admitted and unproven, while an iroh claim
  ;; naming the authenticated endpoint is the transport's own word.
  (for ([case (list (list "relay" (ocapn-node 'webrtc "browser" #f) provenance-unauthenticated)
                    (list "relay" (ocapn-node 'tcp "127.0.0.1:9000" #f) provenance-unauthenticated)
                    (list #f (ocapn-node 'tcp "127.0.0.1:9000" #f) provenance-unauthenticated)
                    (list "peer" (ocapn-node 'iroh "peer" #f) provenance-authenticated-transport))])
    (match-define (list verified claimed want) case)
    (define hello (op:start-session "1.0" '(public-key theirs) claimed 'signature))
    (define opens '())
    (define-values (read-bound write-bound)
      (identity-bound-message-procs
       (lambda (_) hello) (lambda (_msg _marshallers) (void)) verified
       (lambda () (error 'identity-test "closed an admitted hello")) "ours"
       (lambda (event _handle info)
         (when (eq? event 'open) (set! opens (cons info opens))))))
    (write-bound (op:start-session "1.0" '(public-key ours)
                                   (ocapn-node 'iroh "ours" #f) 'signature) '())
    (check-eq? (read-bound '()) hello "an admitted hello reaches Goblins unchanged")
    (check-equal? (map (lambda (info) (hash-ref info 'durable-provenance)) opens) (list want)
                  (format "~a over a channel proving ~a" claimed verified)))

  ;; The dial hint is read off whatever shape a node arrived in. A locator
  ;; decoded from the wire carries the draft's mapping, a discovery-posture
  ;; partner carries none, and a Syrup bytestring value is still an address list.
  (let ([wire (cdr unmarshall::ocapn-node)])
    (check-equal? (node-direct-addresses
                   (wire 'iroh "abc" (hash "direct-addresses" "127.0.0.1:1,127.0.0.1:2")))
                  "127.0.0.1:1,127.0.0.1:2")
    (check-equal? (node-direct-addresses
                   (wire 'iroh "abc" (hash "direct-addresses" #"127.0.0.1:3")))
                  "127.0.0.1:3")
    (check-equal? (node-direct-addresses (wire 'iroh "abc" #f)) "")
    (check-equal? (node-direct-addresses (wire 'iroh "abc" (hash "other" "x"))) ""))

  ;; The port adaptation, over a byte channel that records what it was asked to
  ;; send and answers with what it was told to deliver.
  ;;
  ;; This is the half of the netlayer with no CapTP in it and the half most
  ;; easily got wrong, so it is checked without an endpoint: the transport is a
  ;; struct, and what is under test is that Goblins's ports behave over it.
  (define (test-channel inbound)
    (define sent (make-async-channel))
    (define queue (box inbound))
    (values sent
            (byte-channel
             (lambda ()
               (define remaining (unbox queue))
               (cond
                 [(null? remaining) eof]
                 [else (set-box! queue (cdr remaining)) (car remaining)]))
             (lambda (data) (async-channel-put sent data))
             void
             #f)))

  ;; Reading: every chunk the connection produces reaches the port in order, and
  ;; the end of the connection is the end of the port.
  (let ()
    (define-values (_sent ch) (test-channel (list #"hel" #"lo")))
    (define-values (in _out) (channel-ports ch))
    (check-equal? (read-bytes 5 in) #"hello")
    (check-equal? (read-bytes 1 in) eof))

  ;; Writing: a message written a few bytes at a time and then flushed, which
  ;; is exactly what `syrup-write` followed by `captp-message-procs`' flush does,
  ;; reaches the connection as ONE write. Sending each small write on its own
  ;; would put a QUIC write behind every length prefix.
  (let ()
    (define-values (sent ch) (test-channel '()))
    (define-values (_in out) (channel-ports ch))
    (write-bytes #"<3:abc" out)
    (write-bytes #">" out)
    (check-false (sync/timeout 0 sent) "bytes reached the wire before the flush")
    (flush-output out)
    (check-equal? (sync/timeout 5 sent) #"<3:abc>")
    ;; A flush with nothing accumulated says nothing.
    (flush-output out)
    (check-false (sync/timeout 0 sent))
    ;; Closing the port sends whatever the last message left behind.
    (write-bytes #"tail" out)
    (close-output-port out)
    (check-equal? (sync/timeout 5 sent) #"tail")))
