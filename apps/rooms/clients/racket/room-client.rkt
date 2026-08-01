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
;;   (define room (room-subscribe (directory-session d) (dir-enter d "general") "alice"))
;;   (room-say room "hello")
;;   (for ([msg (in-room room)]) (printf "~a: ~a\n" (message-sender msg) (message-text msg)))
;;   (room-leave room)
;;
;; The Goblins verbs (`spawn`, `<-`, `on`, `methods`) work as they do in
;; Goblins; `connect`, `session-fetch`, and `session-send` do the peer/vat/import
;; plumbing. `dir-open` and `dir-enter` mirror the wire one-to-one and stay
;; strict; the friendly "enter, opening it if new" behavior is a CLI convenience
;; and lives in `client.rkt`. The room name is the directory's lookup key; the
;; room itself is the capability the directory returns.

(require "../../../_demo/bindings.rkt"
         "../../../../bindings/racket/pancake-iroh.rkt" ; IROH-REACH-* postures
         racket/string)
(provide room-connect directory-session dir-open dir-enter dir-list dir-watch
         room-subscribe room-say room-leave in-room room-next
         (struct-out message) (struct-out presence))

;; Dial a transport-neutral rooms locator: an `ocapn://` URI goes over iroh, a
;; bare `host:port` over TCP. The room's wire is identical either way; only how a
;; member reaches it differs. A URI carrying direct-addresses dials those directly
;; (relay-less Direct); a node-id-only URI resolves the peer through discovery.
(define (dial locator)
  (cond
    [(string-contains? locator "://")
     (define loc (parse-locator locator))
     (unless (string=? (locator-transport loc) TRANSPORT-IROH)
       (error 'dial (format "rooms expected an iroh ocapn:// URI, got \"~a\": ~a"
                            (locator-transport loc) locator)))
     (define hints (hash-ref (locator-hints loc) HINT-DIRECT-ADDRESSES ""))
     (define reach (if (> (string-length hints) 0) IROH-REACH-DIRECT IROH-REACH-DISCOVERY))
     (connect locator reach)]
    [else
     (define-values (host port) (designator-host-port locator))
     (connect (tcp-locator host port))]))

