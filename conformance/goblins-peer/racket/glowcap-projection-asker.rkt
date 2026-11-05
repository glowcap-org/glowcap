#lang racket/base
;; Goblins has no application API for outbound op:get/op:index. This probe
;; translates two ordinary Goblins delivers into projection/listen pairs while
;; preserving each allocated question and resolver export. Actual Goblins vow
;; callbacks observe the replies. A later fetch and call keep the same session
;; usable after the listener releases, including its bootstrap export.
;; Run by goblins-interop: <target-port> <swiss-ascii> [local-port].

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
(define record-answer-pos #f)
(define list-answer-pos #f)
;; Keep the source questions alive until both projections have settled.
(define held-answer-vows (box '()))
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

(define (write-projection write-message msg marshallers)
  (define verb (deliver-verb msg))
  (cond
    [(equal? verb "record")
     (set! record-answer-pos (record-field msg 3))
     (write-message msg marshallers)]
    [(equal? verb "list")
     (unless list-answer-pos (set! list-answer-pos (record-field msg 3)))
     (write-message msg marshallers)]
    [(or (equal? verb "interop-get") (equal? verb "interop-index"))
     (define source-pos (if (equal? verb "interop-get") record-answer-pos list-answer-pos))
     (unless (exact-nonnegative-integer? source-pos)
       (error 'projection-asker "source question was not allocated"))
     (define-values (answer-pos resolver) (deliver-answer-and-resolver msg))
     (register-resolver resolver)
     (define codecs (append interop-marshallers marshallers))
     (write-message
      (if (equal? verb "interop-get")
          (make-op:get (make-desc:answer source-pos) "name" answer-pos)
          (make-op:index (make-desc:answer source-pos) 0 answer-pos))
      codecs)
     (write-message (make-op:listen (make-desc:answer answer-pos) resolver #f) codecs)]
    [else (write-message msg marshallers)]))

(dialer-vat
 'run
 (lambda ()
   (define netlayer
     (spawn ^tcp-netlayer "127.0.0.1" local-port
            #:trace (lambda (event . _)
                      (when (eq? event 'connect) (set! connections (add1 connections))))
            #:interop-write-message write-projection
            #:interop-message-sink observe-session))
   (define mycapn (spawn-mycapn netlayer))
   (define target
     (ocapn-sturdyref
      (ocapn-node 'tcp (format "127.0.0.1:~a" target-port) #f)
      (string->bytes/latin-1 swiss-ascii)))
   (define proof
     (on (<- mycapn 'enliven target)
         (lambda (provider)
           (define record-vow (<- provider 'record "glowcap-get"))
           (define list-vow (<- provider 'list))
           (set-box! held-answer-vows (list record-vow list-vow))
           (define get-vow (<- provider 'interop-get))
           (define index-vow (<- provider 'interop-index))
           (on get-vow
               (lambda (got)
                 (unless (equal? got "glowcap-get")
                   (error 'projection-asker "wrong field: ~v" got))
                 (on index-vow
                     (lambda (first)
                       (unless (equal? first "alpha")
                         (error 'projection-asker "wrong index: ~v" first))
                       (set-box! held-answer-vows '())
                       ;; Await both listener releases, then prove Goblins
                       ;; consumed them by fetching and calling on this session.
                       (on (sync/pr resolver-releases)
                           (lambda (_released)
                             (on (<- mycapn 'enliven
                                     (ocapn-sturdyref advertised-location
                                                      (ocapn-sturdyref-swiss-num target)))
                                 (lambda (again) (<- again 'list))
                                 #:promise? #t))
                           #:promise? #t))
                     #:promise? #t))
               #:promise? #t))
         #:promise? #t))
   (on proof
       (lambda (lst)
         (if (and (pair? lst) (equal? (car lst) "alpha") (= connections 1))
             (async-channel-put response-ch '(ok))
             (async-channel-put response-ch (list 'err 'session-health lst connections))))
       #:catch (lambda (err) (async-channel-put response-ch (list 'err err))))))

(define reply (sync/timeout 10.0 response-ch))
(cond
  [(equal? reply '(ok))
   (printf "PROJECTION OK: Goblins resolved both projections and fetched again on the same session~n")
   (exit 0)]
  [else
   (printf "PROJECTION ERR: ~v~n" (or reply 'timeout))
   (exit 1)])
