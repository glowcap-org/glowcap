#lang racket/base
;; rooms-member.rkt — one Spritely Goblins vat joining a pancake rooms chat,
;; saying one thing, and leaving.
;;
;; This is the scripted half of the Goblins rooms member; `rooms-chat.rkt` is
;; the half a person types in. Both speak the rooms wire protocol through
;; `rooms-client.rkt`, which is also where the profile story lives: a Goblins vat
;; speaks the OCapN v1.0 baseline and the room settles there for this member
;; alone.
;;
;; Usage:
;;   racket rooms-member.rkt <locator> <room> <nick> <line> [expect-from] [local-port]
;;
;; The locator is whatever the room server announced: a `host:port` over TCP, or
;; an `ocapn://<node-id>.iroh?direct-addresses=…` URI over iroh's encrypted QUIC.
;; The transport in the locator picks the netlayer. The trailing local-port is a
;; TCP argument and an iroh locator refuses it by name.
;;
;; It succeeds once it has both posted its line and heard the one it came for:
;; a line from `expect-from`, or, with no `expect-from`, its own line coming back
;; around. It then prints `ROOMS OK: …` and exits 0. A run that stalls prints
;; `ROOMS TIMEOUT` and one that is refused prints `ROOMS ERR: <reason>`, both
;; exiting 1. Every `notify` it hears is printed as it arrives, so a person
;; watching the terminal sees the room.
;;
;; Set `ROOMS_VIZ_URL` to a live timeline endpoint and this vat publishes its own
;; trace there, so the session it holds appears beside every other peer's. With
;; the variable unset it holds no publishing socket and sends nothing.

(require goblins
         "rooms-client.rkt"
         "trace-publish.rkt"
         racket/async-channel)

(file-stream-buffer-mode (current-output-port) 'line)

(define argv (current-command-line-arguments))

(define (arg i [default #f])
  (if (> (vector-length argv) i) (vector-ref argv i) default))

(define locator (or (arg 0) (error 'rooms-member "need a rooms locator")))
(define room-name (or (arg 1) "general"))
(define nick (or (arg 2) "goblins"))
(define line (or (arg 3) "hello from a goblins vat"))
;; The member whose line proves the room reached us. Empty (or absent) means
;; wait for our own line to come back around.
(define expect-from
  (let ([raw (arg 4 "")]) (if (string=? raw "") #f raw)))
(define local-port (local-port-argument (arg 5)))

;; The outcome, settled outside the vat so the main thread can wait on it without
;; blocking the vat that has to deliver the room's callbacks.
(define outcome-ch (make-async-channel))
(define member-vat (make-vat))

;; Where this vat publishes its own trace, or #f when no endpoint is configured.
(define publisher
  (let ([endpoint (trace-endpoint-from-env)])
    (and endpoint
         (make-trace-publisher
          endpoint
          #:self-label nick
          #:on-error (lambda (err) (eprintf "trace: ~a~n" (exn-message err)))))))

;; How long the whole join is allowed to take. Finite, because a silent partner
;; must fail loud rather than park the process.
(define deadline-seconds 60.0)

(define (fail . parts)
  (async-channel-put outcome-ch `(err ,(apply format parts))))

(member-vat
 'run
 (lambda ()
   ;; The run is over once this vat has both said its piece and heard what it
   ;; came to hear. Waiting on the line alone would let a fast partner finish us
   ;; before we ever post, and the room would lose the very message the other
   ;; member is waiting for. Both boxes are read and written on the vat's own
   ;; turn thread, so no lock is involved.
   (define posted (box #f))
   (define heard (box #f))
   (define (settle-when-both-done)
     (when (and (unbox posted) (unbox heard))
       (async-channel-put outcome-ch (cons 'ok (unbox heard)))))

   (define inbox
     (spawn-inbox
      (lambda (from text _presence)
        (printf "~a <- ~a: ~a~n" nick from text)
        (when (if expect-from
                  (string=? from expect-from)
                  (and (string=? from nick) (string=? text line)))
          (set-box! heard (list from text))
          (settle-when-both-done)))))

   (define (join room)
     (on (<- room 'subscribe nick inbox)
         (lambda (_ack)
           (printf "~a subscribed to ~a~n" nick room-name)
           (on (<- room 'post line)
               (lambda (_posted)
                 (printf "~a posted: ~a~n" nick line)
                 (set-box! posted #t)
                 (settle-when-both-done))
               #:catch (lambda (err) (fail "post failed: ~v" err))))
         #:catch (lambda (err) (fail "subscribe failed: ~v" err))))

   (define-values (directory-vow _our-locator)
     (connect-directory locator
                        #:local-port local-port
                        #:session-trace (and publisher (trace-publisher-sink publisher))))
   (on directory-vow
       (lambda (directory)
         (printf "~a reached the rooms directory at ~a~n" nick locator)
         (enter-or-open directory
                        room-name
                        join
                        (lambda (err) (fail "neither enter nor open: ~v" err))))
       #:catch
       (lambda (err) (fail "could not reach the directory: ~v" err)))))

(define result (sync/timeout deadline-seconds outcome-ch))
(when publisher (stop-trace-publisher publisher))
(case (and (pair? result) (car result))
  [(ok)
   (if expect-from
       (printf "ROOMS OK: ~a heard ~a say ~s~n" nick (cadr result) (caddr result))
       (printf "ROOMS OK: ~a heard the room echo ~s~n" nick (caddr result)))
   (exit 0)]
  [(err)
   (printf "ROOMS ERR: ~a~n" (cadr result))
   (exit 1)]
  [else
   (printf "ROOMS TIMEOUT~n")
   (exit 1)])
