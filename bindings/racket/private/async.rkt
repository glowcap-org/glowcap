#lang racket/base
;; Internal: the transport layer under the byte-fed CapTP session. It owns how
;; raw bytes move (the `async-transport` closures over Racket TCP ports, with
;; the iroh companion injecting its own) and the per-session inbox that
;; accumulates them. Framing is the core's: the pump in `private/pump.rkt`
;; hands the inbox to `pancake_host_session_feed_bytes`, whose codec delimits each
;; complete frame — both codecs, both frame shapes, the frame cap enforced
;; during the scan — and keeps only the unconsumed tail here. This module knows
;; nothing about the host.

(provide (all-defined-out))

;; ── The transport ─────────────────────────────────────────────────────────────
;; How bytes move for one session and how it tears down. The core supplies
;; the TCP port transport below; the `pancake-iroh` companion supplies the iroh
;; one, so the iroh artifact stays out of this core module entirely.
;;   write-frame! : (bytes? -> void)                 write one outbound frame
;;   flush!       : (-> void)                        flush buffered output
;;   fill-inbox!  : (evt? -> (or/c bytes? eof-object? 'woke))
;;       block for more inbound bytes, but also wait on the given wake event:
;;       return 'woke when it fired first, so a pump parked on the wire still
;;       notices progress another thread made on the shared host (a settle fired
;;       by a sibling session's feed).
;;   close!       : (-> void)                        release the transport
;;
;; Contract: `write-frame!` and `flush!` move bytes only. They must not call a
;; host verb or feed a session — a writer runs under the session's write
;; gate, so a transport that re-enters the host from its write half would
;; self-deadlock on the gate it already holds.
(struct async-transport (write-frame! flush! fill-inbox! close!))

;; The per-session pump state `session` builds on: the transport carrying
;; the bytes, the accumulated inbound `inbox`, the single-reader gate (`reader`
;; boxes the thread currently filling the inbox, so two green threads never
;; interleave reads of one stream), the `closed?` flag the reader raises on end
;; of stream, and the `released?` flag guarding the C handle after
;; `session-close!` (no host verb may touch a released conn). `conn` boxes
;; the owning `session` once it is built, so a flush can reach the
;; host from the pump handle alone.
(struct async-connection (transport [inbox #:mutable] reader closed? released? conn) #:transparent)

(define (make-async-connection transport)
  (async-connection transport #"" (box #f) (box #f) (box #f) (box #f)))

;; The TCP port transport: frames concatenate into the byte stream and flush
;; once; a fill reads whatever is ready, waiting on the port and the wake event
;; together (both yield to the scheduler); close shuts both ports.
;; Leave the ports on Racket's TCP default (`'block`): since 8.8.0.8 that mode
;; sets TCP_NODELAY. `'none` would re-enable Nagle; `flush!` is what pushes.
(define (port-transport in out)
  (define (read-avail)
    (define buf (make-bytes 65536))
    (define n (read-bytes-avail! buf in))
    (if (eof-object? n) eof (subbytes buf 0 n)))
  (async-transport
   (lambda (frame) (write-bytes frame out))
   (lambda () (flush-output out))
   (lambda (wake-evt)
     ;; Bytes always beat wake: `sync` among ready events is nondeterministic,
     ;; so a posted progress evt can starve an input port that already holds
     ;; the partner's reply (CLIENT_TIMEOUT, serve still alive). Recheck after
     ;; wake for the same reason — both can become ready together.
     (cond
       [(byte-ready? in) (read-avail)]
       [else
        (define ready (sync in wake-evt))
        (cond
          [(eq? ready in) (read-avail)]
          [(byte-ready? in) (read-avail)]
          [else 'woke])]))
   (lambda () (close-output-port out) (close-input-port in))))

;; Append freshly read bytes onto the inbox.
(define (async-fill! ac got)
  (set-async-connection-inbox! ac (bytes-append (async-connection-inbox ac) got)))

;; Drop the `n` leading bytes the host consumed, keeping the unconsumed tail —
;; the feed's other half.
(define (async-consume! ac n)
  (when (> n 0)
    (set-async-connection-inbox! ac (subbytes (async-connection-inbox ac) n))))
