#lang racket/base
;; A small, friendly client for the rooms chat, built on pancake actors.
;;
;; On the new connection API this is barely a layer: connect, fetch the room by
;; name, spawn an inbox the room can call back, subscribe by handing it that
;; capability, and turn the room's callbacks into a sequence of messages.
;; Everything above it reads like an app:
;;
;;   (define room (room-join "127.0.0.1" 9099 "alice"))
;;   (room-say room "hello")
;;   (for ([msg (in-room room)]) (printf "~a: ~a\n" (message-sender msg) (message-text msg)))
;;   (room-leave room)
;;
;; The Goblins verbs (`spawn`, `<-`, `on`, `methods`) are unchanged; `connect`
;; and `fetch` replace the peer/vat/import plumbing the old version wired by hand.

(require "../../../../bindings/racket/pancake.rkt")
(provide room-join room-say room-leave in-room room-next
         (struct-out message))

;; One line in the room. `system?` is #t for the room's own announcements (a
;; member joining, your welcome); otherwise `sender` is who said it.
(struct message (sender text system?) #:transparent)

(struct room (conn far queue) #:mutable)

;; Append a message to the room's pending queue (single-threaded: the consumer
;; pull pumps the connection, whose inbox actor enqueues here).
(define (enqueue! a-room msg)
  (set-room-queue! a-room (append (room-queue a-room) (list msg))))

;; Join the room: connect, fetch the room by name, publish an inbox the room can
;; call back, and subscribe by handing it that capability.
(define (room-join host port nick)
  (define c (connect host port))
  (define the-room (fetch c "room"))
  (define a-room (room c the-room '()))
  ;; The room calls this inbox back with every line; enqueue each one.
  (define inbox
    (conn-spawn c
      (lambda (bcom)
        (methods
         [(notify from text)
          (enqueue! a-room (message from text (string=? from "room")))
          (void)]))))
  ;; Subscribe; the welcome the room returns becomes our first line.
  (with-vat (conn-vat c)
    (define vow (<- the-room 'subscribe nick inbox))
    (on vow (lambda (welcome)
              (enqueue! a-room (message "room" (if (string? welcome) welcome "joined") #t)))))
  (async-flush! (conn-async c))
  a-room)

;; Say a line to everyone in the room.
(define (room-say a-room text)
  (with-vat (conn-vat (room-conn a-room)) (<- (room-far a-room) 'post text))
  (async-flush! (conn-async (room-conn a-room))))

;; Leave the room and close the connection.
(define (room-leave a-room)
  (connection-close! (room-conn a-room)))

;; Produce the next line, pumping the connection (and serving the vat, which fills
;; the queue) until one is available. Returns `eof` when the room hangs up.
(define (room-next a-room)
  (let loop ()
    (cond
      [(pair? (room-queue a-room))
       (define msg (car (room-queue a-room)))
       (set-room-queue! a-room (cdr (room-queue a-room)))
       msg]
      [else
       (define ev (async-next-event (conn-async (room-conn a-room))))
       (cond
         [(eof-object? ev) eof]
         [else (vat-serve! (conn-vat (room-conn a-room)) ev) (loop)])])))

;; The lines the room sends, as a sequence: `(for ([msg (in-room room)]) …)`.
(define (in-room a-room)
  (in-producer (lambda () (room-next a-room)) eof))
