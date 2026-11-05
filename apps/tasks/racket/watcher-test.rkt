#lang racket/base
;; Adapt only the imported public send in a temporary copy of the actual app.
;; Observe and successful cancel still execute against the Tasks server.
(require rackunit racket/file racket/path racket/runtime-path)
(current-check-handler raise)
(define-runtime-path source "task-client.rkt")
(define-runtime-path binding "../../_demo/bindings.rkt")
(define-runtime-path tcp "../../../bindings/racket/glowcap-tcp.rkt")
(define adapted (make-temporary-file "tasks-watcher-~a.rkt"))
(define input (file->string source))
(define code
  (regexp-replace
   #rx"\"../../../bindings/racket/glowcap-tcp.rkt\""
   (regexp-replace #rx"\"../../_demo/bindings.rkt\"" input
                   (format "(rename-in (file ~s) [session-send original-send])" (path->string binding)))
   (format "(file ~s)" (path->string tcp))))
(call-with-output-file adapted #:exists 'truncate
  (lambda (out)
    (display code out)
    (display #<<ADAPTER

(provide configure! disable! poll-error cleanup-error cancel-attempts server-cancelled? fixture-cleanup!)
(define poll-error (exn:fail "injected first poll failure" (current-continuation-marks)))
(define cleanup-error (exn:fail "injected cancellation failure" (current-continuation-marks)))
(define first-poll? #f)
(define refuse-cleanup? #f)
(define cancel-attempts 0)
(define server-cancelled? #f)
(define registration #f)
(define (configure! both?)
  (set! first-poll? #t)
  (set! refuse-cleanup? both?)
  (set! cancel-attempts 0)
  (set! server-cancelled? #f))
(define (disable!) (set! first-poll? #f) (set! refuse-cleanup? #f))
(define (session-send c target verb . args)
  (cond
    [(and (eq? verb 'poll) first-poll?)
     (set! first-poll? #f)
     (raise poll-error)]
    [(eq? verb 'cancel)
     (set! cancel-attempts (add1 cancel-attempts))
     (set! registration (cons c target))
     (when refuse-cleanup? (raise cleanup-error))
     (define reply (apply original-send c target verb args))
     (set! server-cancelled? (eq? reply #t))
     reply]
    [else (apply original-send c target verb args)]))
(define (fixture-cleanup!)
  (original-send (car registration) (cdr registration) 'cancel))
ADAPTER
             out)))

(define (get name) (dynamic-require adapted name))
(define args (current-command-line-arguments))
(define b ((get 'board-join) "127.0.0.1" (string->number (vector-ref args 0)) (vector-ref args 1)))
(dynamic-wind
 void
 (lambda ()
   (for ([both? '(#f #t)])
     ((get 'configure!) both?)
     (define failure
       (with-handlers ([exn? values])
         ((get 'board-watch) b)
         (error 'watcher-test "injected poll failure was ignored")))
     (check-equal? (get 'cancel-attempts) 1 "startup must cancel exactly once")
     (if both?
         (begin
           (check-true ((get 'exn:fail:watcher-start?) failure))
           (check-eq? ((get 'exn:fail:watcher-start-primary) failure) (get 'poll-error))
           (check-eq? ((get 'exn:fail:watcher-start-cleanup) failure) (get 'cleanup-error))
           (check-true ((get 'fixture-cleanup!))))
         (begin
           (check-eq? failure (get 'poll-error))
           (check-true (get 'server-cancelled?))))
     ((get 'disable!))
     (define next ((get 'board-watch) b))
     ((get 'watcher-stop) next)))
 (lambda ()
   ((get 'board-leave) b)
   (delete-file adapted)))
(displayln "Racket: failed watcher startup cancels once and preserves cleanup failures")
