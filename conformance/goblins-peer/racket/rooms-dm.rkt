#lang racket/base
;; rooms-dm.rkt — direct messages in a glowcap rooms chat, held by a real
;; Spritely Goblins vat.
;;
;; A room introduces two members and then gets out of the way: the message
;; itself travels on a connection between the two of them, and the room carries
;; none of it. That is OCapN's three-party handoff (ADR-0009), and it is the same
;; conversation whichever implementation is standing at each corner. This module
;; is the Goblins member's whole half of it, so a vat is as reachable by direct
;; message as any glowcap peer in the same room.
;;
;; Three roles meet at one message, and this vat plays two of them:
;;
;;   as the exporter   another member asks the room to introduce it, and the room
;;                     hands on the inbox this vat offered for that member as a
;;                     `desc:handoff-give`. The member redeems it by dialing this
;;                     vat, and the message arrives on the inbox minted for them
;;                     alone. That is where a direct message gets its sender: no
;;                     message names anybody, and the inbox it came in on is the
;;                     answer.
;;
;;   as the recipient  this vat asks the room to introduce it to a member, and
;;                     Goblins redeems the give the room answers with by dialing
;;                     that member directly. Whether the dial lands is the
;;                     member's transport: an address or an endpoint key this
;;                     vat's netlayer speaks is reachable, and a member reachable
;;                     only through glowcap's own relay is not. A member reached
;;                     over a keyed transport is a further limit that
;;                     `docs/boundaries.md` states. Whatever this direction can
;;                     reach, a member that messaged us first is always
;;                     answerable, over the connection its message arrived on.
;;
;; The room is the gifter and this module never plays it.
;;
;; Everything here takes a vat turn, because every line of it either spawns an
;; actor or sends a message. Call `dm-register`, `dm-say`, and `dm-forget` from
;; inside `(vat 'run …)` or from a handler.

(require goblins
         goblins/actor-lib/methods
         "rooms-client.rkt"
         racket/string)

(provide spawn-dm-member
         dm-register
         dm-say
         dm-forget
         dm-notify
         max-dm-inboxes)

;; How many direct-message inboxes this vat will hold. Each one is an actor and a
;; row that lives as long as the process, and the peer asking is the one who
;; chose the name, so the count needs a ceiling that peer cannot argue with.
;; `MAX_DM_INBOXES` in `apps/rooms/lib/limits.ts` and `max_dm_inboxes` in
;; `cli/app/rooms_peer/common.zig` are the same bound for the other two peers.
(define max-dm-inboxes 256)

