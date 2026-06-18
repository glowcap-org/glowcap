#lang racket/base
;; A rooms chat client, written on pancake actors in native Racket.
;;
;; It enters the named room, waits until everyone it expects is present, posts
;; one line, and collects each expected member's line as the room pushes it back.
;; All the OCapN machinery lives in `room-client.rkt` (`room-connect` /
;; `dir-enter` / `room-subscribe` / `room-say` / `in-room`), so this reads like a
;; chat client — a loop over the lines the room sends. The strict directory verbs
;; live there; the friendly enter-or-open below is this app's own convenience.
;;
;;   racket client.rkt 127.0.0.1:9099 general alice "hi" alice,bob,carol
;;
;; The locator is transport-neutral: a `host:port` reaches a TCP room, an
;; `ocapn://<nodeid>.iroh?direct-addresses=…` URI reaches an iroh room. The
;; second argument is the room name (entering one that does not exist opens it).
;; The fifth argument is the roster: a comma-separated list of the member nicks
;; to expect (default: just you). An optional timeout in milliseconds defaults to
;; 15000. The client posts only once every roster member is present — it learns
;; who is present from its welcome (which names everyone already in the room) and
;; from the room's join announcements — and exits 0 once it has seen a line from
;; every roster member. Members outside the roster (people already chatting in an
;; attached room, say) are printed but never counted, so a busy room cannot fake
;; or break the assertion.
;;
;; This is the same application as the Deno, Python, Rust, and Zig clients, on one
;; OCapN wire — the room cannot tell which language a member is written in.

(require "room-client.rkt" racket/string)

