#lang racket/base
;; trace-publish.rkt — publish this vat's own protocol activity to a live
;; timeline endpoint.
;;
;; A timeline endpoint takes records from several peers at once. Viewers connect
;; to `/` and receive records; producers connect to `/publish` and send them, one
;; JSON record per frame, and are sent none back. This vat is a producer, so the
;; sessions it holds appear beside every other peer's. Where two peers both
;; report one session, the endpoint forwards both views and a viewer folds them
;; into one edge, because each end names the session by the same OCapN Session
;; ID.
;;
;; A record is a claim a producer makes about itself. The endpoint owns every
;; name a merged feed keys on: it scopes each session id by the connection the
;; record arrived on, and it stamps the sequence number, the epoch, and the
;; arrival time. So a producer's claims cannot collide with another's, and
;; nothing here has to be trusted for the feed to stay coherent.
;;
;; Telemetry never gets to slow the vat down. A record made while there is no
;; socket waits in a bounded queue and the oldest are dropped past its ceiling;
;; a send that fails drops the socket; a socket that is down is redialed on a
;; backoff. Every session still open is announced again on each fresh
;; connection, because the endpoint scopes ids per connection and a reconnect is
;; a new scope.
;;
;; Being sent no records is not the same as never reading the socket, and the
;; difference is load-bearing. `net/rfc6455` answers a ping and notices a peer's
;; close only inside a receive, so a socket that is only written to can be shut
;; by the far end without this end ever learning: an endpoint that drops a
;; producer for missing its pings takes with it every session that producer
;; reported, and a viewer connecting afterwards is shown a room this vat has
;; vanished from. The worker therefore syncs on the connection itself, not on
;; `ws-conn-closed?`, which a socket nobody reads can never flip.
;;
;; Nothing is published unless an endpoint is configured. `ROOMS_VIZ_URL` names
;; one; with the variable unset the vat holds no socket and emits no record.

(require json
         net/rfc6455
         net/url
         racket/async-channel
         racket/list
         racket/string)

(provide publish-url
         trace-endpoint-from-env
         trace-endpoint-variable
         make-trace-publisher
         trace-publisher-sink
         stop-trace-publisher)

;; The path a producer connects to. Viewers use `/`; naming the split once is
;; what keeps a producer and the endpoint from drifting apart.
(define publish-path "publish")

;; The environment variable that names the endpoint.
(define trace-endpoint-variable "ROOMS_VIZ_URL")

;; What this producer answers when a record asks what it runs. A constant and
;; not an argument: the vat behind this publisher is a Goblins vat, and letting
;; a caller name itself something else would put a claim on the wire that
;; nothing here could stand behind. The schema is not one implementation's mark
;; — pancake's own hosts publish the same records, saying `pancake` — so a
;; consumer cannot read an implementation off the fact that a record arrived,
;; and this is how the vat's own end is named on screen. This word must never
;; be folded into the one pancake's bindings state: it is a different producer
;; reporting a different fact, and a shared constant would erase exactly the
;; distinction the field exists to carry. `zig build source-check`
;; (`checkTraceViewerVocabulary`) pins both words so neither can drift into the
;; other.
(define self-profile "goblins")

;; Records held while there is no socket to send them on. One session's opening
;; burst is a single record; this is far above that and still a fixed ceiling.
(define max-pending 4096)

;; How long to wait before redialing an endpoint that is down, so an endpoint
;; that is missing, or that hangs up as fast as it accepts, is polled rather
;; than hot-looped.
(define retry-seconds 1.0)

;; A running publisher: the sink to hand a netlayer, and the stop that ends it.
(struct trace-publisher (sink stop))

(define (stop-trace-publisher pub)
  ((trace-publisher-stop pub)))

