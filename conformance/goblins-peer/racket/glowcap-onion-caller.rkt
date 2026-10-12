#lang racket/base
;; glowcap-onion-caller.rkt: a Goblins client that calls a glowcap actor across
;; a Tor hidden service circuit.
;;
;; It is `glowcap-actor-call.rkt`'s sibling, and the only difference is the
;; netlayer: this one is `goblins/ocapn/netlayer/onion`, upstream Goblins' own,
;; which glowcap had no hand in. The CapTP above it is unchanged, enlivening the
;; actor published behind a swiss-num and sending it one positional argument.
;;
;; Usage:
;;   racket glowcap-onion-caller.rkt <service-id> <swiss-ascii> <message> \
;;                                   <tor-control-socket> <tor-socks-socket>
;;
;; The service id is the bare 56 base32 characters, with no `.onion` suffix. The
;; Tor sockets are an already-running daemon's, and its control endpoint must take
;; no credential, because the netlayer sends a bare `AUTHENTICATE`.
;;
;; Prints `DIAL OK: <reply>` and exits 0 on success; `DIAL ERR: <err>` or
;; `DIAL TIMEOUT` and exits 1 otherwise.

(require goblins
         goblins/ocapn
         goblins/ocapn/structs-urls
         goblins/ocapn/netlayer/onion
         racket/async-channel
         racket/path)

(file-stream-buffer-mode (current-output-port) 'line)

(define argv (current-command-line-arguments))
(define service-id  (vector-ref argv 0))
(define swiss-ascii (vector-ref argv 1))
(define message     (vector-ref argv 2))
(define expected-reply
  (format "hello ~a, from glowcap over tor" message))
(define tor-control-path (string->path (vector-ref argv 3)))
(define tor-socks-path   (string->path (vector-ref argv 4)))

;; This client publishes a service of its own, because the netlayer is
;; symmetrical: it needs somewhere for replies to arrive. The directory holds the
;; socket Tor forwards to it, under the temporary tree the driver deletes.
(define ocapn-socks-dir
  (build-path (path-only tor-control-path) "goblins-caller-sockets"))

;; Settled outside the vat so the outer thread can `sync/timeout` on it without
;; blocking the vat that has to deliver the resolution.
(define response-ch (make-async-channel))
(define dialer-vat (make-vat))

(dialer-vat
 'run
 (lambda ()
   ;; Three values: the netlayer, the key that restores this client's own
   ;; service, and its id. This end only needs the first.
   (define-values (netlayer _private-key _service-id)
     (new-onion-netlayer #:tor-control-path tor-control-path
                         #:tor-socks-path tor-socks-path
                         #:tor-ocapn-socks-dir ocapn-socks-dir))
   (define mycapn (spawn-mycapn netlayer))

   ;; An onion locator carries no hints: the service id already says where to
   ;; dial, and this is the shape the pinned Goblins builds for itself.
   (define target
     (ocapn-sturdyref
      (ocapn-node 'onion service-id #f)
      (string->bytes/latin-1 swiss-ascii)))

   (on (<- mycapn 'enliven target)
       (lambda (actor)
         (on (<- actor message)
             (lambda (val) (async-channel-put response-ch `(ok ,val)))
             #:catch
             (lambda (err) (async-channel-put response-ch `(err ,err)))))
       #:catch
       (lambda (err) (async-channel-put response-ch `(err ,err))))))

;; Generous, because a freshly minted service's descriptor takes tens of seconds
;; to reach the directories this client asks, and the enliven is what waits.
(define reply (sync/timeout 240.0 response-ch))
(case (and (pair? reply) (car reply))
  [(ok)
   (define actual (cadr reply))
   (if (equal? actual expected-reply)
       (begin
         (printf "DIAL OK: ~v~n" actual)
         (exit 0))
       (begin
         (printf "DIAL ERR: expected ~v, got ~v~n" expected-reply actual)
         (exit 1)))]
  [(err)
   (printf "DIAL ERR: ~v~n" (cadr reply))
   (exit 1)]
  [else
   (printf "DIAL TIMEOUT~n")
   (exit 1)])
