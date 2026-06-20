#lang racket/base
;; A one-shot tasks client for the cross-language demo, in native Racket:
;; connect, add a task, list, mark it done, list again, confirm, and exit. The
;; same sequence every other language's one-shot client runs, on one OCapN wire.
;;
;;   racket client.rkt 127.0.0.1 9099 rkt-alan "buy groceries"

(require "task-client.rkt")

(define (run-client host port nick text)
  (define b (board-join host port))
  (define id (board-add b (format "[~a] ~a" nick text)))
  (printf "~a: added task #~a\n" nick id)
  (flush-output)

  (define before (board-list b))
  (printf "~a: ~a task(s) on the board\n" nick (length before))
  (for ([t (in-list before)])
    (printf "  ~a #~a ~a\n" (if (task-completed? t) "[x]" "[ ]") (task-id t) (task-text t)))
  (flush-output)

  (board-done b id)
  (printf "~a: completed task #~a\n" nick id)
  (flush-output)

  (define after (board-list b))
  (define ours (findf (lambda (t) (= (task-id t) id)) after))
  (cond
    [(and ours (task-completed? ours))
     (printf "~a: confirmed task #~a is done\n" nick id)
     (flush-output)]
    [else
     (eprintf "~a: FAIL, task #~a not marked completed\n" nick id)
     (board-leave b)
     (exit 1)])
  (board-leave b))

(module+ main
  (define args (current-command-line-arguments))
  (when (< (vector-length args) 4)
    (eprintf "usage: client.rkt <host> <port> <nick> <task-text>\n")
    (exit 2))
  (define host (vector-ref args 0))
  (define port (string->number (vector-ref args 1)))
  (define nick (vector-ref args 2))
  (define text (vector-ref args 3))
  (with-handlers ([(lambda (_) #t)
                   (lambda (e)
                     (eprintf "client ~a failed: ~a\n" nick (if (exn? e) (exn-message e) e))
                     (exit 1))])
    (run-client host port nick text)
    (exit 0)))
