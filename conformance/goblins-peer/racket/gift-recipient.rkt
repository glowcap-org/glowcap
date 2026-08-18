#lang racket/base
;; gift-recipient.rkt — Goblins Carol, the recipient in the pancake-as-gifter
;; three-party handoff proof. Dials the pancake gifter's introducer, asks it for
;; the greeter, and calls it. With the optional `nested` mode the answer is a
;; list containing two recursively placed gives; Carol must redeem and call
;; both, proving that the gifter did not special-case a top-level answer.
;;
;; The introduction returns a `desc:handoff-give` pancake minted that names the
;; Goblins exporter (Bob). Goblins redeems it transparently: it dials Bob
;; directly, withdraws the gift, and resolves the send to the live greeter cap.
;; The greeter call then lands straight on Bob — pancake (the gifter) is never in
;; the message path. The reply must carry the name we sent, proving data
;; integrity across the cross-implementation handoff.
;;
;; Usage:
;;   racket gift-recipient.rkt <gifter-host:port> <introducer-swiss> <local-port> [expect-hint] [nested]
;;
;; Prints `GIFT OK: <reply>` and exits 0 on success; `GIFT ERR`/`GIFT TIMEOUT`
;; and exits 1 otherwise. With the optional `expect-hint` name, the netlayer's
;; connect trace inspects each dialed node's hints and prints
;; `HINT SEEN: <name> <byte-length>` when a dial target carries that hint as a
;; bytes value — the positive signal that the give's exporter locator crossed
;; the upstream unmarshaller with its hint dict intact.

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
(define optional-args
  (for/list ([index (in-range 3 (vector-length argv))]) (vector-ref argv index)))
(define nested? (and (member "nested" optional-args) #t))
(define expect-hint
  (for/first ([arg (in-list optional-args)] #:unless (string=? arg "nested")) arg))

;; The wire unmarshaller builds `ocapn-node` through the raw constructor, so a
;; decoded node can carry mapping-shaped hints even though the contracted
;; accessor admits only #f-or-string. The struct is transparent, so the probe
;; reads the hints field reflectively — observing what actually arrived
;; without re-imposing the constructor contract on it.
(define (connect-trace event . args)
  (when (and expect-hint (eq? event 'connect))
    (define remote (cadr args))
    (when (ocapn-node? remote)
      (define hints (vector-ref (struct->vector remote) 3))
      (when (hash? hints)
        (define val (hash-ref hints expect-hint #f))
        (when (bytes? val)
          (printf "HINT SEEN: ~a ~a~n" expect-hint (bytes-length val))
          (flush-output))))))

;; Defined OUTSIDE the vat lambda so the outer thread can `sync/timeout` on it
;; (the vat lambda must not block, or it can't deliver the resolution).
(define response-ch (make-async-channel))
(define carol-vat (make-vat))

(carol-vat
 'run
 (lambda ()
   (define netlayer (spawn ^tcp-netlayer "127.0.0.1" local-port #:trace connect-trace))
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
   ;; before calling. In nested mode Goblins recursively unmarshals the two
   ;; gives inside the list into promises; calling both proves each distinct
   ;; signed introduction reached the exporter.
   (on (<- introducer-vow 'get-greeter)
       (lambda (answer)
         (with-handlers ([(lambda (_) #t)
                          (lambda (err) (async-channel-put response-ch `(err ,err)))])
           (define greeters
             (if nested?
                 (if (and (list? answer)
                          (= (length answer) 2)
                          (list? (cadr answer))
                          (= (length (cadr answer)) 1))
                     (list (car answer) (car (cadr answer)))
                     (error 'gift-recipient "nested answer has the wrong shape: ~v" answer))
                 (list answer)))
           (on (<- (car greeters) "goblins-carol-one")
               (lambda (first)
                 (if nested?
                     (on (<- (cadr greeters) "goblins-carol-two")
                         (lambda (second)
                           (async-channel-put response-ch `(nested-ok ,first ,second)))
                         #:catch
                         (lambda (err) (async-channel-put response-ch `(err ,err))))
                     (async-channel-put response-ch `(ok ,first))))
               #:catch
               (lambda (err) (async-channel-put response-ch `(err ,err))))))
       #:catch
       (lambda (err) (async-channel-put response-ch `(err ,err))))))

(define reply (sync/timeout 20.0 response-ch))
(case (and (pair? reply) (car reply))
  [(ok)
   (printf "GIFT OK: ~v~n" (cadr reply))
   (exit 0)]
  [(nested-ok)
   (printf "GIFT NESTED OK: ~v | ~v~n" (cadr reply) (caddr reply))
   (exit 0)]
  [(err)
   (printf "GIFT ERR: ~v~n" (cadr reply))
   (exit 1)]
  [else
   (printf "GIFT TIMEOUT~n")
   (exit 1)])
