#lang racket/base
;; Internal: the transport layer under the byte-fed CapTP session. It owns how
;; raw bytes move (the `async-transport` closures over Racket TCP ports, with
;; the iroh companion injecting its own). Framing and the unconsumed tail are
;; the core's: the pump in `private/pump.rkt` hands each read to
;; `glowcap_host_session_feed_bytes`, whose codec delimits each complete frame
;; (both codecs, both frame shapes, the frame cap enforced during the scan)
;; and buffers a partial frame in the session itself. This module knows
;; nothing about the host.

(require "constants.rkt")

(provide (all-defined-out))

;; ── The transport ─────────────────────────────────────────────────────────────
;; How bytes move for one session and how it tears down. The core supplies
;; the TCP port transport below; the `glowcap-iroh` companion supplies the iroh
;; one, so the iroh artifact stays out of this core module entirely.
;;   write-frame! : (bytes? -> void)                 write one outbound frame
;;   flush!       : (-> void)                        flush buffered output
;;   read-some!   : (evt? -> (or/c bytes? eof-object? 'woke))
;;       block for more inbound bytes, but also wait on the given wake event:
;;       return 'woke when it fired first, so a pump parked on the wire still
;;       notices progress another thread made on the shared host (a settle fired
;;       by a sibling session's feed).
;;   close!       : (-> void)                        release the transport
;;
;; Contract: `write-frame!` and `flush!` move bytes only. They must not call a
;; host verb or feed a session. A writer runs under the session's write
;; gate, so a transport that re-enters the host from its write half would
;; self-deadlock on the gate it already holds.
(struct async-transport (write-frame! flush! read-some! close!))

;; The per-session pump state `session` builds on: the transport carrying
;; the bytes, the single-reader gate (`reader` boxes the thread currently
;; reading the stream, so two green threads never interleave reads), the
;; once-per-session `tail-resumed?` flag (the pump's first open-session read
;; step dispatches the frames the core held behind the handshake hello), the
;; `closed?` flag the reader raises on end of stream, and the `released?`
;; flag guarding the C handle after `session-close!` (no host verb may touch
;; a released session). `session` boxes the owning `session` once it is built, so a
;; flush can reach the host from the pump handle alone.
;; `serve-hook` is a box holding a thunk `session-serve` runs once before its
;; first pump: how a loop-backed session announces post-open setup is done so
;; the native loop starts delivering its inbound. Byte-fed connections keep
;; the default no-op; their serve loop resumes retained input directly.
(struct async-connection (transport tail-resumed? reader closed? released? session serve-hook) #:transparent)

(define (make-async-connection transport)
  (async-connection transport (box #f) (box #f) (box #f) (box #f) (box #f) (box void)))

;; The TCP port transport: frames concatenate into the byte stream and flush
;; once; a fill reads whatever is ready, waiting on the port and the wake event
;; together (both yield to the scheduler); close shuts both ports.
;; Leave the ports on Racket's TCP default (`'block`): since 8.8.0.8 that mode
;; sets TCP_NODELAY. `'none` would re-enable Nagle; `flush!` is what pushes.
(define (port-transport in out)
  (define (read-avail)
    (define buf (make-bytes BINDING-STREAM-READ-CHUNK-BYTES))
    (define n (read-bytes-avail! buf in))
    (if (eof-object? n) eof (subbytes buf 0 n)))
  (async-transport
   (lambda (frame) (write-bytes frame out))
   (lambda () (flush-output out))
   (lambda (wake-evt)
     ;; Bytes always beat wake: `sync` among ready events is nondeterministic,
     ;; so a posted progress evt can starve an input port that already holds
     ;; the partner's reply (CLIENT_TIMEOUT, serve still alive). Recheck after
     ;; wake for the same reason: both can become ready together.
     (cond
       [(byte-ready? in) (read-avail)]
       [else
        (define ready (sync in wake-evt))
        (cond
          [(eq? ready in) (read-avail)]
          [(byte-ready? in) (read-avail)]
          [else 'woke])]))
   (lambda () (close-output-port out) (close-input-port in))))
