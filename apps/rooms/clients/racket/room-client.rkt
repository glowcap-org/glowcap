#lang racket/base
;; A small, friendly client for the rooms chat, built on glowcap actors.
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
         "../../../../bindings/racket/glowcap-tcp.rkt"
         "../../../../bindings/racket/glowcap-iroh.rkt" ; IROH-REACH-* postures
         racket/list
         racket/match
         racket/string)
(provide room-connect directory-session dir-open dir-enter dir-list dir-watch
         (struct-out room-info)
         room-next/timeout
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
     (define runtime
       (open-runtime
        #:providers (list (iroh-provider (make-iroh-config reach)))
        #:profile 'native))
     (values runtime (runtime-connect runtime loc))]
    [else
     (define-values (host port) (designator-host-port locator))
     (define runtime
       (open-runtime #:providers (list (tcp-provider))
                     #:profile 'native))
     (values runtime (runtime-connect runtime (tcp-locator host port)))]))

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
;; the cell in arrival order through its own `pending` buffer. The count shares
;; the same CAS as the list, so two callback threads cannot both admit the slot
;; at the ceiling.
(define MAX-UNREAD-LINES 256)
(struct mailbox-buffer (count newest closed?) #:transparent)
(struct mailbox (cell sema pending))

(define (make-mailbox)
  (mailbox (box (mailbox-buffer 0 '() #f)) (make-semaphore 0) (box '())))

;; Safe from inside a behavior callback: push and post, nothing waits.
(define (mailbox-put! mb v)
  (define cell (mailbox-cell mb))
  (let loop ()
    (define old (unbox cell))
    (when (mailbox-buffer-closed? old) (error 'inbox "the room inbox is closed"))
    (when (>= (mailbox-buffer-count old) MAX-UNREAD-LINES)
      (error 'inbox "the room retained its maximum ~a unread lines" MAX-UNREAD-LINES))
    (define next
      (mailbox-buffer (add1 (mailbox-buffer-count old))
                      (cons v (mailbox-buffer-newest old))
                      #f))
    (unless (box-cas! cell old next) (loop)))
  (semaphore-post (mailbox-sema mb)))

(define (mailbox-close! mb)
  (define cell (mailbox-cell mb))
  (let loop ()
    (define old (unbox cell))
    (unless (or (mailbox-buffer-closed? old)
                (box-cas! cell old
                          (mailbox-buffer (mailbox-buffer-count old)
                                          (mailbox-buffer-newest old)
                                          #t)))
      (loop)))
  (semaphore-post (mailbox-sema mb)))

;; Reader-side only: the next value in arrival order. `timeout-seconds` of #f
;; parks until one lands; a number returns #f when none arrives in time. The
;; timed wait syncs on the mailbox's own semaphore, so a caller with a
;; deadline never has to park a worker thread and kill it: a thread killed
;; mid-port-read can leave the port's lock held, and the process then hangs
;; in exit's own flush of that port.
(define (mailbox-get/timeout mb timeout-seconds)
  (define pending (mailbox-pending mb))
  (let loop ()
    (cond
      [(pair? (unbox pending))
       (define items (unbox pending))
       (set-box! pending (cdr items))
       (car items)]
      [(let ([state (unbox (mailbox-cell mb))])
         (and (mailbox-buffer-closed? state)
              (zero? (mailbox-buffer-count state))))
       eof]
      [(sync/timeout timeout-seconds (mailbox-sema mb))
       ;; Take everything pushed so far; a batch taken on one post leaves the
       ;; later posts to land on an already-empty cell, hence the loop.
       (define cell (mailbox-cell mb))
       (define taken
         (let take ()
           (define old (unbox cell))
           (if (box-cas! cell old
                         (mailbox-buffer 0 '() (mailbox-buffer-closed? old)))
               (mailbox-buffer-newest old)
               (take))))
       (set-box! pending (reverse taken))
       (loop)]
      [else #f])))

(define (mailbox-get mb) (mailbox-get/timeout mb #f))

;; `queue` is the mailbox the inbox actor (run inside the connection's serve
;; thread's feed) feeds and `room-next` reads; `serve` is that background
;; thread, so `room-leave` can be sure the pump winds down with the connection.
(struct room (runtime session far queue [serve #:mutable]))

;; The directory of rooms: the connection plus the directory's far reference.
;; `room-connect` dials and fetches it; `dir-open` / `dir-enter` send it the
;; strict verbs. `session-send` is synchronous: it returns the room reference or
;; raises a broken-vow exception whose message carries the reason.
(struct directory (runtime session far))

;; One exact directory publication. A foreign room's count is #f: unknown is
;; distinct from an empty room.
(struct room-info (name count id kind origin proof offers) #:transparent)

(define (wire-room fields)
  (and (list? fields)
       (= (length fields) 7)
       (let ([name (list-ref fields 0)]
             [count (list-ref fields 1)]
             [id (list-ref fields 2)]
             [kind (list-ref fields 3)]
             [origin (list-ref fields 4)]
             [proof (list-ref fields 5)]
             [offers (list-ref fields 6)])
         (and (string? name) (string? id) (string? kind)
              (string? origin) (string? proof)
              (or (not count) (exact-nonnegative-integer? count))
              (or (not offers) (member offers '("observer" "participant") string=?))
              (room-info name count id kind origin proof offers)))))

(define (wire-rooms who raw)
  (unless (list? raw) (error who "directory answered a room list that is not a list"))
  (for/list ([row (in-list raw)])
    (or (wire-room row) (error who "directory answered a malformed room publication"))))

(define (wire-watch-rooms raw)
  (match raw
    [(list rooms registrations (? exact-nonnegative-integer?))
     (unless (and (list? registrations)
                  (for/and ([row (in-list registrations)])
                    (match row
                      [(list (? non-empty-string?) (? non-empty-string?)) #t]
                      [_ #f])))
       (error 'dir-watch "directory answered malformed registration rows"))
     (wire-rooms 'dir-watch rooms)]
    [_ (error 'dir-watch "directory answered a malformed watch snapshot")]))

(define registration-id-rx
  #px"(?i:^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$)")

(define (registration-id? value)
  (and (string? value) (regexp-match-exact? registration-id-rx value)))

;; Validate every watcher shape. Member and truncation changes are valid but
;; carry no room row for this small terminal client to display.
(define (wire-watch-event args)
  (match args
    [(list (and kind (or "opened" "closed" "count")) fields ...)
     (define entry (wire-room fields))
     (unless entry (error 'dir-watch "directory sent a malformed room watch notification"))
     (cons kind entry)]
    [(list (or "registered" "unregistered")
           (? non-empty-string?)
           (? exact-nonnegative-integer?)
           (? registration-id?))
     #f]
    [(list "truncated" (? exact-nonnegative-integer?)) #f]
    [_ (error 'dir-watch "directory sent a malformed watch notification")]))

(define (room-connect locator)
  (define-values (runtime c) (dial locator))
  (directory runtime c (session-fetch c "directory")))

;; Create a new room and return its reference. Raises if the name is taken.
(define (dir-open d name)
  (session-send (directory-session d) (directory-far d) 'open name))

;; Return an existing room's reference. Raises if there is no such room.
(define (dir-enter d name)
  (session-send (directory-session d) (directory-far d) 'enter name))

;; The exact live local and foreign room publications.
(define (dir-list d)
  (wire-rooms 'dir-list
              (session-send (directory-session d) (directory-far d) 'listPublications)))

;; Follow the live room list: spawn an observer the directory calls back with
;; each change, register it, and return the current snapshot as a baseline.
;; `on-event` is called with the event kind and exact publication record.
(define (dir-watch d on-event)
  (define c (directory-session d))
  (define observer
    (session-spawn c
      (lambda (_bcom)
        (lambda (verb . args)
          (unless (eq? verb 'notify)
            (error 'dir-watch "watch inbox has no method ~a" verb))
          (define event (wire-watch-event args))
          (when event (on-event (car event) (cdr event)))
          (void)))))
  (wire-watch-rooms (session-send c (directory-far d) 'watchPublications observer)))

;; Subscribe to a room you already hold a reference to, on an open connection:
;; spawn an inbox actor the room can call back, hand it over, and start a
;; background `session-serve` thread that keeps the connection pumped — the room's
;; notifies run the inbox actor inside that serve, which enqueues each line
;; onto the room's channel for `room-next` to read.
(define (room-subscribe d the-room nick)
  (define c (directory-session d))
  (define queue (make-mailbox))
  (define a-room (room (directory-runtime d) c the-room queue #f))
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
                             (mailbox-close! queue))))
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
  (when t (sync/timeout 1 (thread-dead-evt t)))
  (runtime-close! (room-runtime a-room)))

;; The next line the room sent, parked until one arrives. Returns `eof` when
;; the room hangs up.
(define (room-next a-room)
  (mailbox-get (room-queue a-room)))

;; `room-next` under a deadline: the next line, or #f when none arrives
;; within `timeout-seconds`.
(define (room-next/timeout a-room timeout-seconds)
  (mailbox-get/timeout (room-queue a-room) timeout-seconds))

;; The lines the room sends, as a sequence: `(for ([msg (in-room room)]) …)`.
(define (in-room a-room)
  (in-producer (lambda () (room-next a-room)) eof))

(module+ test
  (require rackunit)

  (test-case "unread lines stop at the named ceiling"
    (define mb (make-mailbox))
    (for ([at (in-range MAX-UNREAD-LINES)]) (mailbox-put! mb at))
    (check-exn #rx"256 unread lines" (lambda () (mailbox-put! mb 'one-more)))
    (check-equal? (mailbox-buffer-count (unbox (mailbox-cell mb))) MAX-UNREAD-LINES))

  (test-case "malformed watch callbacks are refused"
    (check-exn #rx"malformed room watch"
               (lambda () (wire-watch-event '("opened" "only-a-name"))))
    (check-false
     (wire-watch-event
      '("registered" "ada" 1 "00000000-0000-4000-8000-000000000001")))))
