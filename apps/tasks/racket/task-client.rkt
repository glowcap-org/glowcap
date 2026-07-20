#lang racket/base
;; A small, friendly client for the tasks board, built on pancake actors.
;;
;; On the connection API this is barely a layer: connect, fetch the board by
;; name, publish a watcher, and call add/done/list. The Goblins verbs (`spawn`,
;; `<-`, `on`, `methods`) work as they do in Goblins; `connect`, `session-fetch`,
;; and `session-send` do the peer/vat/import plumbing.
;;
;;   (define b (board-join "127.0.0.1" 9099))
;;   (define id (board-add b "buy groceries"))
;;   (board-done b id)
;;   (for ([t (board-list b)]) (printf "~a\n" (task-text t)))
;;   (board-leave b)

(require "../../_demo/bindings.rkt")
(provide board-join board-add board-done board-list board-leave (struct-out task))

;; One task on the board.
(struct task (id text completed?) #:transparent)

(struct board (session far) #:mutable)

;; Join the board: connect, fetch the board by name, publish a watcher the board
;; can call back (we ignore its updates in this one-shot client).
(define (board-join host port)
  (define c (connect (tcp-locator host port)))
  (define the-board (session-fetch c "board"))
  (define a-board (board c the-board))
  (define watcher (session-spawn c (lambda (bcom) (methods [(update tasks) (void)]))))
  (board-call a-board 'watch watcher)
  a-board)

;; Send a request to the board and drive the connection until it settles,
;; returning the reply value, `session-send` aimed at the board.
(define (board-call a-board verb . args)
  (apply session-send (board-session a-board) (board-far a-board) verb args))

;; Add a task; returns its id.
(define (board-add a-board text) (board-call a-board 'add text))

;; Mark a task done.
(define (board-done a-board id) (board-call a-board 'done id))

;; List the current tasks.
(define (board-list a-board)
  (define raw (board-call a-board 'list))
  (if (list? raw)
      (for/list ([entry (in-list raw)] #:when (and (list? entry) (>= (length entry) 3)))
        (task (list-ref entry 0) (list-ref entry 1) (list-ref entry 2)))
      '()))

;; Leave the board and close the connection.
(define (board-leave a-board)
  (session-close! (board-session a-board)))
