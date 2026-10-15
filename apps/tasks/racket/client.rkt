#lang racket/base
;; A one-shot tasks client for the cross-language demo, in native Racket: join
;; the board and watch it, add a task, mark it done, print both lists, and exit 0
;; once the task shows up under "Done" and the watcher saw the board change.
;;
;;   racket client.rkt 127.0.0.1 9099 <board-name> rkt-alan "buy groceries"

(require racket/list
         "task-client.rkt")

(define (run-client host port name nick task)
  (define b (board-join host port name))
  (define text (format "[~a] ~a" nick task))
  (define w (board-watch b))
  (define t (board-add b text))
  (printf "~a: added a task\n" nick)
  (board-done b t)
  (printf "~a: marked it done\n" nick)

  (define lists (board-lists b))
  (for ([l (in-list lists)])
    (printf "~a: ~a: ~a task(s)\n" nick (task-list-name l) (length (task-list-tasks l)))
    (for ([t (in-list (task-list-tasks l))])
      (printf "  ~a\n" t)))
  (flush-output)
  (define watched? (watcher-changed? w))
  (watcher-stop w)
  (board-leave b)

  (cond
    [(member text (task-list-tasks (second lists)))
     (printf "~a: confirmed the task is done\n" nick)
     (cond
       [watched? (printf "~a: the watcher saw the board change\n" nick)]
       [else
        (eprintf "~a: FAIL, the watcher saw no change\n" nick)
        (exit 1)])]
    [else
     (eprintf "~a: FAIL, the task is not in the done list\n" nick)
     (exit 1)]))

(module+ main
  (define args (current-command-line-arguments))
  (when (< (vector-length args) 5)
    (eprintf "usage: client.rkt <host> <port> <board-name> <nick> <task-text>\n")
    (exit 2))
  (define nick (vector-ref args 3))
  (with-handlers ([(lambda (_) #t)
                   (lambda (e)
                     (eprintf "client ~a failed: ~a\n" nick (if (exn? e) (exn-message e) e))
                     (exit 1))])
    (run-client (vector-ref args 0)
                (string->number (vector-ref args 1))
                (vector-ref args 2)
                nick
                (vector-ref args 4))
    (exit 0)))
