#lang racket/base
;; A byte-transparent relay in Racket — the fourth-runtime reference for the
;; ADR-0086 relay contract, proving the contract is language-neutral and not a
;; TypeScript shape with a doc wrapper.
;;
;; It carries the raw bytes of a keyed CapTP session between a browser peer's
;; WebSocket and a native host, without parsing them, so the keyed handshake and
;; session authority run end to end and the relay holds no capability. This is the
;; same five-part shape ADR-0086 names, in Racket: the WebSocket adapter is
;; `rfc6455`, the pump is `relay-pump`, the byte channel is a TCP `byte-channel`
;; or the iroh binding's `dial-locator-for-relay`, the dial dispatcher is
;; `open-channel`, and the config is the two constants below. The embedding app
;; would add the target allow-list; this proof relays wherever the conformance
;; test points it.
;;
;; Two transports, dispatched by what the WebSocket names:
;;   - `?to=host:port`         a raw TCP socket (byte-level, kernel-backpressured);
;;                             no pancake binding loads on this path at all.
;;   - `?locator=<ocapn-uri>`  an iroh byte channel dialed through the Racket iroh
;;                             binding's `dial-locator-for-relay`, loaded lazily
;;                             only here, over the same C-ABI conn and readiness
;;                             primitives every binding drives.
;;
;;   racket bindings/racket/relay.rkt <listen-port>
;; Prints `RACKET-RELAY-READY <port>` on stdout once listening.

(require racket/async-channel
         racket/tcp
         net/rfc6455
         (only-in web-server/web-server serve)
         (only-in net/rfc6455/dispatcher make-general-websockets-dispatcher)
         net/url
         "private/iroh-companion.rkt"
         "private/byte-channel.rkt")

(provide relay-pump (struct-out exn:fail:relay))

