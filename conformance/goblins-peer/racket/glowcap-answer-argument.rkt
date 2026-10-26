#lang racket/base
;; glowcap-answer-argument.rkt: Goblins client that names one of its own
;; pending questions in argument position of a call to a glowcap actor.
;;
;; Goblins 0.18.0 writes a promise it passes as `desc:import-promise`, so this
;; script writes the canonical `op:deliver` itself through the live session
;; (`tcp-netlayer` `interop-send`), with `desc:answer` naming the ordinary
;; `make` question. The outbound observation hook supplies the question's
;; answer position and the actor's export position as Goblins wrote them.
;;
;; Usage:
;;   racket glowcap-answer-argument.rkt <target-port> <swiss-ascii> [local-port]
;;
;; Prints `ANSWER ARG OK` and exits 0 when glowcap answers `read` with the
;; value the `make` question settled to, which the ordinary `make` vow also
;; delivered.

(require goblins
         goblins/ocapn
         goblins/ocapn/structs-urls
         "tcp-netlayer.rkt"
         "captp-interop-wire.rkt"
         racket/async-channel)

(file-stream-buffer-mode (current-output-port) 'line)

(define argv (current-command-line-arguments))
(define target-port (string->number (vector-ref argv 0)))
(define swiss-ascii (vector-ref argv 1))
(define local-port
  (if (>= (vector-length argv) 3)
      (string->number (vector-ref argv 2))
      19994))

(define response-ch (make-async-channel))
(define dialer-vat (make-vat))
;; The netlayer, once the vat spawned it, so the main loop can write through it.
(define netlayer-box (box #f))
;; interop-send bypasses Goblins' question allocator. Keep its answer in the
;; disjoint high range the projection asker uses, away from the allocator's
;; low positions.
(define read-answer-pos #x7ffffffffffffffd)
;; Export 0 is Goblins' bootstrap object, a valid local export for glowcap's
;; resolver callback. The probe observes that callback on the wire.
(define listener-export-pos 0)
(define make-observed? (box #f))

(define (put-err tag . parts)
  (async-channel-put response-ch (cons 'err (cons tag parts))))

;; The `make` deliver leaving. Its answer position and the actor's export
;; position are what the `read` deliver names.
(define (observe-outbound msg)
  (when (and (equal? (record-label msg) "op:deliver") (not (unbox make-observed?)))
    (define args (record-field msg 2))
    (when (and (pair? args) (equal? (payload->text (car args)) "make"))
      (set-box! make-observed? #t)
      (define target-pos (export-desc-pos (record-field msg 1)))
      (if target-pos
          (async-channel-put response-ch (list 'make-sent target-pos (record-field msg 3)))
          (put-err 'make-target (record-field msg 1))))))

;; glowcap's resolver callback for the `read` answer arrives as a deliver to
;; export 0 carrying the settlement tag and payload.
(define (observe-inbound msg)
  (when (equal? (record-label msg) "op:deliver")
    (define target-pos (export-desc-pos (record-field msg 1)))
    (define args (record-field msg 2))
    (when (and (equal? target-pos listener-export-pos) (list? args) (>= (length args) 2))
      (define tag (payload->text (car args)))
      (define payload (payload->text (cadr args)))
      (if (equal? tag "fulfill")
          (async-channel-put response-ch (list 'read-ok payload))
          (put-err 'read-settlement tag payload)))))

;; Write the `read` deliver naming the `make` question, from a vat turn.
(define (send-read target-pos answer-pos)
  (dialer-vat
   'run
   (lambda ()
     (<- (unbox netlayer-box) 'interop-send
         (make-op:deliver (make-desc:export target-pos)
                          (list 'read (make-desc:answer answer-pos))
                          read-answer-pos
                          (make-desc:import-object listener-export-pos))
         interop-marshallers))))

(dialer-vat
 'run
 (lambda ()
   (define netlayer
     (spawn ^tcp-netlayer "127.0.0.1" local-port
            #:interop-message-sink observe-inbound
            #:interop-outbound-message-sink observe-outbound))
   (set-box! netlayer-box netlayer)
   (define mycapn (spawn-mycapn netlayer))
   (define target
     (ocapn-sturdyref
      (ocapn-node 'tcp (format "127.0.0.1:~a" target-port) #f)
      (string->bytes/latin-1 swiss-ascii)))
   (on (<- mycapn 'enliven target)
       (lambda (reader)
         (eprintf "answer-argument: enlivened reader~n")
         (on (<- reader 'make)
             (lambda (made)
               (async-channel-put response-ch (list 'make-ok (payload->text made))))
             #:catch
             (lambda (err) (put-err 'make err))))
       #:catch
       (lambda (err) (put-err 'enliven err)))))

(let loop ([sent? #f] [made #f] [read #f] [deadline (+ (current-inexact-milliseconds) 10000.0)])
  (cond
    [(and sent? made read)
     (cond
       [(equal? made read)
        (printf "ANSWER ARG OK: read answered with the value make settled to (~a)~n" read)
        (exit 0)]
       [else
        (printf "ANSWER ARG ERR: make settled to ~v but read answered ~v~n" made read)
        (exit 1)])]
    [else
     (define remaining-ms (- deadline (current-inexact-milliseconds)))
     (define reply (and (positive? remaining-ms)
                        (sync/timeout (/ remaining-ms 1000.0) response-ch)))
     (case (and (pair? reply) (car reply))
       [(make-sent)
        (send-read (cadr reply) (caddr reply))
        (loop #t made read deadline)]
       [(make-ok) (loop sent? (cadr reply) read deadline)]
       [(read-ok) (loop sent? made (cadr reply) deadline)]
       [(err)
        (printf "ANSWER ARG ERR: ~v~n" (cdr reply))
        (exit 1)]
       [else
        (printf "ANSWER ARG TIMEOUT sent=~v made=~v read=~v~n" sent? made read)
        (exit 1)])]))
