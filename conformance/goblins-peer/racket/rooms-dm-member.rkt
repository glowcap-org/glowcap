#lang racket/base
;; rooms-dm-member.rkt — a Spritely Goblins vat sitting in a glowcap rooms chat,
;; reachable by direct message and able to start one.
;;
;; This is the scripted half of the Goblins direct-message member;
;; `rooms-chat.rkt` is the half a person types in. Both hold the same
;; conversation through `rooms-dm.rkt`, so what a build step proves here is what
;; a person gets there.
;;
;; It joins the room, claims its name for direct messages, and then stays up
;; until it is killed, narrating what it hears one line at a time:
;;
;;   DM READY <locator>          registered; this is where members reach it
;;   DM FROM <peer>: <text>      a direct message arrived, off-room
;;   DM SENT <peer>              a direct message of its own has gone out
;;   DM SEEN <peer>              a member became reachable by direct message
;;
;; Every message it receives is answered on the connection that message arrived
;; on, using the reply capability the sender handed it. That is the only way to
;; answer a peer that opened no listener of its own, and a browser tab is exactly
;; that peer.
;;
;; Usage:
;;   racket rooms-dm-member.rkt
;;     [--reply-prefix <text>] [--dm <peer>] [--dm-text <text>]
;;     [--local-port <n>]
;;     <locator> <room> <nick>
;;
;; The options come first, because that is where Racket's command-line reader
;; stops looking for them.
;;
;; With `--dm`, it plays the other role too: it waits for that member to become
;; reachable and then asks the room to introduce it, redeems the give by dialing
;; that member directly, and sends `--dm-text`. Whether the dial lands is the
;; member's transport, so the caller picks a member this vat's netlayer speaks
;; to; `docs/boundaries.md` states the further limit on a keyed one.
;;
;; Set `GLOWCAP_ROOMS_VIZ_URL` to a live timeline endpoint and this vat publishes its own
;; trace there, so each direct-message connection appears beside the room's own
;; sessions, and disappears when the conversation is closed from either end.

(require goblins
         goblins/actor-lib/methods
         "rooms-client.rkt"
         "rooms-dm.rkt"
         "trace-publish.rkt"
         racket/cmdline
         racket/string)

(file-stream-buffer-mode (current-output-port) 'line)
(file-stream-buffer-mode (current-error-port) 'line)

(define reply-prefix (make-parameter "got your DM: "))
(define dm-peer (make-parameter #f))
(define dm-text (make-parameter "hello from a goblins vat, privately"))
(define local-port-arg (make-parameter #f))

(define-values (locator start-room nick)
  (command-line
   #:program "rooms-dm-member.rkt"
   #:once-each
   [("--reply-prefix") text "what to put in front of a message when answering it"
                       (reply-prefix text)]
   [("--dm") peer "a member to direct-message once they are reachable"
             (dm-peer peer)]
   [("--dm-text") text "the line to send that member"
                  (dm-text text)]
   [("--local-port") port "the TCP port this vat's own netlayer binds"
                     (local-port-arg port)]
   #:args (locator room nick)
   (values locator room nick)))

(define local-port (local-port-argument (local-port-arg)))

(define (say . parts) (printf "~a~n" (apply format parts)))

(define publisher
  (let ([endpoint (trace-endpoint-from-env)])
    (and endpoint
         (make-trace-publisher
          endpoint
          #:self-label nick
          #:on-error (lambda (err) (eprintf "! trace: ~a~n" (exn-message err)))))))

(define member-vat (make-vat))

;; The member this vat was told to message, once it has been messaged. A vat that
;; sent its line and then heard that member register again must not send twice.
(define greeted (box #f))

(member-vat
 'run
 (lambda ()
   (define-values (directory-vow our-locator)
     (connect-directory locator
                        #:local-port local-port
                        #:session-trace (and publisher (trace-publisher-sink publisher))))
   (on
    directory-vow
    (lambda (directory)
      ;; The direct-message half. Each message that arrives is answered straight
      ;; back over its own connection, so this vat is a partner in a
      ;; conversation rather than a mailbox.
      (define dm
        (spawn-dm-member
         directory
         #:nick nick
         #:locator our-locator
         #:on-message
         (lambda (from text)
           (say "DM FROM ~a: ~a" from text)
           ;; `dm` is the very member being defined here. The handler runs on a
           ;; later turn, by which time the definition has landed.
           (dm-say dm from (string-append (reply-prefix) text)))
         #:on-sent (lambda (peer _text) (say "DM SENT ~a" peer))
         #:on-status (lambda (text) (say "* ~a" text))
         #:on-error (lambda (what err) (say "! could not ~a: ~v" what err))))
      (dm-register dm)

      ;; Watching the directory is what turns a member appearing into an inbox
      ;; offered for them, so their first message needs no extra round trip. It
      ;; is also how this vat learns that the member it was told to message has
      ;; arrived.
      (define watcher
        (spawn (lambda (_bcom)
                 (methods
                  [(notify event . rest)
                   (define name (if (pair? rest) (car rest) ""))
                   (define registration-id
                     (if (and (pair? rest) (pair? (cdr rest)) (pair? (cddr rest)))
                         (caddr rest)
                         ""))
                   (dm-notify dm event name registration-id)
                   (when (and (equal? event "registered")
                              (not (string-ci=? name nick)))
                     (say "DM SEEN ~a" name)
                     (when (and (dm-peer)
                                (string-ci=? name (dm-peer))
                                (not (unbox greeted)))
                       (set-box! greeted #t)
                       (dm-say dm name (dm-text))))]))))
      (on (<- directory 'watch watcher)
          void
          #:catch (lambda (err) (say "! could not watch the directory: ~v" err)))

      ;; Being in the room as well as reachable off it: a member list is what a
      ;; person clicks to start a direct message, and that list is the room's.
      (define room-inbox (spawn-inbox (lambda (_from _text _rest) (void))))
      (enter-or-open directory
                     start-room
                     (lambda (room)
                       (on (<- room 'subscribe nick room-inbox)
                           (lambda (_ack) (say "DM READY ~a" our-locator))
                           #:catch (lambda (err) (say "! subscribe: ~v" err))))
                     (lambda (err) (say "! neither enter nor open: ~v" err))))
    #:catch
    (lambda (err)
      (say "! could not reach the directory at ~a: ~v" locator err)
      (exit 1)))))

;; Stay up until killed. The vat's own threads carry the conversation; this one
;; only keeps the process alive so they can.
(semaphore-wait (make-semaphore 0))