(struct exn:fail:relay exn:fail (primary secondary) #:transparent)

;; The iroh binding loads on demand, only when a `?locator=` dial actually needs
;; it, so a TCP-only relay never loads iroh — matching the Deno, Python, and Rust
;; relays, which each defer their iroh import to the locator path. A relay serves
;; many connections at once, so it reaches the companion through
;; `iroh-companion.rkt`, which loads it exactly once however many arrive together.

;; The two bounded-resources knobs ADR-0086's contract names, matching the
;; @pancake/relay gold standard. The idle timeout reclaims a stalled pair; the
;; per-session byte total is a runaway backstop over the session's life, not a
;; memory bound (instantaneous memory is bounded by the backpressure on both
;; legs). Both sit far above any real chat session. The conformance idle-timeout
;; proof sets PANCAKE_RELAY_IDLE_MS low; a production run leaves it unset.
(define IDLE-TIMEOUT-MS
  (let ([v (getenv "PANCAKE_RELAY_IDLE_MS")])
    (or (and v (string->number v)) 60000)))
(define MAX-BYTES-PER-SESSION (expt 2 30)) ; 1 GiB
(define READ-CHUNK 65536)                   ; 64 KiB

;; A raw TCP byte channel as a `byte-channel`: `read` blocks and returns eof on
;; close, `write` flushes (which blocks under the socket's send-buffer
;; backpressure) — the same shape `dial-locator-for-relay` returns so the pump is
;; transport-agnostic.
(define (open-tcp-channel host port)
  (define-values (in out) (tcp-connect host port))
  (define read-buf (make-bytes READ-CHUNK))
  (byte-channel
   ;; `read-bytes-avail!` returns as soon as any bytes arrive (up to the buffer),
   ;; never blocking for a full buffer — a whole handshake reply forwards at once
   ;; rather than waiting for 64 KiB that a small session never sends.
   (lambda ()
     (define n (read-bytes-avail! read-buf in))
     (if (eof-object? n) eof (subbytes read-buf 0 n)))
   (lambda (data) (write-bytes data out) (flush-output out))
   (lambda ()
     (close-input-port in)
     (close-output-port out))
   ;; A TCP dial proves nothing about who answered: the designator is an
   ;; address, and an address is a route rather than a name.
   #f))

;; Dial classifier: a `host:port` opens a raw socket, an iroh `ocapn://` locator
;; opens the iroh relay channel. One of the two must be present.
(define (open-channel to locator)
  (cond
    [locator
     ;; The conformance host advertises loopback direct addresses, so the relay
     ;; reaches it directly; a deployment relay resolves node ids by discovery.
     ;; Load the iroh binding only now, so a TCP-only relay never touches it.
     (define dial (iroh-ref 'dial-locator-for-relay))
     (define reach (iroh-ref 'IROH-REACH-DIRECT))
     (dial locator reach)]
    [else
     ;; Split on the last colon so an IPv6 host keeps its own colons.
     (define i (let loop ([j (sub1 (string-length to))])
                 (cond [(< j 0) #f]
                       [(char=? (string-ref to j) #\:) j]
                       [else (loop (sub1 j))])))
     (open-tcp-channel (substring to 0 i) (string->number (substring to (add1 i))))]))

;; Read `?to=` / `?locator=` out of the WebSocket request path. `ws-conn-path`
;; returns the raw request-line path as bytes; `url-query` form-decodes the
;; values, so a percent-encoded `?locator=` comes back as a plain `ocapn://` URI.
(define (query-value path-bytes key)
  (define q (url-query (string->url (bytes->string/utf-8 path-bytes))))
  (define cell (assq key q))
  (and cell (cdr cell)))

;; Relay one accepted WebSocket to the channel its query names, both directions,
;; until either leg ends. Teardown is pair-atomic.
(define (relay-pump conn ch
                    #:ws-recv [recv ws-recv]
                    #:ws-send [send ws-send!]
                    #:ws-close [close-websocket ws-close!])
  ;; `up`/`down` are each written by exactly one pump thread, so the byte cap
  ;; needs no lock: a stale cross-thread read of the sibling counter only delays
  ;; the backstop by one chunk, and the cap sits a gigabyte above any real
  ;; session. `last-activity` is likewise touched by both legs, and either recent
  ;; timestamp re-arms the idle watchdog correctly.
  (define up 0)
  (define down 0)
  (define last-activity (current-inexact-monotonic-milliseconds))
  (define done (make-semaphore 0))
  (define failures (box '()))
  (define (record-failure! error)
    (set-box! failures (append (unbox failures) (list error)))
    (semaphore-post done))
  (define (run-leg! body)
    (with-handlers ([(lambda (error) (not (exn:break? error)))
                     record-failure!])
      (body)))
  (define (over-cap?) (> (+ up down) MAX-BYTES-PER-SESSION))
  (define (touch!) (set! last-activity (current-inexact-monotonic-milliseconds)))

  (define ws->channel
    (thread
     (lambda ()
       (run-leg!
        (lambda ()
          (let loop ()
            (define msg (recv conn #:payload-type 'auto))
            (cond
              [(eof-object? msg) (semaphore-post done)]
              [else
               (define bytes* (if (string? msg) (string->bytes/utf-8 msg) msg))
               (touch!)
               (set! up (+ up (bytes-length bytes*)))
               (if (over-cap?)
                   (semaphore-post done)
                   (begin ((byte-channel-write ch) bytes*) (loop)))])))))))

  (define channel->ws
    (thread
     (lambda ()
       (run-leg!
        (lambda ()
          (let loop ()
            (define chunk ((byte-channel-read ch)))
            (cond
              [(eof-object? chunk) (semaphore-post done)]
              [else
               (touch!)
               (set! down (+ down (bytes-length chunk)))
               (if (over-cap?)
                   (semaphore-post done)
                   (begin
                     (send conn chunk #:payload-type 'binary)
                     (loop)))])))))))

  ;; Reclaim a stalled pair: post `done` once neither leg has moved a chunk for
  ;; IDLE-TIMEOUT-MS. A `touch!` mid-sleep only shortens the next check, so the
  ;; timeout fires at worst one sleep-cycle late.
  (define watchdog
    (thread
     (lambda ()
       (let loop ()
         (define idle (- (current-inexact-monotonic-milliseconds) last-activity))
         (cond
           [(>= idle IDLE-TIMEOUT-MS) (semaphore-post done)]
           [else (sleep (/ (- IDLE-TIMEOUT-MS idle) 1000.0)) (loop)])))))

  (semaphore-wait done)
  (for ([worker (in-list (list ws->channel channel->ws watchdog))])
    (kill-thread worker))
  (for ([worker (in-list (list ws->channel channel->ws watchdog))])
    (thread-wait worker))
  (run-leg! (lambda () ((byte-channel-close! ch))))
  (run-leg! (lambda () (close-websocket conn)))
  (define ordered (unbox failures))
  (when (pair? ordered)
    (define primary (car ordered))
    (raise
     (exn:fail:relay
      (format "relay failed: ~a" (if (exn? primary) (exn-message primary) primary))
      (current-continuation-marks)
      primary
      (cdr ordered)))))

;; One accepted WebSocket: dial the channel its query names, then pump. A missing
;; or malformed target is a 1008 policy close; a dial that cannot land is a 1011
;; that tells the browser the relay leg failed, not the session.
(define (handle conn . _)
  (define path (ws-conn-path conn))
  (define to (query-value path 'to))
  (define locator (query-value path 'locator))
  (cond
    [(and (not locator) (or (not to) (not (regexp-match? #rx":" to))))
     (ws-close! conn #:status 1008 #:reason "relay requires ?to=host:port or ?locator=<uri>")]
    [else
     (define ch
       (with-handlers ([(lambda (_) #t)
                        (lambda (e)
                          (eprintf "relay: dial failed: ~a\n" (exn-message e))
                          (ws-close! conn #:status 1011 #:reason "relay dial failed")
                          #f)])
         (open-channel to locator)))
     (when ch (relay-pump conn ch))]))

(module+ main
  (define listen-port
    (let ([args (current-command-line-arguments)])
      (if (positive? (vector-length args)) (or (string->number (vector-ref args 0)) 0) 0)))
  ;; Drive web-server's `serve` directly with the rfc6455 dispatcher rather than
  ;; the `ws-serve` convenience wrapper: the wrapper conses `#:dispatch` onto the
  ;; caller's already-sorted keywords, which `#:confirmation-channel` sorts before,
  ;; tripping `keyword-apply`'s sorted-keywords contract. Calling `serve` with
  ;; literal keywords sidesteps that and still gives us the ephemeral port.
  (define conf (make-async-channel))
  (define _shutdown
    (serve #:dispatch (make-general-websockets-dispatcher handle)
           #:port listen-port
           #:listen-ip "127.0.0.1"
           #:confirmation-channel conf))
  (define result (async-channel-get conf))
  (when (exn? result) (raise result))
  (printf "RACKET-RELAY-READY ~a\n" result)
  (flush-output)
  (sync never-evt)) ; serve until killed