;; Turn a viewer URL into the producer URL for the same endpoint. Either
;; spelling is accepted, so a caller can pass whatever URL it was configured
;; with.
(define (publish-url url-string)
  (define parsed (string->url url-string))
  (define segments (url-path parsed))
  (define last-segment
    (if (null? segments) "" (path/param-path (last segments))))
  (if (equal? last-segment publish-path)
      (url->string parsed)
      (url->string
       (struct-copy url parsed
                    [path-absolute? #t]
                    [path (list (path/param publish-path '()))]))))

;; The endpoint this vat publishes to, or #f when none is configured.
(define (trace-endpoint-from-env)
  (define raw (getenv trace-endpoint-variable))
  (and raw
       (let ([trimmed (string-trim raw)])
         (and (positive? (string-length trimmed)) trimmed))))

;; Start publishing to the endpoint at `url`.
;;
;; `self-label` is what this vat would like its own endpoint CALLED on screen, a
;; display name beside the identity rather than instead of it: the record's `a`
;; stays the designator a partner names this vat by, which is the only name two
;; producers can agree on. `on-error` hears a socket that could not be opened or
;; written, so a caller may log it; the publisher itself carries on either way.
(define (make-trace-publisher url
                              #:self-label [self-label #f]
                              #:on-error [on-error void])
  (define target (publish-url url))
  (define channel (make-async-channel))
  (define worker
    (thread (lambda () (publisher-loop target channel self-label on-error))))
  (trace-publisher
   ;; The sink a netlayer calls, from whichever thread observed the fact. It
   ;; only ever puts on the channel, so the worker owns every piece of state
   ;; below and no lock is involved.
   (lambda (event handle info)
     (async-channel-put channel (list event handle info)))
   (lambda ()
     (async-channel-put channel 'stop)
     (sync/timeout 2.0 worker)
     (void))))

;; One `ocapn.session-opened` in the timeline schema.
;;
;; `a` is the designator this vat calls itself by and `b` the one it calls its
;; partner by; the endpoint carries both across unchanged. `session_id` is the
;; OCapN Session ID, which both ends of one session derive alike, so a viewer
;; watching this session from both ends draws one edge rather than two.
;;
;; `provenance` says what proved the partner's durable name. A `tcp` locator
;; designates a socket address rather than a key, so nothing on this path proves
;; a durable name and the verdict is `unauthenticated`.
;;
;; `a_profile` is the implementation this vat runs, a statement about the
;; producer's own end on the same footing as the `provenance` verdict beside it.
;;
;; The fields are the schema's and only the schema's. A producer that invents
;; one is claiming a vocabulary the consumer never agreed to: nothing reads it,
;; and the endpoint's own bound on what a producer may say is written per field,
;; so an unknown name would be carried into the state a viewer replays with no
;; bound at all.
(define (open-record id info self-label t)
  (define base
    (hasheq 'v 1
            'sim_t_ns t
            'kind "ocapn.session-opened"
            'session id
            'a (hash-ref info 'our-designator)
            'b (hash-ref info 'partner-designator)
            'transport (hash-ref info 'transport)
            'session_id (hash-ref info 'session-id)
            'codec (hash-ref info 'codec)
            'captp_version (hash-ref info 'captp-version)
            'provenance (hash-ref info 'durable-provenance)
            'a_profile self-profile))
  (if self-label (hash-set base 'a_label self-label) base))

(define (close-record id t)
  (hasheq 'v 1
          'sim_t_ns t
          'kind "ocapn.session-closed"
          'session id))

;; The worker. Everything the publisher remembers lives on this one thread, and
;; the only way in is the channel, so the netlayer threads that report facts
;; never touch it.
(define (publisher-loop target channel self-label on-error)
  (define started (current-inexact-monotonic-milliseconds))
  ;; The sessions this vat is holding, by the netlayer's handle for each: the id
  ;; it was announced under, and the record announcing it. This is the state a
  ;; fresh connection replays, and it is the same state the endpoint keeps for a
  ;; reconnecting viewer.
  (define open-sessions (make-hasheq))
  ;; The same handles, newest first, so a replay announces them in the order
  ;; they opened.
  (define open-order '())
  ;; Records waiting for a socket, newest first. Dropping the oldest past the
  ;; ceiling is safe because the live state above is announced again in full on
  ;; every connection.
  (define pending '())
  (define pending-count 0)
  (define connection #f)
  (define sessions-named 0)
  ;; The moment a redial is allowed. A socket that dies is held off for the
  ;; same backoff as one that never opened, so an endpoint that accepts and
  ;; hangs up at once is polled rather than dialed as fast as the loop turns.
  (define redial-after 0)

  (define (elapsed-ns)
    (inexact->exact
     (round (* 1e6 (- (current-inexact-monotonic-milliseconds) started)))))

  (define (drop-connection!)
    (when connection
      (with-handlers ([exn:fail? void]) (ws-close! connection))
      (set! connection #f))
    (set! redial-after
          (+ (current-inexact-monotonic-milliseconds) (* 1000.0 retry-seconds))))

  (define (send-record! record)
    (and connection
         (with-handlers ([exn:fail? (lambda (e)
                                      (on-error e)
                                      (drop-connection!)
                                      #f)])
           (ws-send! connection (jsexpr->string record))
           #t)))

  (define (flush!)
    (let loop ([oldest-first (reverse pending)])
      (cond
        [(null? oldest-first)
         (set! pending '())
         (set! pending-count 0)]
        [(send-record! (car oldest-first)) (loop (cdr oldest-first))]
        [else
         (set! pending (reverse oldest-first))
         (set! pending-count (length oldest-first))])))

  (define (emit! record)
    (set! pending (cons record pending))
    (set! pending-count (add1 pending-count))
    (when (> pending-count max-pending)
      (set! pending (take pending max-pending))
      (set! pending-count max-pending))
    (flush!))

  (define (connect!)
    (with-handlers ([exn:fail? (lambda (e) (on-error e) (set! connection #f))])
      (set! connection (ws-connect (string->url target)))
      (for ([handle (in-list (reverse open-order))])
        (define row (hash-ref open-sessions handle #f))
        (when row (send-record! (cdr row))))
      (flush!)))

  (define (opened! handle info)
    (set! sessions-named (add1 sessions-named))
    (define id (format "gv-s~a" sessions-named))
    (define record (open-record id info self-label (elapsed-ns)))
    (hash-set! open-sessions handle (cons id record))
    (set! open-order (cons handle open-order))
    (emit! record))

  (define (closed! handle)
    (define row (hash-ref open-sessions handle #f))
    (when row
      (hash-remove! open-sessions handle)
      (set! open-order (remq handle open-order))
      (emit! (close-record (car row) (elapsed-ns)))))

  (let loop ()
    (when (and (not connection)
               (>= (current-inexact-monotonic-milliseconds) redial-after))
      (connect!))
    ;; A connection is its own event (`prop:evt` on `net/rfc6455`'s connection
    ;; struct, which receives), so the socket's own end arrives on the same
    ;; sync the vat's facts do. That is the only thing that hears a peer hang
    ;; up, and it is what answers the endpoint's pings: both live inside the
    ;; library's receive. While disconnected there is nothing to hear, so the
    ;; wait is the redial backoff instead.
    (define message
      (sync/timeout
       (if connection #f retry-seconds)
       channel
       (if connection
           (handle-evt connection
                       (lambda (payload) (if (eof-object? payload) 'lost 'heard)))
           never-evt)))
    (cond
      [(eq? message 'stop) (drop-connection!)]
      [(eq? message 'lost) (drop-connection!) (loop)]
      ;; Reading is the point; what was read is not. Nothing an endpoint could
      ;; send a producer is part of this protocol, so a frame that arrives is
      ;; dropped and the socket goes on being heard.
      [(eq? message 'heard) (loop)]
      [(not message) (loop)]
      [else
       (case (car message)
         [(open) (opened! (cadr message) (caddr message))]
         [(close) (closed! (cadr message))]
         [else (void)])
       (loop)])))

(module+ test
  (require rackunit
           racket/tcp)

  ;; Start `handler` as a WebSocket endpoint and answer with its stop and the
  ;; port it bound.
  ;;
  ;; `ws-serve` cannot be asked which port it took: it prepends `#:dispatch` to
  ;; the caller's keywords and `keyword-apply` demands them sorted, so any
  ;; keyword sorting ahead of that one — `#:confirmation-channel`, the one that
  ;; would answer — is a contract violation. So the port is chosen the other way
  ;; round: the OS names a free one, it is given back, and the endpoint claims
  ;; it, trying again if something else took it in between.
  (define (serve-on-a-free-port handler)
    (let attempt ([tries 20])
      (define candidate
        (let ([listener (tcp-listen 0 4 #t "127.0.0.1")])
          (define-values (_host port _peer-host _peer-port) (tcp-addresses listener #t))
          (tcp-close listener)
          port))
      (define stop
        (with-handlers ([exn:fail? (lambda (e) (when (zero? tries) (raise e)) #f)])
          (ws-serve handler #:port candidate)))
      (if stop (values stop candidate) (attempt (sub1 tries)))))

  ;; Either spelling of the endpoint reaches the producer path.
  (check-equal? (publish-url "ws://127.0.0.1:9300/") "ws://127.0.0.1:9300/publish")
  (check-equal? (publish-url "ws://127.0.0.1:9300") "ws://127.0.0.1:9300/publish")
  (check-equal? (publish-url "ws://127.0.0.1:9300/publish") "ws://127.0.0.1:9300/publish")

  ;; The two records a session's life produces, in the schema an endpoint
  ;; accepts. Both name the same session; only the open carries identity.
  (define info
    (hasheq 'transport "tcp"
            'our-designator "127.0.0.1:40001"
            'partner-designator "127.0.0.1:9099"
            'session-id (make-string 64 #\a)
            'captp-version "1.0"
            'codec "syrup"
            'durable-provenance "unauthenticated"))
  (define opened (open-record "gv-s1" info "goblins-carol" 0))
  (check-equal? (hash-ref opened 'kind) "ocapn.session-opened")
  (check-equal? (hash-ref opened 'a) "127.0.0.1:40001")
  (check-equal? (hash-ref opened 'b) "127.0.0.1:9099")
  (check-equal? (hash-ref opened 'provenance) "unauthenticated")
  (check-equal? (hash-ref opened 'a_label) "goblins-carol")
  (check-equal? (hash-ref opened 'a_profile) "goblins")
  (check-equal? (hash-ref (close-record "gv-s1" 0) 'session) "gv-s1")
  ;; Every record has to survive the trip as JSON.
  (check-true (string? (jsexpr->string opened)))

  ;; A record says only what the schema has words for. An invented field is
  ;; carried by the endpoint into the state it replays to viewers, unbounded,
  ;; and read by nobody.
  ;;
  ;; The schema is `TraceEvent` in `bindings/ts/runtime/trace.ts`, which is where
  ;; to go when this fires: either the field belongs there and this list has
  ;; not caught up, or it does not and the record should not be saying it.
  (check-equal? (sort (map symbol->string (hash-keys opened)) string<?)
                '("a" "a_label" "a_profile" "b" "captp_version" "codec" "kind"
                      "provenance" "session" "session_id" "sim_t_ns"
                      "transport" "v"))

  ;; A publisher whose socket the far end shuts must notice and come back with
  ;; the sessions it still holds.
  ;;
  ;; This is the whole of the defect a live endpoint showed: `net/rfc6455`
  ;; notices a peer's close only inside a receive, so a producer that only sends
  ;; leaves `ws-conn-closed?` false forever. The endpoint had already dropped the
  ;; producer and retired every session it reported, while this end went on
  ;; believing it was publishing, and no viewer connecting afterwards was ever
  ;; shown the vat again. The endpoint below hangs up on its first producer the
  ;; way a live one does; a publisher that hears it redials and announces its
  ;; open session a second time, and one that does not never returns.
  (let ()
    (define arrivals (make-async-channel))
    (define hung-up? (box #f))
    (define (endpoint conn _state)
      (define first? (not (unbox hung-up?)))
      (let loop ()
        (define line (ws-recv conn #:payload-type 'text))
        (unless (eof-object? line)
          (async-channel-put arrivals line)
          (cond
            [first? (set-box! hung-up? #t) (ws-close! conn)]
            [else (loop)]))))
    (define-values (stop-endpoint port) (serve-on-a-free-port endpoint))
    (define pub (make-trace-publisher (format "ws://127.0.0.1:~a/" port)))
    ((trace-publisher-sink pub) 'open 'handle-1 info)

    (define (next-open what)
      (define line (sync/timeout 20.0 arrivals))
      (check-true (string? line) what)
      (when (string? line)
        (check-equal? (hash-ref (string->jsexpr line) 'kind) "ocapn.session-opened" what)))

    (next-open "the endpoint never heard the session open at all")
    (next-open "the publisher never noticed its socket was shut, so the session it holds reaches no viewer again")

    (stop-trace-publisher pub)
    (stop-endpoint)))
