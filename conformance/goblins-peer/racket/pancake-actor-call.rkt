#lang racket/base
;; pancake-actor-call.rkt — a Goblins client that calls a pancake actor.
;;
;; It dials a pancake listener over TCP, enlivens the actor published behind a
;; swiss-num (an OCapN bootstrap fetch), waits for that to resolve to a live
;; reference, then sends the actor one positional argument and prints the reply.
;;
;; It deliberately resolves the cap *before* calling it (the nested `on`), so the
;; call is an ordinary deliver to a settled reference rather than a pipelined
;; send. That isolates this proof — "a real Goblins peer can call a pancake actor
;; and read its reply" — from promise pipelining, which is its own scenario.
;;
;; Usage:
;;   racket pancake-actor-call.rkt <target-port> <swiss-ascii> <message> [local-port]
;;
;; Prints `DIAL OK: <reply>` and exits 0 on success; `DIAL ERR: <err>` or
;; `DIAL TIMEOUT` and exits 1 otherwise.

(require goblins
         goblins/ocapn
         goblins/ocapn/structs-urls
         "tcp-netlayer.rkt"
         racket/async-channel)

(file-stream-buffer-mode (current-output-port) 'line)

(define argv (current-command-line-arguments))
(define target-port (string->number (vector-ref argv 0)))
(define swiss-ascii (vector-ref argv 1))
(define message     (vector-ref argv 2))
;; Goblins binds its own port so the listener can return calls to it.
(define local-port
  (if (>= (vector-length argv) 4)
      (string->number (vector-ref argv 3))
      19998))

;; Settled outside the vat so the outer thread can `sync/timeout` on it without
;; blocking the vat that has to deliver the resolution.
(define response-ch (make-async-channel))
(define dialer-vat (make-vat))

(dialer-vat
 'run
 (lambda ()
   (define netlayer (spawn ^tcp-netlayer "127.0.0.1" local-port))
   (define mycapn (spawn-mycapn netlayer))

   ;; Build the sturdyref directly (the struct constructor, not the URL parser):
   ;; netlayer name 'tcp, designator "host:port", swiss is the ASCII bytes the
   ;; pancake listener registered the actor under.
   (define target
     (ocapn-sturdyref
      (ocapn-node 'tcp (format "127.0.0.1:~a" target-port) #f)
      (string->bytes/latin-1 swiss-ascii)))

   (on (<- mycapn 'enliven target)
       (lambda (actor)
         ;; The cap is live now — this is a plain (non-pipelined) deliver.
         (on (<- actor message)
             (lambda (val) (async-channel-put response-ch `(ok ,val)))
             #:catch
             (lambda (err) (async-channel-put response-ch `(err ,err)))))
       #:catch
       (lambda (err) (async-channel-put response-ch `(err ,err))))))

(define reply (sync/timeout 10.0 response-ch))
(case (and (pair? reply) (car reply))
  [(ok)
   (printf "DIAL OK: ~v~n" (cadr reply))
   (exit 0)]
  [(err)
   (printf "DIAL ERR: ~v~n" (cadr reply))
   (exit 1)]
  [else
   (printf "DIAL TIMEOUT~n")
   (exit 1)])
