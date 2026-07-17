#lang racket/base
;; pancake-projection-asker.rkt — Goblins client that sends canonical `op:get`
;; and `op:index` against pancake projection responders.
;;
;; Goblins 0.18.0 has no outbound projection API at the application layer; this
;; script marshals the same CapTP records Goblins already defines and writes
;; them through the live session (`tcp-netlayer` `interop-send`). Question
;; positions 1–2 carry the record/list delivers; projection ops mint 3–4 so
;; they do not collide with Goblins' questioned-send counter (interop-send
;; bypasses the local answer table).
;;
;; Usage:
;;   racket pancake-projection-asker.rkt <target-port> <swiss-ascii> [local-port]
;;
;; Prints `PROJECTION OK` and exits 0 when delivers resolve and both projection
;; ops were written on the wire.

(require goblins
         goblins/ocapn
         goblins/ocapn/structs-urls
         "tcp-netlayer.rkt"
         "captp-projection-wire.rkt"
         racket/async-channel)

(file-stream-buffer-mode (current-output-port) 'line)

(define argv (current-command-line-arguments))
(define target-port (string->number (vector-ref argv 0)))
(define swiss-ascii (vector-ref argv 1))
(define local-port
  (if (>= (vector-length argv) 3)
      (string->number (vector-ref argv 2))
      19996))

(define response-ch (make-async-channel))
(define dialer-vat (make-vat))

(define record-answer-pos 1)
(define list-answer-pos 2)
(define get-answer-pos 3)
(define index-answer-pos 4)

(define (put-err tag . parts)
  (async-channel-put response-ch (cons 'err (cons tag parts))))

(dialer-vat
 'run
 (lambda ()
   (define netlayer (spawn ^tcp-netlayer "127.0.0.1" local-port))
   (define mycapn (spawn-mycapn netlayer))
   (define target
     (ocapn-sturdyref
      (ocapn-node 'tcp (format "127.0.0.1:~a" target-port) #f)
      (string->bytes/latin-1 swiss-ascii)))

   (on (<- mycapn 'enliven target)
       (lambda (provider)
         (define record-vow (<- provider 'record "pancake-get"))
         (on record-vow
             (lambda (record)
               (define got-name
                 (cond
                   [(string? record) record]
                   [(bytes? record) (bytes->string/latin-1 record)]
                   [(hash? record) (hash-ref record "name")]
                   [(pair? record) (cadr record)]
                   [else #f]))
               (unless (equal? got-name "pancake-get")
                 (put-err 'get-field got-name)
                 (void))
               (define list-vow (<- provider 'list))
               (on list-vow
                   (lambda (lst)
                     (define first
                       (cond
                         [(pair? lst) (car lst)]
                         [(vector? lst) (vector-ref lst 0)]
                         [else #f]))
                     (unless (equal? first "alpha")
                       (put-err 'index-element first)
                       (void))
                     (<-np netlayer 'interop-send
                           (make-op:get (make-desc:answer record-answer-pos)
                                        "name"
                                        get-answer-pos)
                           interop-marshallers)
                     (<-np netlayer 'interop-send
                           (make-op:index (make-desc:answer list-answer-pos)
                                          0
                                          index-answer-pos)
                           interop-marshallers)
                     (async-channel-put response-ch '(ok)))
                   #:catch
                   (lambda (err) (put-err 'list err))))
             #:catch
             (lambda (err) (put-err 'record err))))
       #:catch
       (lambda (err) (put-err 'enliven err)))))

(define reply (sync/timeout 10.0 response-ch))
(case (and (pair? reply) (car reply))
  [(ok)
   (printf "PROJECTION OK~n")
   (exit 0)]
  [(err)
   (printf "PROJECTION ERR: ~v~n" (cdr reply))
   (exit 1)]
  [else
   (printf "PROJECTION TIMEOUT~n")
   (exit 1)])
