#lang racket/base
;; A small, friendly client for the rooms chat, built on pancake actors.
;;
;; On the connection API this is barely a layer: connect, fetch the directory by
;; name, ask it to open or enter a room (which hands back a live reference to
;; that room), spawn an inbox the room can call back, subscribe by handing it
;; that capability, and turn the room's callbacks into a sequence of messages.
;; Everything above it reads like an app:
;;
;;   (define d (room-connect "127.0.0.1:9099"))
;;   (define room (room-subscribe (directory-conn d) (dir-enter d "general") "alice"))
;;   (room-say room "hello")
;;   (for ([msg (in-room room)]) (printf "~a: ~a\n" (message-sender msg) (message-text msg)))
;;   (room-leave room)
;;
;; The Goblins verbs (`spawn`, `<-`, `on`, `methods`) work as they do in
;; Goblins; `connect`, `conn-fetch`, and `conn-send` do the peer/vat/import
;; plumbing. `dir-open` and `dir-enter` mirror the wire one-to-one and stay
;; strict; the friendly "enter, opening it if new" behavior is a CLI convenience
;; and lives in `client.rkt`. The room name is the directory's lookup key; the
;; room itself is the capability the directory returns.

(require "../../../../bindings/racket/pancake.rkt"
         "../../../../bindings/racket/pancake-iroh.rkt" ; IROH-REACH-* postures
         racket/string)
(provide room-connect directory-conn dir-open dir-enter dir-list dir-watch
         room-subscribe room-say room-leave in-room room-next
         (struct-out message))

;; Dial a transport-neutral rooms locator: an `ocapn://` URI goes over iroh, a
;; bare `host:port` over TCP. The room's wire is identical either way; only how a
;; member reaches it differs.
(define (dial locator)
  (cond
    ;; Rooms URIs carry direct-addresses, so dial with the explicit Direct
    ;; posture, reachability is required, never defaulted.
    [(string-contains? locator "://") (connect locator IROH-REACH-DIRECT)]
    [else
     (define colon (let loop ([i (- (string-length locator) 1)])
                     (cond [(< i 0) #f]
                           [(char=? (string-ref locator i) #\:) i]
                           [else (loop (- i 1))])))
     (unless colon
       (error 'room-connect "rooms locator is neither host:port nor an ocapn:// URI: ~a" locator))
     (connect (tcp-locator (substring locator 0 colon)
                           (string->number (substring locator (+ colon 1)))))]))

;; One line in the room. `system?` is #t for the room's own announcements (a
;; member joining, your welcome); otherwise `sender` is who said it.
(struct message (sender text system?) #:transparent)

(struct room (conn far queue) #:mutable)

;; Append a message to the room's pending queue (single-threaded: the consumer
;; pull pumps the connection, whose inbox actor enqueues here).
(define (enqueue! a-room msg)
  (set-room-queue! a-room (append (room-queue a-room) (list msg))))

;; The directory of rooms: the connection plus the directory's far reference.
;; `room-connect` dials and fetches it; `dir-open` / `dir-enter` send it the
;; strict verbs. `conn-send` is synchronous: it returns the room reference or
;; raises a broken-vow exception whose message carries the reason.
(struct directory (conn far))

(define (room-connect locator)
  (define c (dial locator))
  (directory c (conn-fetch c "directory")))

;; Create a new room and return its reference. Raises if the name is taken.
(define (dir-open d name)
  (conn-send (directory-conn d) (directory-far d) 'open name))

;; Return an existing room's reference. Raises if there is no such room.
(define (dir-enter d name)
  (conn-send (directory-conn d) (directory-far d) 'enter name))

;; The live rooms — the ones with people in them — as a list of `(name count)`
;; pairs. `list` and `watch` send the directory a list of `[name count]` pairs.
(define (dir-list d)
  (conn-send (directory-conn d) (directory-far d) 'list))

;; Follow the live room list: spawn an observer the directory calls back with
;; each change, register it, and return the current snapshot as a baseline.
;; `on-event` is called `(on-event kind name count)` on every open/close/count
;; change (`kind` is "opened", "closed", or "count").
(define (dir-watch d on-event)
  (define c (directory-conn d))
  (define observer
    (conn-spawn c
      (lambda (bcom)
        (methods
         [(notify kind name count)
          (on-event kind name count)
          (void)]))))
  (conn-send c (directory-far d) 'watch observer))

;; Subscribe to a room you already hold a reference to, on an open connection:
;; publish an inbox the room can call back and hand it that capability. The
;; welcome the room returns becomes the first line.
(define (room-subscribe c the-room nick)
  (define a-room (room c the-room '()))
  ;; The room calls this inbox back with every line; enqueue each one.
  (define inbox
    (conn-spawn c
      (lambda (bcom)
        (methods
         [(notify from text)
          (enqueue! a-room (message from text (string=? from "room")))
          (void)]))))
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
