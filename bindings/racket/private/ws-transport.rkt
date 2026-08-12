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
;; wake event. A reader thread bridges the two: it pulls one message and posts
;; it to a synchronous channel, so the adapter never queues an unbounded
;; backlog while the pump is stalled. The put is an event, not
;; `channel-put`: close wins the same wait, so a reader cannot remain blocked
;; forever trying to publish EOF after the pump has stopped consuming.
;;
;; This module loads lazily from the dial path, so a program that never dials
;; a keyed-relay locator never loads the WebSocket client.

(require net/rfc6455
         net/url
         "async.rkt")

(provide ws-transport)

;; A WebSocket message is a transport chunk and may coalesce several CapTP
;; frames. This bound is intentionally independent from DEFAULT-FRAME-CAP.
(define WS-MESSAGE-HIGH-WATER (arithmetic-shift 1 20))

;; Open a WebSocket to `url-string` and adapt it. A connect failure raises;
;; after the open, an error or close surfaces as end of stream, which the
;; session's teardown classifies.
(define (ws-transport url-string)
  (define c (ws-connect (string->url url-string)))
  (define ch (make-channel))
  (define closed? (box #f))
  (define close-signal (make-semaphore 0))
  (define close-token (gensym 'ws-closed))
  (define close-evt
    (wrap-evt (semaphore-peek-evt close-signal) (lambda (_) close-token)))

  ;; A WebSocket close handshake may wait for a peer that has already stopped
  ;; cooperating. Run that transport cleanup independently of the pump caller.
  (define (request-close!)
    (thread
     (lambda ()
       (with-handlers ([(lambda (_e) #t) void])
         (ws-close! c)))))

  (define (stop!)
    (unless (unbox closed?)
      (set-box! closed? #t)
      (semaphore-post close-signal)
      (request-close!)))

  (define (post! value)
    ;; One synchronous handoff keeps the adapter bounded. The close event
    ;; makes a blocked producer abandon the handoff during teardown.
    (define put-token (gensym 'ws-put))
    (define put-evt
      (wrap-evt (channel-put-evt ch value) (lambda (_) put-token)))
    (eq? (sync put-evt close-evt) put-token))

  (define (send-bytes! frame)
    (cond
      [(zero? (bytes-length frame))
       (ws-send! c frame #:payload-type 'binary)]
      [else
       ;; WebSocket message boundaries carry no CapTP meaning. Keep each send
       ;; within the receive-side transport bound so a large frame remains
       ;; byte-transparent through every binding and relay.
       (for ([start (in-range 0 (bytes-length frame) WS-MESSAGE-HIGH-WATER)])
         (ws-send! c
                   (subbytes frame start
                             (min (bytes-length frame)
                                  (+ start WS-MESSAGE-HIGH-WATER)))
                   #:payload-type 'binary))]))

  ;; The reader owns every `ws-recv`: it posts each binary message (or eof,
  ;; once, at close/error) and ends. Posting eof rather than dying silently is
  ;; what turns a dropped socket into the pump's clean end-of-stream.
  (thread
   (lambda ()
     (let loop ()
       (define msg
         (with-handlers ([(lambda (_e) #t) (lambda (_e) eof)])
           (ws-recv c #:payload-type 'binary)))
       (cond
         [(eof-object? msg) (post! eof)]
         [(not (bytes? msg))
          ;; The protocol is byte-transparent: text is not another spelling
          ;; of protocol bytes. Refuse it and end the stream instead of letting
          ;; `bytes-length` kill this reader silently.
          (stop!)]
         [(> (bytes-length msg) WS-MESSAGE-HIGH-WATER)
          (stop!)]
         [else
          (when (post! msg) (loop))]))))

  (async-transport
   ;; write-frame!: bounded binary transport chunks; rfc6455 flushes per send.
   send-bytes!
   void
   ;; read-some!: bytes beat wake (see the module header). Syncing the channel
   ;; consumes the item it yields.
   (lambda (wake-evt)
     (define (deliver v) (if (eof-object? v) eof v))
     (define ready (sync ch wake-evt close-evt))
     (cond
       [(eq? ready close-token) eof]
       [(eq? ready wake-evt)
        (define again (channel-try-get ch))
        (cond
          [again (deliver again)]
          [(unbox closed?) eof]
          [else 'woke])]
       [else (deliver ready)]))
   ;; close!: idempotent; the reader unblocks on the closed socket and posts
   ;; eof, so nothing waits on a dead connection or a blocked channel handoff.
   (lambda ()
     (stop!))))
