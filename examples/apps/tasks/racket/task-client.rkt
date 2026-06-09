#lang racket/base
;; A small, friendly client for the tasks board, built on pancake actors.
;;
;; On the new connection API this is barely a layer: connect, fetch the board by
;; name, publish a watcher, and call add/done/list. The Goblins verbs (`spawn`,
;; `<-`, `on`, `methods`) are unchanged; `connect` and `fetch` replace the
;; peer/vat/import plumbing.
;;
;;   (define b (board-join "127.0.0.1" 9099))
;;   (define id (board-add b "buy groceries"))
;;   (board-done b id)
;;   (for ([t (board-list b)]) (printf "~a\n" (task-text t)))
;;   (board-leave b)

(require "../../../../bindings/racket/pancake.rkt")
(provide board-join board-add board-done board-list board-leave (struct-out task))

;; One task on the board.
(struct task (id text completed?) #:transparent)

(struct board (conn far) #:mutable)

;; Join the board: connect, fetch the board by name, publish a watcher the board
;; can call back (we ignore its updates in this one-shot client).
(define (board-join host port)
  (define c (connect host port))
  (define the-board (fetch c "board"))
  (define a-board (board c the-board))
  (define watcher (conn-spawn c (lambda (bcom) (methods [(update tasks) (void)]))))
  (board-call a-board 'watch watcher)
  a-board)

;; Send a request to the board and drive the connection until it settles,
;; returning the reply value. Single-threaded, matching the rest of the binding.
(define (board-call a-board verb . args)
  (define c (board-conn a-board))
  (define result (box 'pending))
  (with-vat (conn-vat c)
    (define vow (apply <- (board-far a-board) verb args))
    (on vow
        (lambda (v) (set-box! result (cons 'ok v)))
        #:catch (lambda (m) (set-box! result (cons 'err m)))))
  (async-flush! (conn-async c))
  (let loop ()
    (define r (unbox result))
    (cond
      [(eq? r 'pending)
       (define ev (async-next-event (conn-async c)))
       (when (eof-object? ev) (error 'board-call "connection closed before ~a settled" verb))
       (vat-serve! (conn-vat c) ev)
       (loop)]
      [(eq? (car r) 'err) (error 'board-call "~a broke: ~a" verb (cdr r))]
      [else (cdr r)])))

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
  (connection-close! (board-conn a-board)))
