#lang racket/base
;; `interface-goblins-check`: plain Goblins calls the real Tasks server's
;; generated Zig creation checker. Arguments: target TCP port and board swiss.
;; The parent owns the process deadline and termination. This caller has its
;; own finite response wait and exits nonzero for every failed assertion.
(require goblins goblins/ocapn goblins/ocapn/structs-urls
         racket/async-channel "tcp-netlayer.rkt")

(define argv (current-command-line-arguments))
(unless (= (vector-length argv) 2) (error 'arguments "expected port and board swiss"))
(define result (make-async-channel))
(define caller (make-vat))
(define profile-seen? #f)
(define (expect actual expected)
  (unless (equal? actual expected) (error 'interface-creation "expected ~v, got ~v" expected actual)))
(define (after promise continuation) (on promise continuation #:promise? #t))

(define (chain initial . steps)
  (for/fold ([promise initial]) ([step (in-list steps)]) (after promise step)))

(define (exercise list)
  (define sequence #f)
  (chain (<- list 'mutation-sequence)
    (lambda (value) (set! sequence value) (<- list 'mutate sequence "add" "write tests"))
    (lambda (task) (<- task 'text))
    (lambda (text) (expect text "write tests") (<- list 'mutate sequence "add" "write tests"))
    (lambda (task) (<- task 'text))
    (lambda (text) (expect text "write tests") (<- list 'count))
    (lambda (count) (expect count 1) (<- list 'mutation-sequence))
    (lambda (next)
      (on (<- list 'mutate next "add" "")
          (lambda (_) (error 'interface-creation "invalid creation fulfilled"))
          #:catch (lambda (err)
                    (unless (regexp-match? #rx"InvalidArguments" (format "~a" err)) (raise err)))
          #:promise? #t))
    (lambda (_) (<- list 'count))
    (lambda (count) (expect count 1) (<- list 'mutation-sequence))
    (lambda (next) (<- list 'mutate next "add" "after refusal"))
    (lambda (task) (<- task 'text))
    (lambda (text) (expect text "after refusal") (<- list 'count))
    (lambda (count) (expect count 2))))

(caller 'run
  (lambda ()
    (define netlayer
      (spawn ^tcp-netlayer "127.0.0.1" 0
             #:session-trace
             (lambda (event _handle info)
               (when (eq? event 'open)
                 (expect (hash-ref info 'captp-version) "1.0")
                 (expect (hash-ref info 'codec) "syrup")
                 (set! profile-seen? #t)))))
    (define mycapn (spawn-mycapn netlayer))
    (define target
      (ocapn-sturdyref
        (ocapn-node 'tcp (string-append "127.0.0.1:" (vector-ref argv 0)) #f)
        (string->bytes/latin-1 (vector-ref argv 1))))
    (on (after (<- mycapn 'enliven target)
          (lambda (board) (after (<- board 'list 0) exercise)))
        (lambda (_) (async-channel-put result 'ok))
        #:catch (lambda (err) (async-channel-put result (list 'error err))))))

(define outcome (sync/timeout 20 result))
(unless (and (eq? outcome 'ok) profile-seen?)
  (error 'interface-creation "failed or timed out: ~v, profile observed: ~v" outcome profile-seen?))
(displayln "interface Goblins caller: Syrup/V1.0, creation, callable task, exact replay and refusal passed")