;; One line in the room. `system?` is #t for the room's own announcements (a
;; member joining, your welcome); otherwise `sender` is who said it. `presence` is
;; a `presence` struct on a membership-change system line, or #f.
(struct message (sender text system? presence) #:transparent)

;; A membership change a system line carries as structured wire args, not prose:
;; the roster on arrival (`kind` "roster", `names` everyone here), or a join/leave
;; (`kind` "join"/"leave", `names` the one nick).
(struct presence (kind names) #:transparent)

;; The structured presence a room line carries after its display text —
;; `(notify "room" text "roster" name …)` or `(notify "room" text kind nick)`.
;; Ordinary chat lines carry none, so this returns #f.
(define (read-presence rest)
  (cond
    [(null? rest) #f]
    [(equal? (car rest) "roster") (presence "roster" (filter string? (cdr rest)))]
    [(and (member (car rest) '("join" "leave")) (pair? (cdr rest)) (string? (cadr rest)))
     (presence (car rest) (list (cadr rest)))]
    [else #f]))

;; ── The inbox mailbox ─────────────────────────────────────────────────────────
;; The inbox actor runs inside a foreign behavior callback, which Racket CS
;; runs in atomic mode: nothing there may deschedule the thread. An
;; async-channel's put takes an internal lock that can, so the room's line
;; queue is this atomic-safe mailbox instead — a lock-free box push
;; (`box-cas!`) plus a `semaphore-post`, both legal in atomic mode. The reader
;; side (`room-next`, an ordinary thread) waits on the semaphore and drains
;; the cell in arrival order through its own `pending` buffer.
(struct mailbox (cell sema pending))

(define (make-mailbox) (mailbox (box '()) (make-semaphore 0) (box '())))

;; Safe from inside a behavior callback: push and post, nothing waits.
(define (mailbox-put! mb v)
  (define cell (mailbox-cell mb))
  (let loop ()
    (define old (unbox cell))
    (unless (box-cas! cell old (cons v old)) (loop)))
  (semaphore-post (mailbox-sema mb)))

;; Reader-side only: the next value in arrival order, parked until one lands.
(define (mailbox-get mb)
  (define pending (mailbox-pending mb))
  (let loop ()
    (cond
      [(pair? (unbox pending))
       (define items (unbox pending))
       (set-box! pending (cdr items))
       (car items)]
      [else
       (semaphore-wait (mailbox-sema mb))
       ;; Take everything pushed so far; a batch taken on one post leaves the
       ;; later posts to land on an already-empty cell, hence the loop.
       (define cell (mailbox-cell mb))
       (define taken
         (let take ()
           (define old (unbox cell))
           (if (box-cas! cell old '()) old (take))))
       (set-box! pending (reverse taken))
       (loop)])))

;; `queue` is the mailbox the inbox actor (run inside the connection's serve
;; thread's feed) feeds and `room-next` reads; `serve` is that background
;; thread, so `room-leave` can be sure the pump winds down with the connection.
(struct room (session far queue [serve #:mutable]))

;; The directory of rooms: the connection plus the directory's far reference.
;; `room-connect` dials and fetches it; `dir-open` / `dir-enter` send it the
;; strict verbs. `session-send` is synchronous: it returns the room reference or
;; raises a broken-vow exception whose message carries the reason.
(struct directory (session far))

(define (room-connect locator)
  (define c (dial locator))
  (directory c (session-fetch c "directory")))

;; Create a new room and return its reference. Raises if the name is taken.
(define (dir-open d name)
  (session-send (directory-session d) (directory-far d) 'open name))

;; Return an existing room's reference. Raises if there is no such room.
(define (dir-enter d name)
  (session-send (directory-session d) (directory-far d) 'enter name))

;; The live rooms — the ones with people in them — as a list of `(name count)`
;; pairs. `list` and `watch` send the directory a list of `[name count]` pairs.
(define (dir-list d)
  (session-send (directory-session d) (directory-far d) 'list))

;; Follow the live room list: spawn an observer the directory calls back with
;; each change, register it, and return the current snapshot as a baseline.
;; `on-event` is called `(on-event kind name count)` on every open/close/count
;; change (`kind` is "opened", "closed", or "count").
(define (dir-watch d on-event)
  (define c (directory-session d))
  (define observer
    (session-spawn c
      (lambda (bcom)
        (methods
         [(notify kind name count)
          (on-event kind name count)
          (void)]))))
  (session-send c (directory-far d) 'watch observer))

;; Subscribe to a room you already hold a reference to, on an open connection:
;; spawn an inbox actor the room can call back, hand it over, and start a
;; background `session-serve` thread that keeps the connection pumped — the room's
;; notifies run the inbox actor inside that serve, which enqueues each line
;; onto the room's channel for `room-next` to read.
(define (room-subscribe c the-room nick)
  (define queue (make-mailbox))
  (define a-room (room c the-room queue #f))
  ;; The room calls this inbox back with every line; enqueue each one. `notify` is
  ;; variadic — a system line appends structured presence args after its text — so
  ;; this dispatches by hand rather than through the fixed-arity `methods` sugar.
  (define inbox
    (session-spawn c
      (lambda (bcom)
        (lambda (method . args)
          (unless (eq? method 'notify) (error 'inbox "object has no method: ~a" method))
          (define from (if (and (pair? args) (string? (car args))) (car args) "?"))
          (define text (if (and (pair? args) (pair? (cdr args)) (string? (cadr args))) (cadr args) ""))
          (define rest (if (and (pair? args) (pair? (cdr args))) (cddr args) '()))
          (mailbox-put! queue (message from text (string=? from "room") (read-presence rest)))
          (void)))))
  ;; Subscribe, handing the room our inbox. Success is the resolution; the room
  ;; delivers the welcome and roster as our first `notify`, not as a return value.
  (session-send c the-room 'subscribe nick inbox)
  ;; Serve until the room hangs up, then mark the end of the line stream.
  (set-room-serve! a-room
                   (thread (lambda ()
                             (with-handlers ([(lambda (_) #t) (lambda (_e) (void))])
                               (session-serve c))
                             (mailbox-put! queue eof))))
  a-room)

;; Say a line to everyone in the room. The serve thread owns the reads; the
;; flush puts this thread's post on the wire now.
(define (room-say a-room text)
  (define c (room-session a-room))
  (session-tell c (room-far a-room) 'post text)
  (session-flush! c))

;; Leave the room and close the connection; the serve thread ends with it.
(define (room-leave a-room)
  (session-close! (room-session a-room))
  (define t (room-serve a-room))
  (when t (sync/timeout 1 (thread-dead-evt t))))

;; The next line the room sent, parked until one arrives. Returns `eof` when
;; the room hangs up.
(define (room-next a-room)
  (mailbox-get (room-queue a-room)))

;; The lines the room sends, as a sequence: `(for ([msg (in-room room)]) …)`.
(define (in-room a-room)
  (in-producer (lambda () (room-next a-room)) eof))
