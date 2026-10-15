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
;; strict. The friendly "enter, opening it if new" behavior is a CLI convenience
;; and lives in `client.rkt`. The room name is the directory's lookup key. The
;; room itself is the capability the directory returns.
;;
;; The wire grammar this reads, the verbs, the publication record, the watch and
;; room notification shapes, and the subscribe answer, comes from
;; `protocol-gen.rkt` beside this file, generated from
;; `tools/gen/rooms_protocol.zig` and shared with every sibling client. The
;; checks below are this language's own. What they check against is the table.

(require "protocol-gen.rkt"
         "../../../_demo/bindings.rkt"
         "../../../../bindings/racket/glowcap-tcp.rkt"
         "../../../../bindings/racket/glowcap-iroh.rkt" ; IROH-REACH-* postures
         racket/list
         racket/string)
(provide room-connect directory-session dir-open dir-enter dir-list dir-watch
         (struct-out room-info) (struct-out room-page)
         room-next/timeout
         room-subscribe room-say room-leave in-room room-next room-ended
         (struct-out message) (struct-out presence))

;; Dial a transport-neutral rooms locator: an `ocapn://` URI goes over iroh, a
;; bare `host:port` over TCP. The room's wire is identical either way. Only how a
;; member reaches it differs. A URI carrying direct-addresses dials those directly
;; (relay-less Direct). A node-id-only URI resolves the peer through discovery.
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
        #:profile 'glowcap))
     (values runtime (runtime-connect runtime loc))]
    [else
     (define-values (host port) (designator-host-port locator))
     (define runtime
       (open-runtime #:providers (list (tcp-provider))
                     #:profile 'glowcap))
     (values runtime (runtime-connect runtime (tcp-locator host port)))]))

;; ── Reading the generated grammar ─────────────────────────────────────────────
;; Every wire shape below is one of `protocol-gen.rkt`'s field lists, checked in
;; Racket's own vocabulary. A wire null decodes to `(void)` in this binding, so
;; that is the value a nullable field admits and the one `#f` never stands for.

