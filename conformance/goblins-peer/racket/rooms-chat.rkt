#lang racket/base
;; rooms-chat.rkt — sit in a pancake chat room as a real Spritely Goblins vat
;; and talk.
;;
;; This is the Goblins counterpart of `apps/rooms/clients/deno/chat.ts`: it
;; enters a room, prints every line as it arrives, and posts whatever you type.
;; Lines that start with "/" are commands, not chat:
;;
;;   /list            the rooms with people in them, right now
;;   /open <name>     open a new room and move into it
;;   /enter <name>    move into an existing room
;;   /leave           leave the current room (stay connected)
;;   /dms             the members who can be direct-messaged
;;   /dm <nick> <…>   send one member a direct message, off-room
;;   /help            this list
;;
;; Press Ctrl-D to quit.
;;
;; A direct message does not travel through the room. The room introduces the two
;; of you and then carries none of it: the line goes over a connection between
;; this vat and that member, opened by dialing the locator they registered.
;; Anyone who messages you first can be answered over the connection their
;; message arrived on. Starting one yourself works when the member registered a
;; locator this vat can dial: TCP for the testing adapter, or iroh when this
;; repository's Goblins iroh netlayer is installed for the vat.
;;
;;   racket -y rooms-chat.rkt 127.0.0.1:9099 general goblins-carol
;;
;; The locator is whatever the room server announced. A `host:port` reaches a
;; TCP server, and an `ocapn://<node-id>.iroh?direct-addresses=…` URI reaches one
;; over iroh's encrypted QUIC; the transport in the locator picks the netlayer,
;; so nothing else on the command line changes:
;;
;;   racket -y rooms-chat.rkt "$(curl -s http://localhost:8000/locator)" \
;;     general goblins-carol
;;
;; The trailing local-port argument is a TCP one — it is the port this vat's own
;; netlayer binds — and an iroh locator refuses it, because an iroh vat is
;; reached by its endpoint key rather than by an address.
;;
;; The wire protocol lives in `rooms-client.rkt`, next door. What is worth
;; watching while you type is that this member is not a pancake peer: the room
;; settles this one session on the OCapN v1.0 Syrup baseline while every pancake
;; member on the same server keeps pancake's native profile. Start the server
;; with `--viz` and the ocapnviz viewer draws that split live.
;;
;; Set `PANCAKE_ROOMS_VIZ_URL` to that endpoint's address and this vat publishes its own
;; trace there too, so the sessions it holds appear beside every other peer's:
;;
;;   PANCAKE_ROOMS_VIZ_URL=ws://127.0.0.1:9300/ racket -y rooms-chat.rkt \
;;     127.0.0.1:9099 general goblins-carol
;;
;; With the variable unset the vat holds no publishing socket and sends nothing.

(require goblins
         goblins/actor-lib/methods
         "rooms-client.rkt"
         "rooms-dm.rkt"
         "trace-publish.rkt"
         racket/set
         racket/string)

