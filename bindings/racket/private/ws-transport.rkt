#lang racket/base
;; The WebSocket byte transport for the keyed-relay rendezvous dial (ADR-0088).
;;
;; A keyed-relay peer holds an inbound socket at a relay under its key
;; designator; the dialer opens the relay's rendezvous leg and the keyed OCapN
;; handshake runs end to end over it. This module adapts one client WebSocket
;; (net/rfc6455) to the `async-transport` record the pump drives: each binary
;; message is one inbound chunk, and the host's stream delimiter owns framing,
;; exactly as over TCP.
;;
;; `ws-recv` blocks its thread, but `read-some!` must also wait on the pump's
;; wake event. A reader thread bridges the two: it pulls messages into an
;; async-channel (itself a sync-able event), and `read-some!` syncs on the
;; channel and the wake event together — bytes beat wake, the same rule the
;; TCP port transport holds, with a recheck after a wake win because both can
;; become ready together.
;;
;; This module loads lazily from the dial path, so a program that never dials
;; a keyed-relay locator never loads the WebSocket client.

(require net/rfc6455
         net/url
         racket/async-channel
         "async.rkt")

(provide ws-transport)

;; Open a WebSocket to `url-string` and adapt it. A connect failure raises;
;; after the open, an error or close surfaces as end of stream, which the
;; session's teardown classifies.
(define (ws-transport url-string)
  (define c (ws-connect (string->url url-string)))
  (define ch (make-async-channel))
  ;; The reader owns every `ws-recv`: it posts each binary message (or eof,
  ;; once, at close/error) and ends. Posting eof rather than dying silently is
  ;; what turns a dropped socket into the pump's clean end-of-stream.
  (thread
   (lambda ()
     (let loop ()
       (define msg
         (with-handlers ([(lambda (_e) #t) (lambda (_e) eof)])
           (ws-recv c #:payload-type 'binary)))
       (async-channel-put ch (if (eof-object? msg) eof msg))
       (unless (eof-object? msg) (loop)))))
  (define closed? (box #f))
  (async-transport
   ;; write-frame!: one binary message per frame; rfc6455 flushes per send.
   (lambda (frame) (ws-send! c frame #:payload-type 'binary))
   void
   ;; read-some!: bytes beat wake (see the module header). Syncing the channel
   ;; consumes the item it yields.
   (lambda (wake-evt)
     (define (deliver v) (if (eof-object? v) eof v))
     (define ready (sync ch wake-evt))
     (cond
       [(eq? ready wake-evt)
        (define again (async-channel-try-get ch))
        (if again (deliver again) 'woke)]
       [else (deliver ready)]))
   ;; close!: idempotent; the reader unblocks on the closed socket and posts
   ;; eof, so nothing waits on a dead connection.
   (lambda ()
     (unless (unbox closed?)
       (set-box! closed? #t)
       (with-handlers ([(lambda (_e) #t) void])
         (ws-close! c))))))
