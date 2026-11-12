#lang racket/base
;; Exercise the public application API from concurrent green threads.
(require rackunit racket/list "task-client.rkt")
(current-check-handler raise)

(define args (current-command-line-arguments))
(define b (board-join (vector-ref args 0) (vector-ref args 1)))
(define (tasks) (task-list-tasks (car (board-lists b))))
(define (overlap left right)
  (define start (make-semaphore 0))
  (define results (make-channel))
  (for ([text (in-list (list left right))])
    (thread
     (lambda ()
       (semaphore-wait start)
       (channel-put results
                    (with-handlers ([exn:fail? values]) (board-add b text))))))
  (semaphore-post start)
  (semaphore-post start)
  (list (channel-get results) (channel-get results)))

(dynamic-wind
 void
 (lambda ()
   (define before (length (tasks)))
   (check-false (ormap exn? (overlap "racket same" "racket same")))
   (check-equal? (length (tasks)) (+ before 2) "identical adds collapsed into one receipt")
   (check-false (ormap exn? (overlap "racket left" "racket right")))
   (check-equal? (length (tasks)) (+ before 4))
   (define outcomes (overlap (make-string 4097 #\x) "racket after refusal"))
   (check-equal? (length (filter exn? outcomes)) 1)
   (check-equal? (length (tasks)) (+ before 5))
   (displayln "Racket: identical/distinct actions and refusal recovery passed"))
 (lambda () (board-leave b)))