(file-stream-buffer-mode (current-output-port) 'line)

(define argv (current-command-line-arguments))
(when (< (vector-length argv) 3)
  (eprintf "usage: rooms-chat.rkt <locator> <room> <nick> [local-port]~n")
  (exit 2))

(define locator (vector-ref argv 0))
(define start-room (vector-ref argv 1))
(define nick (vector-ref argv 2))
(define local-port
  (local-port-argument (and (> (vector-length argv) 3) (vector-ref argv 3))))

(define chat-vat (make-vat))

;; Where this vat publishes its own trace, or #f when no endpoint is configured.
;; The nickname rides along as the display name for this vat's own endpoint; the
;; identity a viewer merges on stays the netlayer's designator.
(define publisher
  (let ([endpoint (trace-endpoint-from-env)])
    (and endpoint
         (make-trace-publisher
          endpoint
          #:self-label nick
          #:on-error (lambda (err) (eprintf "! trace: ~a~n" (exn-message err)))))))

;; What the typing thread needs to reach from outside the vat: the directory and
;; the room this member is currently in. Both are written on the vat's turn
;; thread and read on the terminal's, which is what a box is for here. The values
;; are capability references, handed straight back into `chat-vat 'run`.
(define directory-box (box #f))
(define room-box (box #f))

;; The inbox is spawned once and handed to every room this member enters, so a
;; room switch does not mint a fresh export for the same person.
(define inbox-box (box #f))

;; This member's direct-message half, once the directory has answered, and the
;; members it can currently reach. Both are written on the vat's turn thread and
;; read on the terminal's, which is what the boxes are for.
(define dm-box (box #f))
(define reachable-box (box (set)))

;; Raised once the opening dial has either put us in a room or given up. The
;; terminal loop waits on it before reading a line, so a typed command always has
;; a directory to reach. It is also what lets a piped script behave the way a
;; person does, typing after the banner rather than into a vat that has not
;; dialed yet.
(define opened (make-semaphore 0))
(define connected (box #f))

(define (say . parts)
  (printf "~a~n" (apply format parts)))

;; Print one line the room pushed. A system line comes from "room"; anything else
;; is a person, and our own lines come back around like everyone else's.
(define (print-line from text presence)
  (cond
    ;; A typing flag is ephemeral presence, tagged at the third argument. It
    ;; carries no text and does not belong in a transcript.
    [(and (pair? presence) (equal? (car presence) "typing")) (void)]
    [(string=? from "room") (say "* ~a" text)]
    [else (say "<~a> ~a" from text)]))

;; Subscribe to `room` and make it the current one. The room answers `subscribe`
;; with a bare ack; the welcome and the roster arrive on the inbox.
(define (enter-room room name #:then [then void])
  (on (<- room 'subscribe nick (unbox inbox-box))
      (lambda (_ack)
        (set-box! room-box room)
        (say "* you are in ~a" name)
        (then))
      #:catch (lambda (err)
                (say "! could not join ~a: ~v" name err)
                (then))))

;; Move to another room on the same connection: ask the directory for the room
;; first, and only give up the one we are in once it has answered.
;;
;; The order matters twice. A directory that refuses (`/enter` naming no live
;; room) leaves you where you were instead of nowhere. And the leave still
;; happens before the new subscribe, which is what makes re-entering a room you
;; are already in harmless: the room grants one membership per connection rather
;; than per reference, so a leave sent afterwards would drop the membership just
;; made. Nothing can be typed into the gap, because the terminal reads the next
;; line only once this whole command has settled.
(define (switch-room verb name then)
  (on (<- (unbox directory-box) verb name)
      (lambda (room)
        (define current (unbox room-box))
        (set-box! room-box #f)
        (when current (on (<- current 'leave) void #:catch void))
        (enter-room room name #:then then))
      #:catch (lambda (err)
                (say "! ~a ~a: ~v" verb name err)
                (then))))

(define (opening-settled)
  (semaphore-post opened))

;; Take up the direct-message half of the rooms protocol: claim this nick with
;; the directory so other members can be introduced to us, and watch the
;; directory so the roster of who can be reached stays current. Watching is what
;; makes an offer arrive before the ask, so a member's first direct message to us
;; lands without the extra round trip a cold introduction costs.
(define (start-direct-messages directory our-locator)
  (define dm
    (spawn-dm-member directory
                     #:nick nick
                     #:locator our-locator
                     #:on-message (lambda (from text) (say "(dm) <~a> ~a" from text))
                     #:on-status (lambda (text) (say "* ~a" text))
                     #:on-error (lambda (what err) (say "! could not ~a: ~v" what err))))
  (set-box! dm-box dm)
  (dm-register dm)
  (define watcher
    (spawn (lambda (_bcom)
             (methods
              [(notify event . rest)
               (define name (if (pair? rest) (car rest) ""))
               (when (member event '("registered" "unregistered"))
                 (set-box! reachable-box
                           (if (string=? event "registered")
                               (set-add (unbox reachable-box) name)
                               (set-remove (unbox reachable-box) name))))
               (dm-notify dm event name)]))))
  (on (<- directory 'watch watcher)
      void
      #:catch (lambda (err) (say "! could not watch the directory: ~v" err))))

(chat-vat
 'run
 (lambda ()
   (set-box! inbox-box (spawn-inbox print-line))
   (define-values (directory-vow our-locator)
     (connect-directory locator
                        #:local-port local-port
                        #:session-trace (and publisher (trace-publisher-sink publisher))))
   (on directory-vow
       (lambda (directory)
         (set-box! directory-box directory)
         (set-box! connected #t)
         (say "* connected to the rooms directory at ~a as ~a" locator nick)
         (say "* other members reach you for direct messages at ~a" our-locator)
         (start-direct-messages directory our-locator)
         (enter-or-open directory
                        start-room
                        (lambda (room) (enter-room room start-room #:then opening-settled))
                        (lambda (err)
                          (say "! could not enter ~a: ~v" start-room err)
                          (opening-settled))))
       #:catch
       (lambda (err)
         (say "! could not reach the directory at ~a: ~v" locator err)
         (opening-settled)))))

(semaphore-wait opened)
(unless (unbox connected) (exit 1))

;; How long one typed line may take before the terminal gives up on it and reads
;; the next. Finite, so a server that has stopped answering leaves you with a
;; usable terminal instead of a wedged one.
(define command-seconds 15.0)

;; Run one typed line's work in the vat and wait for it to settle before reading
;; the next. `body` receives a `done` thunk to call when its vow has answered.
;; The wait is what makes the terminal behave the way a person expects: `/open`
;; has finished joining before the next line is read, so a line never lands in
;; the room you just left. Lines the room pushes are separate turns and keep
;; printing throughout.
(define (typed-command body)
  (define done (make-semaphore 0))
  (chat-vat 'run (lambda () (body (lambda () (semaphore-post done)))))
  (unless (sync/timeout command-seconds done)
    (say "! the room did not answer in ~a seconds" command-seconds)))

(define (show-rooms)
  (typed-command
   (lambda (done)
     (on (<- (unbox directory-box) 'list)
         (lambda (rooms)
           (if (null? rooms)
               (say "* no rooms have people in them yet")
               (for ([room (in-list rooms)])
                 (say "* ~a (~a)" (car room) (cadr room))))
           (done))
         #:catch (lambda (err) (say "! list: ~v" err) (done))))))

(define (post text)
  (define room (unbox room-box))
  (if room
      (typed-command
       (lambda (done)
         (on (<- room 'post text)
             (lambda (_posted) (done))
             #:catch (lambda (err) (say "! post: ~v" err) (done)))))
      (say "! you are not in a room; /enter <name> first")))

(define (leave-room)
  (define room (unbox room-box))
  (cond
    [room
     (set-box! room-box #f)
     (typed-command
      (lambda (done)
        (on (<- room 'leave)
            (lambda (_left) (say "* you left the room") (done))
            #:catch (lambda (err) (say "! leave: ~v" err) (done)))))]
    [else (say "! you are not in a room")]))

;; The members the directory says can be direct-messaged, ourselves excluded:
;; there is nobody to introduce us to.
(define (show-reachable)
  (define others
    (sort (for/list ([name (in-set (unbox reachable-box))]
                     #:unless (string-ci=? name nick))
            name)
          string<?))
  (if (null? others)
      (say "* nobody else can be direct-messaged yet")
      (for ([name (in-list others)]) (say "* ~a" name))))

;; Send one direct message. It settles no vow here, because a first message to a
;; member takes an introduction and a dial and the terminal should not sit on
;; either; whatever comes of it arrives on the member's own status and error
;; lines.
(define (direct-message peer text)
  (define dm (unbox dm-box))
  (if dm
      (chat-vat 'run (lambda () (dm-say dm peer text)))
      (say "! not connected yet")))

(define (help)
  (say "* /list, /open <name>, /enter <name>, /leave, /dms, /dm <nick> <text>, /help; Ctrl-D quits"))

(define (run-command line)
  (define parts (string-split line))
  (define verb (car parts))
  (define rest (if (null? (cdr parts)) #f (string-join (cdr parts) " ")))
  (cond
    [(string=? verb "/list") (show-rooms)]
    [(string=? verb "/help") (help)]
    [(string=? verb "/leave") (leave-room)]
    [(string=? verb "/dms") (show-reachable)]
    [(string=? verb "/dm")
     (define who (and (pair? (cdr parts)) (cadr parts)))
     (define text (and who (string-join (cddr parts) " ")))
     (cond
       [(and who text (positive? (string-length text)))
        (direct-message who text)
        ;; Shown as sent right away. A direct message has no echo — the room
        ;; never sees it — so nothing else would ever put it on screen, and a
        ;; line that could not be delivered says so on its own error line.
        (say "(dm) <~a> ~a" nick text)]
       [else (say "! /dm takes a member and a line, as in: /dm alice hello")])]
    [(and (string=? verb "/open") rest)
     (typed-command (lambda (done) (switch-room 'open rest done)))]
    [(and (string=? verb "/enter") rest)
     (typed-command (lambda (done) (switch-room 'enter rest done)))]
    [else (say "! unknown command ~a" verb)]))

;; The terminal loop. Reading stdin here and handing each line to the vat keeps
;; the vat's turn thread free to deliver the room's callbacks while you type.
(let loop ()
  (define line (read-line))
  (unless (eof-object? line)
    (define text (string-trim line))
    (cond
      [(string=? text "") (void)]
      [(string-prefix? text "/") (run-command text)]
      [else (post text)])
    (loop)))

(say "* bye")
(when publisher (stop-trace-publisher publisher))
(exit 0)
