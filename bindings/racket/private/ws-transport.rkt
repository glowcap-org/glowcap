#lang racket/base
;; The WebSocket byte transport for the keyed-relay rendezvous dial (ADR-0034).
;;
;; A keyed-relay peer holds an inbound socket at a relay under its key
;; designator; the dialer opens the relay's rendezvous leg and the keyed OCapN
;; handshake runs end to end over it. This module adapts one client WebSocket
;; (net/rfc6455) to the `async-transport` record the pump drives: each binary
;; message is one inbound chunk, and the host's stream delimiter owns framing,
;; as over TCP.
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
         "async.rkt"
         "constants.rkt")

(provide ws-transport)

;; A WebSocket message is a transport chunk and may coalesce several CapTP
;; frames. This bound is independent from DEFAULT-FRAME-CAP.
(define WS-MESSAGE-HIGH-WATER BINDING-WEBSOCKET-MESSAGE-CAP-BYTES)

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
      [(<= (bytes-length frame) WS-MESSAGE-HIGH-WATER)
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

(module+ test
  (require rackunit
           racket/list)

  ;; Ordinary writes retain the caller's immutable byte string. Oversized
  ;; writes pay one explicit `subbytes` copy per bounded WebSocket message;
  ;; net/rfc6455 then owns framing and masking.
  (define release-reader (make-semaphore 0))
  (define sent '())
  (define transport
    (ws-transport
     "ws://copy.test/"
     #:connect (lambda (_url) 'fake-websocket)
     #:recv (lambda (_connection #:payload-type _payload-type)
              (sync release-reader)
              eof)
     #:send (lambda (_connection bytes #:payload-type _payload-type)
              (set! sent (cons bytes sent)))
     #:close (lambda (_connection) (semaphore-post release-reader))))
  (define ordinary #"ordinary")
  ((async-transport-write-frame! transport) ordinary)
  (check-eq? (car sent) ordinary)
  (define oversized (make-bytes (+ WS-MESSAGE-HIGH-WATER 7)))
  ((async-transport-write-frame! transport) oversized)
  (define chunks (reverse (take sent 2)))
  (check-equal? (map bytes-length chunks) (list WS-MESSAGE-HIGH-WATER 7))
  (check-false (ormap (lambda (chunk) (eq? chunk oversized)) chunks))
  ((async-transport-close! transport))

  ;; A read exception is not EOF. Close joins the worker and keeps that first
  ;; failure ahead of a later close refusal on every observation.
  (define read-failure
    (exn:fail "WebSocket receive failed" (current-continuation-marks)))
  (define close-failure
    (exn:fail "WebSocket close failed" (current-continuation-marks)))
  (define failed
    (ws-transport
     "ws://failure.invalid/"
     #:connect (lambda (_url) 'fake-websocket)
     #:recv (lambda (_connection #:payload-type _payload-type)
              (raise read-failure))
     #:send (lambda (_connection _bytes #:payload-type _payload-type) (void))
     #:close (lambda (_connection) (raise close-failure))))
  (check-eq?
   (with-handlers ([exn:fail? values])
     ((async-transport-read-some! failed) (make-semaphore 0))
     #f)
   read-failure)
  (check-eq?
   (with-handlers ([exn:fail? values])
     ((async-transport-close! failed))
     #f)
   read-failure)
  (check-eq?
   (with-handlers ([exn:fail? values])
     ((async-transport-close! failed))
     #f)
   read-failure))
