#lang racket/base
;; gift-recipient.rkt — Goblins Carol, the recipient in the pancake-as-gifter
;; three-party handoff proof. Dials the pancake gifter's introducer, asks it for
;; the greeter, and calls the greeter once.
;;
;; The introduction returns a `desc:handoff-give` pancake minted that names the
;; Goblins exporter (Bob). Goblins redeems it transparently: it dials Bob
;; directly, withdraws the gift, and resolves the send to the live greeter cap.
;; The greeter call then lands straight on Bob — pancake (the gifter) is never in
;; the message path. The reply must carry the name we sent, proving data
;; integrity across the cross-implementation handoff.
;;
;; Usage:
;;   racket gift-recipient.rkt <gifter-host:port> <introducer-swiss> <local-port>
;;
;; Prints `GIFT OK: <reply>` and exits 0 on success; `GIFT ERR`/`GIFT TIMEOUT`
;; and exits 1 otherwise.

(require goblins
         goblins/vat
         goblins/ocapn
         goblins/ocapn/structs-urls
         "tcp-netlayer.rkt"
         racket/async-channel)

(define argv (current-command-line-arguments))
(define gifter-designator (vector-ref argv 0)) ; "127.0.0.1:NNNNN"
(define swiss-ascii (vector-ref argv 1))
(define local-port (string->number (vector-ref argv 2)))

;; Defined OUTSIDE the vat lambda so the outer thread can `sync/timeout` on it
;; (the vat lambda must not block, or it can't deliver the resolution).
(define response-ch (make-async-channel))
(define carol-vat (make-vat))

(carol-vat
 'run
 (lambda ()
   (define netlayer (spawn ^tcp-netlayer "127.0.0.1" local-port))
   (define mycapn (spawn-mycapn netlayer))

   ;; Build the gifter's introducer sturdyref directly via the struct
   ;; constructor (the net/url parser rejects `host:port` in the subdomain
   ;; field). 'tcp netlayer-name; designator "host:port"; swiss is ASCII bytes.
   (define introducer-sturdyref
     (ocapn-sturdyref
      (ocapn-node 'tcp gifter-designator #f)
      (string->bytes/latin-1 swiss-ascii)))

   (define introducer-vow (<- mycapn 'enliven introducer-sturdyref))

   ;; Ask the gifter to introduce the greeter, and wait for that to *resolve*
   ;; before calling, the resolution is a handoff-give Goblins redeems to the
   ;; live exporter cap. Redeem-then-call (rather than pipelining the greeter
   ;; call onto the unresolved introduction) keeps the greeter call off the
   ;; gifter entirely: it goes straight to the exporter, the same shape the
   ;; `deno-goblins-handoff` recipient proof uses.
   (on (<- introducer-vow 'get-greeter)
       (lambda (greeter)
         (on (<- greeter "goblins-carol")
             (lambda (val) (async-channel-put response-ch `(ok ,val)))
             #:catch
             (lambda (err) (async-channel-put response-ch `(err ,err)))))
       #:catch
       (lambda (err) (async-channel-put response-ch `(err ,err))))))

(define reply (sync/timeout 20.0 response-ch))
(case (and (pair? reply) (car reply))
  [(ok)
   (printf "GIFT OK: ~v~n" (cadr reply))
   (exit 0)]
  [(err)
   (printf "GIFT ERR: ~v~n" (cadr reply))
   (exit 1)]
  [else
   (printf "GIFT TIMEOUT~n")
   (exit 1)])
