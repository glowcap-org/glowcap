#lang racket/base
;; goblins-tap-dialer.rkt, single-shot Goblins client that dials a
;; remote OCapN sturdyref, enlivens it, and invokes it once.
;;
;; Usage:
;;   racket goblins-tap-dialer.rkt <port> <swiss-ascii> <message>
;;
;; Dials `127.0.0.1:<port>` (the tap), enlivens the sturdyref with
;; the given swiss-num (interpreted as ASCII bytes), invokes it with
;; one positional argument (`<message>`), prints the reply, exits.
;;
;; Pair it with a peer listening on `<port>`; the dialer connects
;; straight to that peer with no proxy in between.

(require goblins
         goblins/vat
         goblins/ocapn
         goblins/ocapn/structs-urls
         "tcp-netlayer.rkt"
         racket/async-channel)

(define argv (current-command-line-arguments))
(define target-port (string->number (vector-ref argv 0)))
(define swiss-ascii (vector-ref argv 1))
(define message     (vector-ref argv 2))

;; Local bind for the dialer's own listening socket. Goblins
;; requires every peer to bind something so it can receive return
;; calls from the remote.
(define local-port 19999)

;; Defined OUTSIDE the vat lambda so the outer code can `sync/timeout`
;; on it. If `sync/timeout` runs INSIDE the vat lambda the vat blocks
;; and can't deliver the resolution event when it arrives.
(define response-ch (make-async-channel))
(define dialer-vat (make-vat))

(dialer-vat
 'run
 (lambda ()
   (define netlayer (spawn ^tcp-netlayer "127.0.0.1" local-port))
   (define mycapn (spawn-mycapn netlayer))

   ;; Build the sturdyref directly via the struct constructor,
   ;; bypasses Racket's net/url-string parser (which doesn't accept
   ;; `host:port` inside the OCapN subdomain field). The
   ;; tcp-netlayer here uses netlayer-name 'tcp; designator is
   ;; "host:port"; swiss is ASCII bytes (the canonical form
   ;; seven-caps-peer registers).
   (define target-sturdyref
     (ocapn-sturdyref
      (ocapn-node 'tcp (format "127.0.0.1:~a" target-port) #f)
      (string->bytes/latin-1 swiss-ascii)))

   (define greeter-vow (<- mycapn 'enliven target-sturdyref))
   (on (<- greeter-vow message)
       (lambda (val)
         (async-channel-put response-ch `(ok ,val)))
       #:catch
       (lambda (err)
         (async-channel-put response-ch `(err ,err))))))

;; Now the outer thread waits for the vat to deliver the result.
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
