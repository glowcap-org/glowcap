#lang racket/base
;; A rooms chat client, written on pancake actors in native Racket.
;;
;; It joins the room, waits until it is full (learning the head count from the
;; room's own join announcements), posts one line, and collects every member's
;; line as the room pushes it back. All the OCapN machinery lives in
;; `room-client.rkt` (`room-join` / `room-say` / `in-room`), so this reads like a
;; chat client — a `for` over the lines the room sends.
;;
;;   racket client.rkt 127.0.0.1 9099 alice "hi" 3
;;
;; The last argument is how many members to expect; the client posts only once
;; that many have joined, so an all-to-all broadcast is deterministic regardless
;; of connect order. It exits 0 once it has seen a line from every member.
;;
;; This is the same application as the Deno, Python, Rust, and Zig clients, on one
;; OCapN wire — the room cannot tell which language a member is written in.

(require "room-client.rkt" racket/string)

;; Both the room's announcements carry the head count: a join says "(<count>
;; here)" and the welcome says "<count> in the room". Pull it from either so a
;; client knows the room is full and can post.
(define (room-size msg)
  (and (message-system? msg)
       (let ([m (or (regexp-match #rx"\\(([0-9]+) here\\)" (message-text msg))
                    (regexp-match #rx"([0-9]+) in the room" (message-text msg)))])
         (and m (string->number (cadr m))))))

(define (run-client host port nick line expect)
  (define room (room-join host port nick))
  (define present 0)
  (define posted #f)
  (define chat 0)
  ;; Pull the next line only while we still need more, so once we have everyone's
  ;; we stop instead of blocking on one more. (`(in-room room)` is the sequence
  ;; form, for a display that runs until disconnect; here we want the precise
  ;; stop, so we pull `room-next` ourselves.)
  (let loop ()
    (when (< chat expect)
      (define msg (room-next room))
      (unless (eof-object? msg)
        (printf "[~a] ~a: ~a\n" nick (message-sender msg) (message-text msg))
        (flush-output)
        (cond
          ;; A room announcement (welcome or a join) — never a chat line.
          [(message-system? msg)
           (let ([size (room-size msg)])
             (when size (set! present (max present size))))]
          [else (set! chat (add1 chat))])
        ;; Post once the room is full, so every member is on the roster.
        (when (and (not posted) (>= present expect))
          (room-say room line)
          (set! posted #t))
        (loop))))
  (room-leave room)
  (when (< chat expect)
    (error 'rooms-client "~a saw ~a/~a chat lines before the room ended" nick chat expect)))

(module+ main
  (define args (current-command-line-arguments))
  (when (< (vector-length args) 4)
    (eprintf "usage: client.rkt <host> <port> <nick> <line> [expectMembers]\n")
    (exit 2))
  (define host (vector-ref args 0))
  (define port (string->number (vector-ref args 1)))
  (define nick (vector-ref args 2))
  (define line (vector-ref args 3))
  (define expect (if (> (vector-length args) 4) (string->number (vector-ref args 4)) 1))
  (with-handlers ([(lambda (_) #t)
                   (lambda (e)
                     (eprintf "client ~a failed: ~a\n" nick (if (exn? e) (exn-message e) e))
                     (exit 1))])
    (run-client host port nick line expect)
    (exit 0)))