;; Get a reference to the named room, opening it if it does not exist yet. The
;; wire and the directory wrapper stay strict — `dir-enter` raises on a missing
;; room, `dir-open` raises on a taken name — so this leniency is a CLI
;; convenience, here in the app, composed from the strict verbs.
(define (enter-or-open d name)
  (with-handlers ([exn? (lambda (e)
                          (cond
                            [(regexp-match? #rx"no room named" (exn-message e))
                             (with-handlers ([exn? (lambda (e2)
                                                     (if (regexp-match? #rx"already exists" (exn-message e2))
                                                         (dir-enter d name) ; lost the race; it is there now
                                                         (raise e2)))])
                               (dir-open d name))]
                            [else (raise e)]))])
    (dir-enter d name)))

;; Render the live room list for one line of output.
(define (format-rooms rooms)
  (if (null? rooms)
      "(none yet)"
      (string-join (for/list ([r (in-list rooms)]) (format "~a (~a)" (car r) (cadr r))) ", ")))

;; The friendly entry the client uses: connect, show and follow discovery (the
;; `list` snapshot and the `watch` change feed), then enter the room (opening it
;; if new) and subscribe as `nick`.
(define (join-room locator room-name nick)
  (define d (room-connect locator))
  (printf "[~a] rooms: ~a\n" nick (format-rooms (dir-list d)))
  (flush-output)
  (dir-watch d (lambda (kind name count)
                 (printf "[~a] directory: ~a ~a (~a)\n" nick kind name count)
                 (flush-output)))
  (room-subscribe (directory-conn d) (enter-or-open d room-name) nick))

;; The welcome ends with the nicks already present: "… in the room: a, b, c" —
;; the only way to learn about earlier arrivals.
(define (welcome-names msg)
  (and (message-system? msg)
       (let ([m (regexp-match #rx" in the room: (.+)$" (message-text msg))])
         (and m (string-split (cadr m) ", ")))))

;; The room announces each arrival as "<nick> joined (<count> here)".
(define (joined-nick msg)
  (and (message-system? msg)
       (let ([m (regexp-match #rx"^(.+) joined \\([0-9]+ here\\)$" (message-text msg))])
         (and m (cadr m)))))

(define (room-next/timeout room timeout-seconds)
  (define ch (make-channel))
  (define worker
    (thread
     (lambda ()
       (with-handlers ([exn? (lambda (e) (channel-put ch e))])
         (channel-put ch (room-next room))))))
  (define result (sync/timeout timeout-seconds ch))
  (cond
    [(not result)
     (kill-thread worker)
     #f]
    [(exn? result) (raise result)]
    [else result]))

(define (run-client locator room-name nick line roster [timeout-seconds 15])
  (define room (join-room locator room-name nick))
  (define deadline-ms (+ (current-inexact-milliseconds) (* timeout-seconds 1000.0)))
  (define (remaining-seconds)
    (/ (- deadline-ms (current-inexact-milliseconds)) 1000.0))
  (define left? #f)
  (define (leave!)
    (unless left?
      (set! left? #t)
      (room-leave room)))
  (define present (make-hash))
  (define seen (make-hash))
  (define posted #f)
  (define (all-in? table)
    (for/and ([member (in-list roster)]) (hash-ref table member #f)))
  (with-handlers ([exn? (lambda (e) (leave!) (raise e))])
    ;; Pull the next line only while roster members are still missing, so once we
    ;; have everyone's we stop instead of blocking on one more.
    (let loop ()
      (unless (all-in? seen)
        (define remaining (remaining-seconds))
        (define msg (and (positive? remaining) (room-next/timeout room remaining)))
        (when (and msg (not (eof-object? msg)))
          (printf "[~a] ~a: ~a\n" nick (message-sender msg) (message-text msg))
          (flush-output)
          (cond
            [(message-system? msg)
             (let ([names (welcome-names msg)])
               (when names (for ([n (in-list names)]) (hash-set! present n #t))))
             (let ([joined (joined-nick msg)])
               (when joined (hash-set! present joined #t)))]
            [else
             (hash-set! present (message-sender msg) #t) ; a line is presence too
             (when (member (message-sender msg) roster)
               (hash-set! seen (message-sender msg) #t))])
          ;; Post once every roster member is present, so each one receives it.
          (when (and (not posted) (all-in? present))
            (room-say room line)
            (set! posted #t))
          (loop))))
    (leave!)
    (unless (all-in? present)
      (define missing (for/list ([m (in-list roster)] #:unless (hash-ref present m #f)) m))
      (error 'rooms-client "~a roster did not complete (missing: ~a)"
             nick (string-join missing ", ")))
    (unless (all-in? seen)
      (define missing (for/list ([m (in-list roster)] #:unless (hash-ref seen m #f)) m))
      (error 'rooms-client "~a saw lines from ~a/~a members before the room ended (missing: ~a)"
             nick (hash-count seen) (length roster) (string-join missing ", ")))))

(module+ main
  (define args (current-command-line-arguments))
  (when (< (vector-length args) 4)
    (eprintf "usage: client.rkt <locator> <room> <nick> <line> [roster] [timeout-ms]   (locator: host:port or an ocapn:// URI; roster: comma-separated nicks to expect; default just you)\n")
    (exit 2))
  (define locator (vector-ref args 0))
  (define room-name (vector-ref args 1))
  (define nick (vector-ref args 2))
  (define line (vector-ref args 3))
  (define roster (if (> (vector-length args) 4)
                     (string-split (vector-ref args 4) ",")
                     (list nick)))
  (define timeout-ms (if (> (vector-length args) 5)
                         (string->number (vector-ref args 5))
                         15000))
  (unless (and timeout-ms (real? timeout-ms) (positive? timeout-ms))
    (eprintf "client ~a failed: timeout-ms must be a positive number\n" nick)
    (exit 2))
  (with-handlers ([(lambda (_) #t)
                   (lambda (e)
                     (eprintf "client ~a failed: ~a\n" nick (if (exn? e) (exn-message e) e))
                     (exit 1))])
    (run-client locator room-name nick line roster (/ timeout-ms 1000.0))
    (exit 0)))
