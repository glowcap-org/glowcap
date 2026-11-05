#lang racket/base
;; Name a pending Goblins question in a delivered argument. Goblins normally
;; exports a passed promise, so this probe translates the arguments of one
;; ordinary read deliver while preserving its real question and resolver.
;; Goblins itself must settle both vows, then re-fetch the actor on the same
;; session after listener GC. Run by goblins-interop:
;; <target-port> <swiss-ascii> [local-port].

(require goblins
         goblins/actor-lib/sync-pr
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
  (if (>= (vector-length argv) 3) (string->number (vector-ref argv 2)) 0))
(define response-ch (make-async-channel))
(define dialer-vat (make-vat))
(define make-answer-pos #f)
(define connections 0)
(define advertised-location #f)
(define-values (register-resolver observe-releases resolver-releases)
  (make-resolver-gc-watch 2))

;; Goblins caches by the complete advertised locator, including hints. Reuse
;; that snapshot for the health fetch so it cannot silently open a new session.
(define (observe-session msg)
  (when (equal? (record-label msg) "op:start-session")
    (set! advertised-location (record-field msg 3)))
  (observe-releases msg))

(define (write-answer-argument write-message msg marshallers)
  (define verb (deliver-verb msg))
  (cond
    [(equal? verb "make")
     (define-values (answer-pos resolver) (deliver-answer-and-resolver msg))
     (set! make-answer-pos answer-pos)
     (register-resolver resolver)
     (write-message msg marshallers)]
    [(equal? verb "read")
     (unless (exact-nonnegative-integer? make-answer-pos)
       (error 'answer-argument "make question was not allocated"))
     (define-values (answer-pos resolver) (deliver-answer-and-resolver msg))
     (register-resolver resolver)
     (write-message
      (make-op:deliver (record-field msg 1)
                       (list 'read (make-desc:answer make-answer-pos))
                       answer-pos resolver)
      (append interop-marshallers marshallers))]
    [else (write-message msg marshallers)]))

(dialer-vat
 'run
 (lambda ()
   (define netlayer
     (spawn ^tcp-netlayer "127.0.0.1" local-port
            #:trace (lambda (event . _)
                      (when (eq? event 'connect) (set! connections (add1 connections))))
            #:interop-write-message write-answer-argument
            #:interop-message-sink observe-session))
   (define mycapn (spawn-mycapn netlayer))
   (define target
     (ocapn-sturdyref
      (ocapn-node 'tcp (format "127.0.0.1:~a" target-port) #f)
      (string->bytes/latin-1 swiss-ascii)))
   (define proof
     (on (<- mycapn 'enliven target)
         (lambda (reader)
           (define made (<- reader 'make))
           (define read (<- reader 'read))
           (on read
               (lambda (value)
                 (on made
                     (lambda (expected)
                       (unless (equal? expected value)
                         (error 'answer-argument "make/read mismatch: ~v ~v" expected value))
                       (on (sync/pr resolver-releases)
                           (lambda (_released)
                             ;; Both listener GC frames precede the health reply
                             ;; on Goblins' ordered incoming stream.
                             (on (<- mycapn 'enliven
                                     (ocapn-sturdyref advertised-location
                                                      (ocapn-sturdyref-swiss-num target)))
                                 (lambda (again)
                                   (unless (and (eq? reader again) (= connections 1))
                                     (error 'answer-argument "session identity changed"))
                                   (<- again 'health))
                                 #:promise? #t))
                           #:promise? #t))
                     #:promise? #t))
               #:promise? #t))
         #:promise? #t))
   (on proof
       (lambda (value) (async-channel-put response-ch (list 'ok value)))
       #:catch (lambda (err) (async-channel-put response-ch (list 'err err))))))

(define reply (sync/timeout 10.0 response-ch))
(cond
  [(equal? reply '(ok "reader healthy"))
   (printf "ANSWER ARG OK: Goblins settled both vows, released their resolvers, and called again~n")
   (exit 0)]
  [else
   (printf "ANSWER ARG ERR: ~v~n" (or reply 'timeout))
   (exit 1)])