;; A member's direct-message half, spawned once per connection to a room.
;;
;;   `directory`   the room directory this member registered with. Every
;;                 introduction is asked for over it.
;;   `nick`        the name to claim. The room grants it, and it is the name
;;                 other members' inboxes are minted for.
;;   `locator`     the locator other peers reach this vat by, which
;;                 `connect-directory` answers alongside the directory. The room
;;                 repeats it to everyone it introduces, and they dial it.
;;   `on-message`  called `(from text)` for each direct message that arrives.
;;   `on-sent`     called `(peer text)` only after that peer's inbox fulfills
;;                 the eventual send.
;;   `on-status`   called `(text)` with a line worth showing a person: a name
;;                 granted, a peer becoming reachable.
;;   `on-error`    called `(what err)` when something this member asked for was
;;                 refused, where `what` is a short phrase naming the ask.
;;
;; Answers the member handle every procedure below takes. It is local state and
;; is never handed to anybody: the capability the room holds is a separate inbox
;; this actor spawns, which answers `notify` and nothing else.
(define (spawn-dm-member directory
                         #:nick nick
                         #:locator locator
                         #:on-message on-message
                         #:on-sent [on-sent void]
                         #:on-status [on-status void]
                         #:on-error [on-error void])
  (spawn ^dm-member directory nick locator on-message on-sent on-status on-error))

;; Claim `nick` with the room, so this vat appears in the roster of members that
;; can be direct-messaged and an introduction to it can be asked for.
(define (dm-register member) ($ member 'register))

;; Deliver one direct message to `peer`, opening the line to them if this is the
;; first. Completion arrives on `on-sent` or `on-error` after the far inbox
;; settles the eventual send.
(define (dm-say member peer text) ($ member 'say peer text))

;; Forget everything held for `peer`, because they have left. The name is the
;; room's to grant again, and whoever holds it next is somebody else, so an inbox
;; or a reply route kept across that change would carry a stranger's messages
;; into the conversation that had been theirs.
(define (dm-forget member peer registration-id) ($ member 'forget peer registration-id))

;; Hand this member one `notify` the room pushed on some *other* inbox — a
;; watcher's, say — so a caller that already has its own room callback does not
;; need a second registration to hear about members arriving and leaving. The
;; member's own register inbox reaches this directly.
(define (dm-notify member event name registration-id [opening #f]) ($ member 'heard event name registration-id opening))

;; A name as the room keys it. The room matches nicks case-insensitively, so a
;; member's own tables have to as well or an inbox filed under one casing is
;; never found under another.
(define (peer-key peer) (string-downcase peer))

;; The directory mints one UUID for each live nickname generation. It is
;; correlation, not authority, but accepting any other shape would let a stale
;; or malformed notification retarget the tables below.
(define registration-id-rx
  #px"(?i:^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$)")

(define (registration-id? value)
  (and (string? value) (regexp-match-exact? registration-id-rx value)))

(define (opening? value)
  (and (string? value) (positive? (string-length value))
       (<= (for/sum ([character (in-string value)])
             (if (> (char->integer character) #xffff) 2 1))
           128)))

(define (^dm-member _bcom directory nick locator on-message on-sent on-status on-error)
  ;; The current registration for each peer name. Every other table is keyed by
  ;; this generation rather than by a nickname a later member may reuse.
  (define registrations (make-hash))
  ;; The inbox minted for each registration. It is minted once and used in both
  ;; directions: the room hands it to that peer as the give they redeem, and a
  ;; message this vat sends carries the same actor as the reply capability, so a
  ;; peer's answer lands in the same handler their first message did.
  (define inboxes (make-hash))
  ;; The peer's own inbox, once an introduction has been redeemed. Reaching it
  ;; means a direct connection to them is open.
  (define lines (make-hash))
  ;; The reply capability a peer handed us with a message of theirs. It rides
  ;; their connection, which is the only way to answer a peer that opened no
  ;; listener of its own.
  (define back-channels (make-hash))
  ;; Lines waiting on an introduction the room refused as pending: the member has
  ;; been asked for an inbox, and `notify("introducible", peer)` says it arrived.
  (define waiting (make-hash))
  ;; Peers the room called introducible while nothing was waiting on them.
  ;;
  ;; The wakeup can outrun the refusal it belongs to. One `introduce` makes the
  ;; room do two things: ask the member for an inbox, and refuse us as pending.
  ;; The member may offer before that refusal reaches us, so `introducible`
  ;; arrives, finds an empty queue, and would be dropped, leaving the line parked
  ;; with nothing left to wake it. Remembering the peer here lets the refusal ask
  ;; again straight away instead of parking. `apps/rooms/lib/room/client.ts` keeps
  ;; the same memo against the same race.
  (define introducible-seen (make-hash))
  (define opening-sequence 0)
  (define (new-opening)
    (set! opening-sequence (add1 opening-sequence))
    (format "racket:~a" opening-sequence))
  (define registered? (box #f))

  ;; The capability the room calls this member back on. Separate from the member
  ;; itself, because the room is handed it and must not thereby be able to make
  ;; this vat send anybody a message.
  (define register-inbox
    (spawn (lambda (_bcom)
             (methods
              [(notify event . rest)
               (heard event
                      (if (pair? rest) (car rest) "")
                      (if (and (pair? rest) (pair? (cdr rest))) (cadr rest) "")
                      (if (>= (length rest) 3) (caddr rest) #f))]))))

  ;; The inbox one named peer's messages arrive on. `peer` is closed over at mint
  ;; time and never read off a message, because the room hands this inbox to that
  ;; peer alone: a sender that named itself could name somebody else.
  (define (mint-inbox peer registration-id)
    (spawn
     (lambda (_bcom)
       (methods
        [(directReady reply)
         (hash-set! back-channels registration-id reply)
         (void)]
        [(dm text . rest)
         (define reply (if (pair? rest) (car rest) #f))
         (when reply (hash-set! back-channels registration-id reply))
         (on-message peer text)]
        ;; A peer's typing flag rides the same route as its messages. It carries
        ;; no line and is not a transcript, so a vat that shows none of it still
        ;; has to answer rather than break the sender's send.
        [(typing . _rest) (void)]))))

  (define (inbox-for peer registration-id)
    (or (hash-ref inboxes registration-id #f)
        (and (< (hash-count inboxes) max-dm-inboxes)
             (let ([inbox (mint-inbox peer registration-id)])
               (hash-set! inboxes registration-id inbox)
               inbox))))

  ;; This actor receives every opening for one exact registration. Each offer
  ;; names the requested exchange; forgetting a registration retires its cached
  ;; actor before the next holder of that name can receive an offer.
  (define (offer peer registration-id opening)
    (cond
      [(string=? (peer-key peer) (peer-key nick)) (void)]
      [else
       (offer-minted peer registration-id opening)]))

  (define (offer-minted peer registration-id opening)
    (cond
      [(inbox-for peer registration-id)
       => (lambda (inbox)
            (on (<- directory 'offerInbox peer registration-id opening inbox)
                void
                #:catch (lambda (err) (on-error (format "offer ~a an inbox" peer) err))))]
      [else
       (on-error (format "offer ~a an inbox" peer)
                 (format "already holding ~a inboxes" max-dm-inboxes))]))

  ;; Send one line on a route to `peer` that is already open. Answers whether
  ;; there was one, so a caller can open the introduced line when there was not.
  ;;
  ;; A back-channel is preferred over a line we opened: it reaches a peer that
  ;; cannot be dialed at all, and a peer that messaged us has handed us one.
  (define (say-on-open-route registration-id peer text)
    (define back (hash-ref back-channels registration-id #f))
    (define line (hash-ref lines registration-id #f))
    (cond
      [back
       (deliver peer text (<- back 'dm text) (lambda () (hash-remove! back-channels registration-id)))
       #t]
      [line
       ;; The reply capability is the inbox minted for this peer, so their answer
       ;; arrives where their first message would have. At the inbox ceiling
       ;; there is none to offer and the line is one-way.
       (define reply (inbox-for peer registration-id))
       (deliver peer text
                (if reply (<- line 'dm text reply) (<- line 'dm text))
                (lambda () (hash-remove! lines registration-id)))
       #t]
      [else #f]))

  ;; Watch one delivery. A route that fails is dropped, so the next line re-opens
  ;; rather than failing in the same place forever.
  (define (deliver peer text vow drop-route)
    (on vow
        (lambda (_answer) (on-sent peer text))
        #:catch (lambda (err)
                  (drop-route)
                  (on-error (format "direct message to ~a" peer) err))))

  ;; Open the introduced line to `peer` and send `text` on it. The room answers
  ;; with the inbox that member offered for us, as a give; Goblins redeems it by
  ;; dialing the member directly, so the send below is already off-room.
  (define (introduce-then-say peer registration-id text opening)
    (define key (cons registration-id opening))
    (on (<- directory 'introduce peer registration-id opening)
        (lambda (their-inbox)
          (hash-set! lines registration-id their-inbox)
          (void (say-on-open-route registration-id peer text)))
        #:catch
        (lambda (err)
          (cond
            ;; First contact. The room has just asked the member for an inbox for
            ;; us, and says so again when it arrives, so the line is held rather
            ;; than lost. Unless it already said so: the wakeup can arrive before
            ;; this refusal does, and there will not be a second one, so ask again
            ;; now rather than park on a notice that has already been spent.
            [(equal? (room-error-code err) "introduction-pending")
             (cond
               [(hash-ref introducible-seen key #f)
                (hash-remove! introducible-seen key)
                (introduce-then-say peer registration-id text opening)]
               [else
                (hash-update! waiting key (lambda (held) (cons text held)) '())])]
            [else (on-error (format "reach ~a" peer) err)]))))

  (define (say peer text)
    (define name-key (peer-key peer))
    (define registration-id (hash-ref registrations name-key #f))
    (cond
      [(string=? name-key (peer-key nick))
       (on-error "direct message yourself" "a member cannot direct-message itself")]
      [(not (unbox registered?))
       (on-error (format "direct message to ~a" peer) "not-registered: no name yet")]
      [(not registration-id)
       (on-error (format "direct message to ~a" peer) "peer-offline: no current registration")]
      [else
       (unless (say-on-open-route registration-id peer text)
         (introduce-then-say peer registration-id text (new-opening)))]
      ))

  (define (forget peer registration-id)
    (define name-key (peer-key peer))
    (when (equal? (hash-ref registrations name-key #f) registration-id)
      (hash-remove! registrations name-key))
    (hash-remove! inboxes registration-id)
    (hash-remove! lines registration-id)
    (hash-remove! back-channels registration-id)
    (for ([key (in-list (hash-keys waiting))] #:when (equal? (car key) registration-id))
      (hash-remove! waiting key))
    ;; The next holder of this name is somebody else, and must not inherit a
    ;; notice the last one earned.
    (for ([key (in-list (hash-keys introducible-seen))]
          #:when (equal? (car key) registration-id))
      (hash-remove! introducible-seen key)))

  ;; One `notify` the room pushed, whichever inbox it arrived on.
  (define (heard event name registration-id [opening #f])
    (when (member event '("registered" "unregistered" "mintInboxFor" "introducible"))
      (unless (and (string? name) (registration-id? registration-id))
        (error 'rooms-dm "~a carried an invalid member registration" event)))
    (when (member event '("mintInboxFor" "introducible"))
      (unless (opening? opening)
        (error 'rooms-dm "~a carried an invalid direct opening" event)))
    (define name-key (peer-key name))
    (cond
      [(equal? event "registered")
       (define prior (hash-ref registrations name-key #f))
       (when (and prior (not (equal? prior registration-id))) (forget name prior))
       (hash-set! registrations name-key registration-id)
       (cond
         ;; Our own name granted. Everything a caller wanted to do before this
         ;; needed it, so nothing is attempted until it lands. It is said once
         ;; however many times it is heard: the room tells the register inbox
         ;; directly and tells every watcher as well, and one member may be both.
         [(string=? (peer-key name) (peer-key nick))
          (unless (unbox registered?)
            (set-box! registered? #t)
            (on-status (format "the room granted you the name ~a" nick)))]
         ;; An opening request names the exact inbox exchange.
         [else (void)])]
      [(equal? event "unregistered")
       (when (equal? (hash-ref registrations name-key #f) registration-id)
         (forget name registration-id)
         (when (string=? name-key (peer-key nick)) (set-box! registered? #f))
         (unless (string=? name-key (peer-key nick))
           (on-status (format "~a is no longer reachable by direct message" name))))]
      ;; A member has asked to be introduced to us and the room holds no inbox of
      ;; ours for them.
      [(equal? event "mintInboxFor")
       (define prior (hash-ref registrations name-key #f))
       (when (and prior (not (equal? prior registration-id))) (forget name prior))
       (hash-set! registrations name-key registration-id)
       (offer name registration-id opening)]
      ;; A member we were told to wait for has offered an inbox. Whatever was
      ;; typed while waiting goes now, in the order it was typed.
      [(equal? event "introducible")
       (when (equal? (hash-ref registrations name-key #f) registration-id)
         (define key (cons registration-id opening))
         (define held (reverse (hash-ref waiting key '())))
         (hash-remove! waiting key)
         ;; Nothing parked yet means the refusal this notice belongs to is still on
         ;; its way, so the notice is remembered for it rather than dropped.
         (if (null? held)
             (hash-set! introducible-seen key #t)
             (for ([text (in-list held)]) (introduce-then-say name registration-id text opening))))]
      [else (void)]))

  (define member-self
    (methods
     [(register)
      (on (<- directory 'register nick locator register-inbox)
          void
          #:catch (lambda (err) (on-error (format "register as ~a" nick) err)))]
     [(say peer text) (say peer text)]
     [(forget peer registration-id) (forget peer registration-id)]
     [(heard event name registration-id opening) (heard event name registration-id opening)]))

  member-self)

(module+ test
  ;; What is checked here is the naming rule the tables key on, which is pure.
  ;; The rest of this module is sends and spawns, so a vat and a live room are
  ;; what cover it: `zig build goblins-rooms-dm` is that cover, and a green run
  ;; here says nothing about it.
  (require rackunit)

  ;; The room matches nicks case-insensitively, so an inbox filed under one
  ;; casing is found under any other. Getting this wrong mints a second inbox for
  ;; a peer already holding one, and their reply lands in a handler nobody reads.
  (check-equal? (peer-key "Alice") (peer-key "alice"))
  (check-equal? (peer-key "ALICE") "alice")
  (check-not-equal? (peer-key "alice") (peer-key "alicia")))
