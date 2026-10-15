#lang racket/base
;; A small client for the tasks board, built on glowcap actors.
;;
;; The board is a secret-named capability with two lists, "To do" first and
;; "Done" second. Every change is a receipt-backed call: ask the target for a
;; fresh `mutation-sequence`, then `mutate` with that number, so a retried
;; change applies once. Adding a task returns the task, and `board-done` moves
;; that task. A watcher reports whether anything on the board changed since its
;; last look, and `watcher-stop` frees the board's observation context.
;;
;;   (define b (board-join "127.0.0.1" 9099 board-name))
;;   (define w (board-watch b))
;;   (define t (board-add b "buy groceries"))
;;   (board-done b t)
;;   (board-lists b)
;;   (watcher-changed? w)
;;   (watcher-stop w)
;;   (board-leave b)

(require "../../_demo/bindings.rkt"
         "../../../bindings/racket/glowcap-tcp.rkt")
(provide board-join board-add board-done board-watch watcher-changed? watcher-stop
         board-lists board-leave (struct-out task-list))

;; One list on the board: its name and the text of each task in order.
(struct task-list (name tasks) #:transparent)

(struct board (runtime session root todo-list done-list))

;; A task on the board, named by its capability.
(struct task (ref))

;; Reports whether the board changed since the last look. The cursor is the
;; position of that look.
(struct watcher (board receiver canceller [cursor #:mutable]))

;; Join the board: connect, fetch it by name, and take its first two lists.
(define (board-join host port name)
  (define runtime (open-runtime #:providers (list (tcp-provider))))
  (define c (runtime-connect runtime (tcp-locator host port)))
  (define the-board (session-fetch c name))
  (board runtime c the-board
         (session-send c the-board 'list 0)
         (session-send c the-board 'list 1)))

;; Send one request and drive the connection until it settles.
(define (call a-board target verb . args)
  (apply session-send (board-session a-board) target verb args))

;; One change with a fresh sequence number, so a retry applies once.
(define (mutate a-board target . args)
  (define seq (call a-board target 'mutation-sequence))
  (apply call a-board target 'mutate seq args))

;; Add a task to "To do". Returns the new task.
(define (board-add a-board text)
  (define added (mutate a-board (board-todo-list a-board) "add" text))
  (unless (ref? added) (error 'board-add "the added task was not a capability"))
  (task added))

;; Move `a-task` from "To do" to the end of "Done".
(define (board-done a-board a-task)
  (void (mutate a-board (board-todo-list a-board) "move" (task-ref a-task) (board-done-list a-board))))

;; Start watching the board for changes.
(define (board-watch a-board)
  (define reply (mutate a-board (board-root a-board) "observe"))
  (unless (and (pair? reply) (ref? (car reply)))
    (error 'board-watch "watching returned no receiver"))
  (unless (and (pair? (cdr reply)) (ref? (cadr reply)))
    (error 'board-watch "watching returned no canceller"))
  (define w (watcher a-board (car reply) (cadr reply) #f))
  (poll! w)
  w)

;; Poll from the stored cursor, keep the reply's cursor, and return whether the
;; board changed.
(define (poll! w)
  (define reply
    (if (watcher-cursor w)
        (call (watcher-board w) (watcher-receiver w) 'poll (watcher-cursor w))
        (call (watcher-board w) (watcher-receiver w) 'poll)))
  ;; Loam's `access:observation` record, see docs/loam/access-observation.md:
  ;; the cursor comes first and the fourth field is whether anything changed.
  (define fields (and (tagged-arg? reply) (tagged-arg-value reply)))
  (unless (and fields (= (length fields) 5) (bytes? (car fields)) (boolean? (list-ref fields 3)))
    (error 'watcher-changed? "the watcher sent no observation"))
  (set-watcher-cursor! w (car fields))
  (list-ref fields 3))

;; Whether anything on the board changed since the previous look.
(define (watcher-changed? w)
  (poll! w))

;; Close the board's observation context. Call it once when done watching.
(define (watcher-stop w)
  (define closed (call (watcher-board w) (watcher-canceller w) 'cancel))
  (unless (boolean? closed)
    (error 'watcher-stop "cancelling the watcher returned no boolean")))

;; Read both lists, "To do" first.
(define (board-lists a-board)
  (for/list ([lst (in-list (list (board-todo-list a-board) (board-done-list a-board)))])
    (define count (call a-board lst 'count))
    (task-list (call a-board lst 'name)
               (for/list ([i (in-range count)])
                 (call a-board (call a-board lst 'task i) 'text)))))

;; Leave the board and close the connection.
(define (board-leave a-board)
  (session-close! (board-session a-board))
  (runtime-close! (board-runtime a-board)))
