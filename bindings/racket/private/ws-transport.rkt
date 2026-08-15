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

;; Open a WebSocket and adapt it. Procedures are injectable only at this private
;; seam so dogfood can force asynchronous failures without a timing-dependent
;; network peer.
(define (ws-transport url-string
                      #:connect [connect ws-connect]
                      #:recv [recv ws-recv]
                      #:send [send ws-send!]
                      #:close [close ws-close!])
  (define c (connect (string->url url-string)))
  (define ch (make-channel))
  (define closed? (box #f))
  (define terminal (box #f))
  (define failure (box #f))
  (define close-signal (make-semaphore 0))
  (define close-requested? (box #f))
  (define close-done (make-semaphore 0))
  (define close-token (gensym 'ws-closed))
  (define close-evt
    (wrap-evt (semaphore-peek-evt close-signal) (lambda (_) close-token)))

  (define (record-failure! error)
    (box-cas! failure #f error)
    (box-cas! terminal #f error)
    (semaphore-post close-signal)
    (unbox failure))

  ;; The WebSocket package may block while closing. Its foreign wait stays on
  ;; an owned worker, and transport close joins the worker's exact result.
  (define (request-close!)
    (when (box-cas! close-requested? #f #t)
      (thread
       (lambda ()
         (dynamic-wind
          void
          (lambda ()
            (with-handlers ([(lambda (error) (not (exn:break? error)))
                             (lambda (error) (record-failure! error))])
              (close c)))
          (lambda () (semaphore-post close-done)))))))

  (define (stop!)
    (unless (unbox closed?)
      (set-box! closed? #t)
      (box-cas! terminal #f eof)
      (semaphore-post close-signal)
      (request-close!)))

  (define (post! value)
    (define put-token (gensym 'ws-put))
    (define put-evt
      (wrap-evt (channel-put-evt ch value) (lambda (_) put-token)))
    (eq? (sync put-evt close-evt) put-token))

  (define (send-bytes! frame)
    (cond
      [(zero? (bytes-length frame))
       (send c frame #:payload-type 'binary)]
      [else
       (for ([start (in-range 0 (bytes-length frame) WS-MESSAGE-HIGH-WATER)])
         (send c
               (subbytes frame start
                         (min (bytes-length frame)
                              (+ start WS-MESSAGE-HIGH-WATER)))
               #:payload-type 'binary))]))

  (define reader
    (thread
     (lambda ()
       (with-handlers ([(lambda (error) (not (exn:break? error)))
                        (lambda (error)
                          (record-failure! error)
                          (stop!))])
         (let loop ()
           (define msg (recv c #:payload-type 'binary))
           (cond
             [(eof-object? msg) (stop!)]
             [(not (bytes? msg))
              (error 'ws-transport "received a non-binary WebSocket message")]
             [(> (bytes-length msg) WS-MESSAGE-HIGH-WATER)
              (error 'ws-transport
                     "received ~a bytes, above the ~a-byte transport bound"
                     (bytes-length msg) WS-MESSAGE-HIGH-WATER)]
             [else (when (post! msg) (loop))]))))))

  (async-transport
   send-bytes!
   void
   (lambda (wake-evt)
     (define (deliver value)
       (cond
         [(exn? value) (raise value)]
         [(eof-object? value) eof]
         [else value]))
     (define ready (sync ch wake-evt close-evt))
     (cond
       [(eq? ready close-token) (deliver (or (unbox terminal) eof))]
       [(eq? ready wake-evt)
        (define again (channel-try-get ch))
        (cond
          [again (deliver again)]
          [(unbox closed?) (deliver (or (unbox terminal) eof))]
          [else 'woke])]
       [else (deliver ready)]))
   (lambda ()
     (stop!)
     (sync (semaphore-peek-evt close-done))
     (unless (eq? reader (current-thread)) (thread-wait reader))
     (define error (unbox failure))
     (when error (raise error)))))
