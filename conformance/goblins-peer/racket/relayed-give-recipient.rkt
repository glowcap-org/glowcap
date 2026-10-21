#lang racket/base
;; relayed-give-recipient.rkt: Goblins Carol, the third party in the
;; relayed-give proof (`zig build goblins-relayed-give`). She asks glowcap for a
;; greeter, is answered with a promise living on a vat she has never spoken to,
;; and the settlement of that promise carries a `desc:handoff-give`.
;;
;; What makes this different from `gift-recipient.rkt` is where the give arrives.
;; There, the introduction settles to a capability, so the give rides an answer
;; Carol asked for. Here the introduction settles to a promise, so Goblins
;; subscribes to that promise, `op:listen`, and the give arrives in the fire.
;; Goblins then redeems it without being asked: `incoming-post-unmarshall!`
;; recognizes a signed give wherever one appears in an incoming value, dials the
;; exporter, and withdraws. So the whole chain is transparent to the code below,
;; and the greeter call lands straight on the exporter with glowcap never in the
;; message path.
;;
;; Because it is transparent, Carol needs one extra listener to say out loud
;; that she is waiting, and that is what `#:wants-partial?` is for: a partial
;; listener hears the intermediate promise, and Goblins subscribes to a promise
;; in the same step that fires those listeners. So `LISTENING` on stdout means
;; Goblins has subscribed to the promise, which is the driver's cue to settle the
;; promise while somebody is demonstrably waiting on it. `on` takes no partial
;; flag, and `listen` is not in the plain `goblins` surface, so this file imports
;; it from the `listen` submodule of `goblins/core`, the same seam
;; `glowcap-export-listen.rkt` uses.
;;
;; Usage:
;;   racket relayed-give-recipient.rkt <glowcap-host:port> <introducer-swiss> <local-port>
;;
;; Stdout:
;;   LISTENING            Goblins has subscribed to the relayed promise
;;   GIFT OK: <reply>     and exit 0, when the withdrawn greeter answers
;;   GIFT ERR / GIFT TIMEOUT and exit 1 otherwise

(require goblins
         goblins/vat
         goblins/ocapn
         goblins/ocapn/structs-urls
         (submod goblins/core listen)
         "tcp-netlayer.rkt"
         racket/async-channel)

(file-stream-buffer-mode (current-output-port) 'line)

(define argv (current-command-line-arguments))
(define glowcap-designator (vector-ref argv 0)) ; "127.0.0.1:NNNNN"
(define swiss-ascii (vector-ref argv 1))
(define local-port (string->number (vector-ref argv 2)))

;; The channel lives outside the vat lambda so the outer thread can `sync` on
;; it; a vat lambda that blocks cannot deliver the resolutions it is waiting
;; for. One channel carries both phases, so a failure in either is reported
;; rather than waited out.
(define response-ch (make-async-channel))
(define carol-vat (make-vat))

;; The partial listener. `listen` takes an actor rather than a procedure, and it
;; speaks the resolver protocol.
(define (^waiting _bcom)
  (lambda args
    (case (and (pair? args) (car args))
      [(fulfill) (async-channel-put response-ch '(listening))]
      [(break) (async-channel-put response-ch `(err ,(cadr args)))]
      [else (void)])))

(carol-vat
 'run
 (lambda ()
   (define netlayer (spawn ^tcp-netlayer "127.0.0.1" local-port))
   (define mycapn (spawn-mycapn netlayer))

   ;; The struct constructor rather than the URL parser: net/url rejects
   ;; `host:port` in the subdomain field. Netlayer name 'tcp, designator
   ;; "host:port", swiss as ASCII bytes.
   (define introducer-sturdyref
     (ocapn-sturdyref
      (ocapn-node 'tcp glowcap-designator #f)
      (string->bytes/latin-1 swiss-ascii)))

   ;; Ask only once the introducer is live. A partial listener fires at every
   ;; step of a promise chain, and pipelining `get-greeter` onto the unresolved
   ;; enliven adds a step of its own, the local question promise becoming the
   ;; remote one, which would report `LISTENING` before glowcap had even been
   ;; asked. Sending to a settled reference leaves exactly one step, the one
   ;; this proof is about.
   (on (<- mycapn 'enliven introducer-sturdyref)
       (lambda (introducer)
         (define greeter-answer (<- introducer 'get-greeter))

         ;; Hears the promise glowcap answers with, at the moment Goblins status-allow: state at observation
         ;; starts waiting on it.
         (listen greeter-answer (spawn ^waiting) #:wants-partial? #t)

         ;; Fires with the greeter itself, once the promise has settled and the
         ;; give inside the settlement has been redeemed.
         (on greeter-answer
             (lambda (greeter)
               (on (<- greeter "goblins-carol")
                   (lambda (val) (async-channel-put response-ch `(ok ,val)))
                   #:catch
                   (lambda (err) (async-channel-put response-ch `(err ,err)))))
             #:catch
             (lambda (err) (async-channel-put response-ch `(err ,err)))))
       #:catch
       (lambda (err) (async-channel-put response-ch `(err ,err))))))

(let loop ()
  (define msg (sync/timeout 40.0 response-ch))
  (case (and (pair? msg) (car msg))
    [(listening)
     (printf "LISTENING~n")
     (loop)]
    [(ok)
     (printf "GIFT OK: ~v~n" (cadr msg))
     (exit 0)]
    [(err)
     (printf "GIFT ERR: ~v~n" (cadr msg))
     (exit 1)]
    [else
     (printf "GIFT TIMEOUT~n")
     (exit 1)]))