;; Whether one wire value is of the declared type.
(define (admits-type? type value)
  (case type
    [(string) (string? value)]
    [(text) (non-empty-string? value)]
    [(natural) (exact-nonnegative-integer? value)]
    [(boolean) (boolean? value)]
    [(reference) (ref? value)]
    [(registration-id) (and (string? value) (regexp-match-exact? REGISTRATION-ID-RX value))]
    [(list) (list? value)]
    [(any) #t]
    [else #f]))

;; Whether one wire value fits its declared field: a null where the field admits
;; one, a member of the enumeration where it has one, and then the type.
(define (admits-field? f value)
  (cond
    [(void? value) (field-nullable? f)]
    [(and (pair? (field-values f)) (not (member value (field-values f)))) #f]
    [else (admits-type? (field-type f) value)]))

;; Whether a wire list is exactly the declared fields, one value each.
(define (fields-fit? fields row)
  (and (list? row)
       (= (length row) (length fields))
       (for/and ([f (in-list fields)] [v (in-list row)]) (admits-field? f v))))

;; Where a named field sits in its list, so a validated row is read by name.
(define (field-at fields name)
  (for/first ([f (in-list fields)] [at (in-naturals)] #:when (string=? (field-name f) name)) at))

;; The watch notification a tag names, or #f when the directory sent one this
;; grammar does not declare.
(define (watch-kind-for tag)
  (for/first ([k (in-list WATCH-KINDS)] #:when (equal? (watch-kind-tag k) tag)) k))

;; The room tail a tag names, or #f when the tag is not one.
(define (room-tail-for tag)
  (for/first ([t (in-list ROOM-TAILS)] #:when (equal? (room-tail-tag t) tag)) t))

;; Whether a room line's sender, display text, and arguments after the tag are
;; what the tail declares.
(define (tail-fits? tail from text after-tag)
  (define trailing (room-tail-trailing tail))
  (and (case (room-tail-sender tail)
         [(room) (string=? from ROOM-SENDER)]
         [(member) (not (string=? from ROOM-SENDER))]
         [else #t])
       (case (room-tail-text tail)
         [(empty) (string=? text "")]
         [(nonempty) (non-empty-string? text)]
         [else #t])
       (list? after-tag)
       (>= (length after-tag) (length trailing))
       (let-values ([(fixed more) (split-at after-tag (length trailing))])
         (and (fields-fit? trailing fixed)
              (let ([rest-type (room-tail-rest tail)])
                (if rest-type
                    (for/and ([v (in-list more)]) (admits-type? rest-type v))
                    (null? more)))))))

;; One line in the room. `system?` is #t for the room's own announcements (a
;; member joining, your welcome). Otherwise `sender` is who said it. `presence` is
;; a `presence` struct on a membership-change system line, or #f.
(struct message (sender text system? presence) #:transparent)

;; A membership change a system line carries as structured wire args, not prose.
;; `kind` is the tail's tag, `names` the members it is about (everyone here on a
;; roster, the one nick otherwise), and `effect` what it does to them: 'arrive,
;; 'depart, or 'stay.
(struct presence (kind names effect) #:transparent)

;; The structured presence a room line carries after its display text,
;; `(notify "room" text "roster" name …)` or `(notify "room" text kind nick)`,
;; when the tag names a presence tail and the arguments are its shape. Ordinary
;; chat lines carry none, and a tail that does not fit reads as none, so the
;; line still draws.
(define (read-presence from text rest)
  (define tail (and (pair? rest) (string? (car rest)) (room-tail-for (car rest))))
  (and tail
       (room-tail-effect tail)
       (tail-fits? tail from text (cdr rest))
       (let*-values ([(trailing) (room-tail-trailing tail)]
                     [(fixed more) (split-at (cdr rest) (length trailing))])
         (presence (room-tail-tag tail)
                   (append (for/list ([f (in-list trailing)]
                                      [v (in-list fixed)]
                                      #:when (string=? (field-name f) "name"))
                             v)
                           (if (room-tail-rest tail) more '()))
                   (room-tail-effect tail)))))

;; ── The inbox mailbox ─────────────────────────────────────────────────────────
;; The inbox actor runs inside a foreign behavior callback, which Racket CS
;; runs in atomic mode: nothing there may deschedule the thread. An
;; async-channel's put takes an internal lock that can, so the room's line
;; queue is this atomic-safe mailbox instead: a lock-free box push
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
;; parks until one lands. A number returns #f when none arrives in time. The
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
;; `membership` is the seat the room answered with, and every later membership
;; verb goes there. The room reference is not retained after subscribe.
;; `ended-box` holds the reason once the room has ended this membership.
(struct room (runtime session membership queue ended-box [serve #:mutable]))

;; The directory of rooms: the connection plus the directory's far reference.
;; `room-connect` dials and fetches it; `dir-open` / `dir-enter` send it the
;; strict verbs. `session-send` is synchronous: it returns the room reference or
;; raises a broken-vow exception whose message carries the reason.
(struct directory (runtime session far))

;; One exact directory publication, the generated `PUBLICATION-FIELDS` in wire
;; order. A foreign room's count is #f: unknown is distinct from an empty room.
;; `offers` is #f for a room the public cannot enter by name.
(struct room-info (name count id kind origin proof offers) #:transparent)

;; The struct is that record positionally, so a validated row applies straight
;; into the constructor and a field the table adds fails here first.
(unless (equal? (map field-name PUBLICATION-FIELDS)
                '("name" "count" "id" "kind" "origin" "proof" "offers"))
  (error 'room-client "room-info does not follow the generated publication record"))

;; A wire null decodes to `(void)` in this binding, so that is the shape an
;; unknown count and an absent offer arrive in. The struct keeps #f for both,
;; the value its readers already use for unknown.
(define (wire-room fields)
  (and (fields-fit? PUBLICATION-FIELDS fields)
       (apply room-info (for/list ([v (in-list fields)]) (if (void? v) #f v)))))

(define (wire-rooms who raw)
  (unless (list? raw) (error who "directory answered a room list that is not a list"))
  (for/list ([row (in-list raw)])
    (or (wire-room row) (error who "directory answered a malformed room publication"))))

;; One page of the live room list. `next` is the cursor that asks for the
;; page after it, or #f on the last page.
(struct room-page (rooms next) #:transparent)

(define (wire-room-page raw)
  (unless (fields-fit? LIST-PAGE-FIELDS raw)
    (error 'dir-list "directory answered a malformed room page"))
  (define next (list-ref raw (field-at LIST-PAGE-FIELDS "next")))
  (room-page (wire-rooms 'dir-list (list-ref raw (field-at LIST-PAGE-FIELDS "rooms")))
             (if (void? next) #f next)))

;; The atomic rooms, registrations, and omission-count baseline a watcher folds
;; its deltas into.
(define (wire-watch-rooms raw)
  (unless (fields-fit? WATCH-SNAPSHOT-FIELDS raw)
    (error 'dir-watch "directory answered a malformed watch snapshot"))
  (define registrations (list-ref raw (field-at WATCH-SNAPSHOT-FIELDS "registrations")))
  (unless (for/and ([row (in-list registrations)])
            (fields-fit? REGISTRATION-ROW-FIELDS row))
    (error 'dir-watch "directory answered malformed registration rows"))
  (wire-rooms 'dir-watch (list-ref raw (field-at WATCH-SNAPSHOT-FIELDS "rooms"))))

;; Validate every watcher shape the grammar declares. Member and truncation
;; changes are valid but carry no room row for this small terminal client to
;; display, so they read as #f.
(define (wire-watch-event args)
  (unless (and (pair? args) (string? (car args)))
    (error 'dir-watch "directory sent a malformed watch notification"))
  (define tag (car args))
  (define kind (watch-kind-for tag))
  (unless kind (error 'dir-watch "directory sent an unknown watch event ~a" tag))
  (unless (fields-fit? (watch-kind-args kind) (cdr args))
    (error 'dir-watch "directory sent a malformed ~a watch notification"
           (if (watch-kind-room? kind) "room" tag)))
  (and (watch-kind-room? kind) (cons tag (wire-room (cdr args)))))

(define (room-connect locator)
  (define-values (runtime c) (dial locator))
  (directory runtime c (session-fetch c DIRECTORY)))

;; Create a new room and return its reference. Raises if the name is taken.
(define (dir-open d name)
  (session-send (directory-session d) (directory-far d) OPEN name))

;; Return an existing room's reference. Raises if there is no such room.
(define (dir-enter d name)
  (session-send (directory-session d) (directory-far d) ENTER name))

;; One page of the live local and foreign room publications. Pass the page's
;; `next` to read the page after it.
(define (dir-list d [cursor #f])
  (wire-room-page
   (apply session-send (directory-session d) (directory-far d) LIST-PUBLICATIONS
          (if cursor (list cursor) '()))))

;; Follow the live room list: spawn an observer the directory calls back with
;; each change, register it, and return the current snapshot as a baseline.
;; `on-event` is called with the event kind and exact publication record.
(define (dir-watch d on-event)
  (define c (directory-session d))
  (define observer
    (session-spawn c
      (lambda (_bcom)
        (lambda (verb . args)
          (unless (eq? verb NOTIFY)
            (error 'dir-watch "watch inbox has no method ~a" verb))
          (define event (wire-watch-event args))
          (when event (on-event (car event) (cdr event)))
          (void)))))
  (wire-watch-rooms (session-send c (directory-far d) WATCH-PUBLICATIONS observer)))

;; Subscribe to a room you already hold a reference to, on an open connection:
;; spawn an inbox actor the room can call back, hand it over, and start a
;; background `session-serve` thread that keeps the connection pumped: the room's
;; notifies run the inbox actor inside that serve, which enqueues each line
;; onto the room's channel for `room-next` to read.
;; One `notify` on the room inbox: enqueue the line for `room-next`. `notify` is
;; variadic, a system line appends structured presence args after its text, so
;; this reads the args by hand rather than through the fixed-arity `methods`
;; sugar. A `membershipEnded` tail is the room's last word to this inbox: the
;; reason is the line, `ended-box` keeps it, and the mailbox closes so the line
;; stream ends after what it already holds. Its shape is held strictly, the way
;; a watch notification's is.
(define (inbox-notify! queue ended-box args)
  (define from (if (and (pair? args) (string? (car args))) (car args) "?"))
  (define text (if (and (pair? args) (pair? (cdr args)) (string? (cadr args))) (cadr args) ""))
  (define rest (if (and (pair? args) (pair? (cdr args))) (cddr args) '()))
  (cond
    [(and (pair? rest) (equal? (car rest) MEMBERSHIP-ENDED))
     (unless (tail-fits? (room-tail-for MEMBERSHIP-ENDED) from text (cdr rest))
       (error 'inbox "membership-ended notify takes one reason"))
     (mailbox-put! queue (message from text #t #f))
     (set-box! ended-box text)
     (mailbox-close! queue)]
    [else
     (mailbox-put! queue
                   (message from text (string=? from ROOM-SENDER)
                            (read-presence from text rest)))]))

(define (room-subscribe d the-room nick)
  (define c (directory-session d))
  (define queue (make-mailbox))
  (define ended-box (box #f))
  ;; The room calls this inbox back with every line.
  (define inbox
    (session-spawn c
      (lambda (bcom)
        (lambda (method . args)
          (unless (eq? method NOTIFY) (error 'inbox "object has no method: ~a" method))
          (inbox-notify! queue ended-box args)
          (void)))))
  ;; Subscribe, handing the room our inbox. The room answers the generated
  ;; `SUBSCRIBE-ANSWER-FIELDS`, the membership seat with its kind and the topic
  ;; authority; the welcome and roster arrive as our first `notify`, not as part
  ;; of that answer.
  (define answer (session-send c the-room SUBSCRIBE nick inbox))
  (unless (fields-fit? SUBSCRIBE-ANSWER-FIELDS answer)
    (error 'room-subscribe "the room answered subscribe without one membership capability"))
  (define seat (list-ref answer (field-at SUBSCRIBE-ANSWER-FIELDS "seat")))
  (define a-room (room (directory-runtime d) c seat queue ended-box #f))
  ;; Serve until the room hangs up, then mark the end of the line stream.
  (set-room-serve! a-room
                   (thread (lambda ()
                             (with-handlers ([(lambda (_) #t) (lambda (_e) (void))])
                               (session-serve c))
                             (mailbox-close! queue))))
  a-room)

;; Say a line to everyone in the room, on the membership seat. `session-send`
;; drives to the room's answer, so a refusal (an observer seat, a line past the
;; room's limit) raises here with the wire reason, as `dir-open` does. The serve
;; thread keeps the reads meanwhile: this thread parks on the host's progress
;; event until the answer lands, the pump's reader-gate contract, proved by the
;; concurrent-pump case in the binding's `test/zig-smoke/actors-and-sessions.rkt`.
;; The answer is the line's own reference, which this client never edits or
;; withdraws. `MEMBERSHIP-VERBS` is where the grammar says `post` answers at all,
;; so that is what picks `session-send` over `session-tell` here.
(let ([replies (assq POST MEMBERSHIP-VERBS)])
  (unless (and replies (cdr replies))
    (error 'room-client "the grammar no longer says post answers")))

(define (room-say a-room text)
  (session-send (room-session a-room) (room-membership a-room) POST text)
  (void))

;; The reason the room gave when it ended this membership, or #f while it stands.
(define (room-ended a-room)
  (unbox (room-ended-box a-room)))

;; Leave the room and close the connection. The serve thread ends with it.
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

  ;; One value of a field's declared type, so a shape test is written from the
  ;; table rather than from a literal that can drift away from it.
  (define (sample-field f)
    (if (pair? (field-values f))
        (car (field-values f))
        (case (field-type f)
          [(string) ""]
          [(text) "ada"]
          [(natural) 1]
          [(boolean) #t]
          [(list) '()]
          [(registration-id) "00000000-0000-4000-8000-000000000001"]
          [else "x"])))

  (test-case "malformed watch callbacks are refused"
    (check-exn #rx"malformed room watch"
               (lambda () (wire-watch-event '("opened" "only-a-name"))))
    (check-exn #rx"unknown watch event"
               (lambda () (wire-watch-event '("renamed" "lobby"))))
    (check-exn #rx"malformed registered watch"
               (lambda () (wire-watch-event '("registered" "ada" 1 "not-a-registration"))))
    (check-false
     (wire-watch-event
      '("registered" "ada" 1 "00000000-0000-4000-8000-000000000001"))))

  (test-case "every watch kind the table declares is read, and a room kind carries a room"
    (for ([k (in-list WATCH-KINDS)])
      (define args (cons (watch-kind-tag k)
                         (for/list ([f (in-list (watch-kind-args k))]) (sample-field f))))
      (define event (wire-watch-event args))
      (if (watch-kind-room? k)
          (check-equal? (car event) (watch-kind-tag k))
          (check-false event))))

  (test-case "a watch snapshot is the declared baseline"
    (check-equal? (wire-watch-rooms (list '() '() 0)) '())
    (check-exn #rx"malformed watch snapshot"
               (lambda () (wire-watch-rooms (list '() '()))))
    (check-exn #rx"malformed registration rows"
               (lambda () (wire-watch-rooms (list '() (list (list "ada" "not-a-registration")) 0)))))

  (test-case "a room page is the declared rows and cursor"
    (check-equal? (wire-room-page (list '() (void))) (room-page '() #f))
    (check-equal? (room-page-next (wire-room-page (list '() "local:#garden"))) "local:#garden")
    (check-exn #rx"malformed room page" (lambda () (wire-room-page '())))
    (check-exn #rx"malformed room page" (lambda () (wire-room-page (list '() 256)))))

  (test-case "a wire null is an unknown count and an absent offer, not a malformed record"
    (define foreign (wire-room (list "lobby" (void) "id-1" "foreign" "ocapn://x" "session" "participant")))
    (check-equal? (room-info-count foreign) #f)
    (check-equal? (room-info-offers foreign) "participant")
    (define closed (wire-room (list "lobby" 2 "id-2" "local" "" "local" (void))))
    (check-equal? (room-info-count closed) 2)
    (check-equal? (room-info-offers closed) #f)
    (check-false (wire-room (list "lobby" #f "id-3" "local" "" "local" (void))))
    (check-false (wire-room (list "lobby" 2 "id-4" "local" "" "local" "steward")))
    ;; `kind` and `proof` are enumerations in the table, so an off-table value
    ;; is a malformed record here too.
    (check-false (wire-room (list "lobby" 2 "id-5" "annex" "" "local" (void))))
    (check-false (wire-room (list "lobby" 2 "id-6" "local" "" "hearsay" (void)))))

  (test-case "every presence tail the table declares reads back as presence"
    (for ([t (in-list ROOM-TAILS)] #:when (room-tail-effect t))
      (define trailing (room-tail-trailing t))
      (define given (for/list ([f (in-list trailing)]) (sample-field f)))
      (define text (if (eq? (room-tail-text t) 'empty) "" "hello"))
      (define p (read-presence ROOM-SENDER text (cons (room-tail-tag t) given)))
      (check-pred presence? p (room-tail-tag t))
      (when (presence? p)
        (check-equal? (presence-kind p) (room-tail-tag t))
        (check-equal? (presence-effect p) (room-tail-effect t))
        (check-equal? (presence-names p)
                      (for/list ([f (in-list trailing)] [v (in-list given)]
                                 #:when (string=? (field-name f) "name"))
                        v)))))

  (test-case "a tail that does not fit its declared shape is not presence"
    (check-equal? (presence-names (read-presence ROOM-SENDER "" '("roster" "ada" "bob")))
                  '("ada" "bob"))
    (check-equal? (presence-effect (read-presence ROOM-SENDER "bob left" '("leave" "bob"))) 'depart)
    (check-false (read-presence "ada" "hi" '("join" "bob")))       ; only the room says join
    (check-false (read-presence ROOM-SENDER "hi" '("typing" "ada" #t))) ; typing carries no text
    (check-false (read-presence ROOM-SENDER "hi" '("line" 7)))     ; a line is not presence
    (check-false (read-presence ROOM-SENDER "hi" '("waved" "ada"))))

  (test-case "a membership-ended notice is the last line and ends the stream"
    (define queue (make-mailbox))
    (define ended (box #f))
    (inbox-notify! queue ended (list ROOM-SENDER "kicked by the steward" MEMBERSHIP-ENDED))
    (define final-line (mailbox-get/timeout queue 0))
    (check-equal? (message-text final-line) "kicked by the steward")
    (check-true (message-system? final-line))
    (check-equal? (unbox ended) "kicked by the steward")
    (check-eq? (mailbox-get/timeout queue 0) eof)
    (check-exn #rx"membership-ended notify takes one reason"
               (lambda () (inbox-notify! (make-mailbox) (box #f) '("room" "" "membershipEnded"))))
    (check-exn #rx"membership-ended notify takes one reason"
               (lambda () (inbox-notify! (make-mailbox) (box #f) '("ada" "bye" "membershipEnded"))))
    (check-exn #rx"membership-ended notify takes one reason"
               (lambda () (inbox-notify! (make-mailbox) (box #f)
                                         '("room" "bye" "membershipEnded" "and one more")))))

  (test-case "the subscribe answer is the declared membership capability"
    ;; The seat is a live reference, which a unit test has none of, so what is
    ;; pinned here is the refusal and where the seat is read from.
    (check-false (fields-fit? SUBSCRIBE-ANSWER-FIELDS (list "seat" "observer" (void))))
    (check-equal? (field-at SUBSCRIBE-ANSWER-FIELDS "seat") 0)))
