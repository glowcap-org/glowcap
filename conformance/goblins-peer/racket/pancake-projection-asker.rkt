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
;; Prints `PROJECTION OK` and exits 0 when delivers resolve, both projection
;; ops were written on the wire, and pancake settled both projected answers
;; with the expected payloads.

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
;; Export 0 is Goblins' bootstrap object and therefore a valid local export for
;; a V1.0 listen callback descriptor. The probe observes pancake's callback on
;; the wire; it does not claim Goblins has an application-level projection API.
(define listener-export-pos 0)

(define (put-err tag . parts)
  (async-channel-put response-ch (cons 'err (cons tag parts))))

(define (record-label obj)
  (and (struct? obj)
       (let* ([vec (struct->vector obj)]
              [raw (and (> (vector-length vec) 0) (vector-ref vec 0))]
              [text (format "~a" raw)])
         (cond
           [(regexp-match #rx"^struct:(.+)$" text) => cadr]
           [else text]))))

(define (record-field obj idx)
  (define vec (struct->vector obj))
  (and (> (vector-length vec) idx) (vector-ref vec idx)))

(define (answer-desc-pos desc)
  (and (equal? (record-label desc) "desc:answer")
       (record-field desc 1)))

(define (export-desc-pos desc)
  (and (equal? (record-label desc) "desc:export")
       (record-field desc 1)))

(define (payload->text payload)
  (cond
    [(string? payload) payload]
    [(bytes? payload) (bytes->string/latin-1 payload)]
    [(symbol? payload) (symbol->string payload)]
    [else #f]))

(define (observe-inbound msg)
  (when (equal? (record-label msg) "op:deliver")
    (define target-pos (export-desc-pos (record-field msg 1)))
    (define args (record-field msg 2))
    (when (and (equal? target-pos listener-export-pos) (list? args) (>= (length args) 2))
      (define tag (payload->text (car args)))
      (define payload (payload->text (cadr args)))
      (cond
        [(and (equal? payload "pancake-get")
              (equal? tag "fulfill"))
         (async-channel-put response-ch '(get-ok))]
        [(and (equal? payload "alpha")
              (equal? tag "fulfill"))
         (async-channel-put response-ch '(index-ok))]
        [(not (equal? tag "fulfill"))
         (put-err 'projection-settlement tag payload)]))))

(dialer-vat
 'run
 (lambda ()
   (define netlayer
     (spawn ^tcp-netlayer "127.0.0.1" local-port
            #:interop-message-sink observe-inbound))
   (define mycapn (spawn-mycapn netlayer))
   (define target
     (ocapn-sturdyref
      (ocapn-node 'tcp (format "127.0.0.1:~a" target-port) #f)
      (string->bytes/latin-1 swiss-ascii)))

   (on (<- mycapn 'enliven target)
       (lambda (provider)
         (eprintf "asker: enlivened provider~n")
         (define record-vow (<- provider 'record "pancake-get"))
         (on record-vow
             (lambda (record)
               (eprintf "asker: record vow resolved: ~v~n" record)
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
                     (eprintf "asker: list vow resolved~n")
                     (define first
                       (cond
                         [(pair? lst) (car lst)]
                         [(vector? lst) (vector-ref lst 0)]
                         [else #f]))
                     (unless (equal? first "alpha")
                       (put-err 'index-element first)
                       (void))
                     ;; Sequence the sends before the exit: `interop-send`
                     ;; writes inside the netlayer's turn, so chaining on its
                     ;; vows guarantees both frames reached the port before
                     ;; `(ok)` lets the process exit. A fire-and-forget `<-np`
                     ;; here would race process teardown and could drop the
                     ;; frames this scenario exists to put on the wire.
                     (on (<- netlayer 'interop-send
                             (make-op:get (make-desc:answer record-answer-pos)
                                          "name"
                                          get-answer-pos)
                             interop-marshallers)
                         (lambda (_get-sent)
                           (on (<- netlayer 'interop-send
                                   (make-op:index (make-desc:answer list-answer-pos)
                                                  0
                                                  index-answer-pos)
                                   interop-marshallers)
                               (lambda (_index-sent)
                                 (on (<- netlayer 'interop-send
                                         (make-op:listen
                                          (make-desc:answer get-answer-pos)
                                          (make-desc:import-object listener-export-pos)
                                          #f)
                                         interop-marshallers)
                                     (lambda (_get-listen-sent)
                                       (on (<- netlayer 'interop-send
                                               (make-op:listen
                                                (make-desc:answer index-answer-pos)
                                                (make-desc:import-object listener-export-pos)
                                                #f)
                                               interop-marshallers)
                                           (lambda (_index-listen-sent)
                                             (async-channel-put response-ch '(sent)))
                                           #:catch
                                           (lambda (err) (put-err 'index-listen-send err))))
                                     #:catch
                                     (lambda (err) (put-err 'get-listen-send err))))
                               #:catch
                               (lambda (err) (put-err 'index-send err))))
                         #:catch
                         (lambda (err) (put-err 'get-send err))))
                   #:catch
                   (lambda (err) (put-err 'list err))))
             #:catch
             (lambda (err) (put-err 'record err))))
       #:catch
       (lambda (err) (put-err 'enliven err)))))

(let loop ([sent? #f] [got-get? #f] [got-index? #f] [deadline (+ (current-inexact-milliseconds) 10000.0)])
  (cond
    [(and sent? got-get? got-index?)
     (printf "PROJECTION OK: op:get and op:index settled with expected payloads~n")
     (exit 0)]
    [else
     (define remaining-ms (- deadline (current-inexact-milliseconds)))
     (define reply (and (positive? remaining-ms)
                        (sync/timeout (/ remaining-ms 1000.0) response-ch)))
     (case (and (pair? reply) (car reply))
       [(sent) (loop #t got-get? got-index? deadline)]
       [(get-ok) (loop sent? #t got-index? deadline)]
       [(index-ok) (loop sent? got-get? #t deadline)]
       [(err)
        (printf "PROJECTION ERR: ~v~n" (cdr reply))
        (exit 1)]
       [else
        (printf "PROJECTION TIMEOUT sent=~v get=~v index=~v~n" sent? got-get? got-index?)
        (exit 1)])]))
