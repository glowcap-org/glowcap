#lang racket/base
;; iroh-netlayer.rkt — an iroh netlayer for Spritely Goblins's CapTP, over
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
;; Provide `^iroh-netlayer` — spawn it with a reachability posture, pass the
;; resulting netlayer to `spawn-mycapn`, and the vat speaks CapTP over iroh.
;;
;; What this is for: glowcap ↔ Goblins interop over an encrypted transport. It is
;; the sibling of `tcp-netlayer.rkt`, and the two differ only in what moves the
;; bytes and in what a session over them can honestly claim to have proved.
;;
;; What this is NOT:
;; - Full Spritely netlayer: no graceful shutdown, no reconnect-on-loss, minimal
;;   error reporting. A connection's handle is released when the endpoint is,
;;   which for a driver process is at exit. Good enough for an interop bracket.
;; - A second CapTP. Nothing here parses a CapTP record for the wire's sake; the
;;   session trace below reads `op:start-session` only to name the session, and
;;   the bytes pass through untouched.

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
                  iroh-endpoint-accept iroh-endpoint-dial
                  byte-channel byte-channel-read byte-channel-write
                  byte-channel-verified-remote)
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
;; sidecar's own bounded buffer fills, and QUIC flow control slows the partner —
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

;; What a connection proved about the partner's durable name, asked with the
;; designator the partner's hello claims.
;;
;; `verified-remote` is the endpoint id QUIC authenticated for the far end of
;; this channel, or #f when nothing proved one. QUIC verifies the remote in both
;; directions, so an accepted connection answers this as well as a dialed one:
;; the vat reads the proof off the connection rather than trusting that a dial
;; reached the endpoint it named.
;;
;; A proved id equal to the claim is what makes the claim the transport's own
;; word. Anything else is unproven: a claim naming some other endpoint is a
;; claim about somebody else, and a channel that proved nothing leaves nothing
;; to weigh the claim against. Both stay `unauthenticated`, because reporting
;; either as proved would report a check nobody ran.
(define ((transport-proof-provenance verified-remote) claimed)
  (if (and verified-remote (equal? claimed verified-remote))
      provenance-authenticated-transport
      provenance-unauthenticated))

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
     ;; is bytes to accumulate, and reporting them all written is honest because
     ;; the accumulator cannot refuse them.
     (lambda (bs start end non-block? breakable?)
       (cond
         [(= start end) (send-pending!) 0]
         [else (write-bytes bs pending start end) (- end start)]))
     (lambda () (send-pending!))))

  (values from-partner to-partner))

;; Constructor for an iroh netlayer.
;;
;;   reachability — how this endpoint becomes reachable, one of the binding's
;;                  IROH-REACH-* postures. Required, with no default: a peer
;;                  states how it is reachable and the binding never guesses.
;;                  `IROH-REACH-DIRECT` is the loopback and LAN posture, where a
;;                  dialer needs the direct-address hints this netlayer
;;                  advertises; a discovery posture resolves an endpoint id
;;                  without them.
;;
;; Optional `#:seed bytes` — the 32-byte Ed25519 secret behind the endpoint. It
;; is the vat's durable name, not a tuning knob: an `iroh` locator's designator
;; IS this key, so a vat that draws a fresh one is a different peer after every
;; restart and no sturdyref naming it survives. Omitting it draws a fresh random
;; key, as both scripts in this directory do, because a driver's vat lives
;; for one run.
;;
;; Optional `#:advertise-direct-addresses procedure` maps the bound address
;; list to the currently advertised routing advice. Called for each location
;; query, so fixtures can change advice while existing sessions retain their
;; signed snapshot. The default advertises the endpoint's bound addresses.
;;
;; Optional `#:session-trace sink` — a `(lambda (event handle info) ...)` called
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

  (define (start-accept-thread)
    (thread
     (lambda ()
       (let loop ()
         (async-channel-put new-conn-ch (iroh-endpoint-accept endpoint))
         (loop)))))

  ;; The message procs one connection runs on, traced when a sink was given.
  (define (connection-procs ch)
    (define-values (in out) (channel-ports ch))
    (define-values (read-message write-message) (captp-message-procs in out))
    (if session-trace
        (traced-message-procs read-message write-message session-trace
                              #:transport "iroh"
                              #:our-designator our-designator
                              #:provenance (transport-proof-provenance
                                            (byte-channel-verified-remote ch)))
        (values read-message write-message)))

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
       [(our-location) (our-location)]))

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

  ;; What a channel's proof is allowed to conclude about the partner's claim.
  ;; This is the netlayer's whole authentication verdict, so each way it can go
  ;; is checked: only an exact match between the id QUIC verified and the id the
  ;; hello claims is the transport's own word for the partner.
  (let ([proved "aa11"]
        [other "bb22"])
    (check-equal? ((transport-proof-provenance proved) proved)
                  provenance-authenticated-transport
                  "a claim naming the endpoint QUIC verified is proved")
    ;; A partner that opened the connection under one key and claims another in
    ;; its hello is claiming something nothing here checked.
    (check-equal? ((transport-proof-provenance proved) other)
                  provenance-unauthenticated
                  "a claim naming some other endpoint is not proved")
    ;; A channel that proved nothing cannot lend its silence to a claim.
    (check-equal? ((transport-proof-provenance #f) other)
                  provenance-unauthenticated
                  "an unproved channel proves no claim")
    (check-equal? ((transport-proof-provenance #f) #f)
                  provenance-unauthenticated
                  "two absent names are not a match"))

  ;; Reading: every chunk the connection produces reaches the port in order, and
  ;; the end of the connection is the end of the port.
  (let ()
    (define-values (_sent ch) (test-channel (list #"hel" #"lo")))
    (define-values (in _out) (channel-ports ch))
    (check-equal? (read-bytes 5 in) #"hello")
    (check-equal? (read-bytes 1 in) eof))

  ;; Writing: a message written a few bytes at a time and then flushed — which
  ;; is exactly what `syrup-write` followed by `captp-message-procs`' flush does —
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
