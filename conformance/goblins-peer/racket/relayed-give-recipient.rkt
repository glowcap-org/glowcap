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
;; and the settled greeter call lands straight on the exporter. A second call
;; is sent while the introduced promise is unresolved: glowcap must carry that
;; queued invocation onto Bob's session when the promise settles.
;;
;; Because it is transparent, Carol needs one extra listener to say out loud
;; that she is waiting, and that is what `#:wants-partial?` is for: a partial
;; listener hears the intermediate promise and sends the queued invocation.
;; An unchanged outgoing deliver is observed, then an ordinary call to the
;; introducer acknowledges receipt of all preceding frames on that session.
;; Only that acknowledgment permits the driver to settle Bob's promise. `on` takes no partial
;; flag, and `listen` is not in the plain `goblins` surface, so this file imports
;; it from the `listen` submodule of `goblins/core`, the same seam
;; `glowcap-export-listen.rkt` uses.
;;
;; Usage:
;;   racket relayed-give-recipient.rkt <glowcap-host:port> <introducer-swiss> <local-port>
;;
;; Stdout:
;;   PIPELINE QUEUED      glowcap received the unresolved-target invocation
;;   PIPELINE OK: <reply> Bob answered that queued invocation
;;   GIFT OK: <reply>     the withdrawn greeter answered; exit 0 needs both
;;   GIFT ERR / GIFT TIMEOUT and exit 1 otherwise

(require goblins
         goblins/vat
         goblins/ocapn
         goblins/ocapn/structs-urls
         (submod goblins/core listen)
         "tcp-netlayer.rkt"
         "captp-interop-wire.rkt"
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
(define pipeline-name "goblins-carol-pipelined")
(define pipeline-written? (box #f))

;; Observe Goblins' own deliver without changing its target, resolver or wire
;; accounting. A desc:answer would exercise the introduction question,
;; rather than the imported promise this trace needs to call.
(define (observe-write write-message msg marshallers)
  (define pipeline? (equal? (deliver-verb msg) pipeline-name))
  (when (and (equal? (deliver-verb msg) "pipeline-barrier")
             (not (unbox pipeline-written?)))
    (error 'relayed-give "barrier overtook the queued wire deliver"))
  (when pipeline?
    (unless (and (not (unbox pipeline-written?))
                 (equal? (record-label (record-field msg 1)) "desc:export"))
      (error 'relayed-give "expected one deliver to the introduced promise")))
  (write-message msg marshallers)
  (when pipeline? (set-box! pipeline-written? #t)))

(define (report-error err) (async-channel-put response-ch `(err ,err)))

;; The partial listener. `listen` takes an actor rather than a procedure, and it
;; speaks the resolver protocol.
(define (^waiting _bcom introducer)
  (define queued? #f)
  (lambda args
    (case (and (pair? args) (car args))
      [(fulfill)
       (unless queued?
         (set! queued? #t)
         (on (<- (cadr args) pipeline-name)
             (lambda (val) (async-channel-put response-ch `(pipeline-ok ,val)))
             #:catch report-error)
         (on (<- introducer 'pipeline-barrier)
             (lambda (val)
               (if (and (equal? val "pipeline-barrier") (unbox pipeline-written?))
                   (async-channel-put response-ch '(queued))
                   (report-error "barrier arrived without the queued wire deliver")))
             #:catch report-error))]
      [(break) (report-error (cadr args))]
      [else (void)])))

(carol-vat
 'run
 (lambda ()
   (define netlayer
     (spawn ^tcp-netlayer "127.0.0.1" local-port #:interop-write-message observe-write))
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
   ;; remote one, which would queue the call before glowcap had even been
   ;; asked. Sending to a settled reference leaves exactly one step, the one
   ;; this proof is about.
   (on (<- mycapn 'enliven introducer-sturdyref)
       (lambda (introducer)
         (define greeter-answer (<- introducer 'get-greeter))

         ;; Hears the promise glowcap answers with, at the moment Goblins
         ;; starts waiting on it.
         (listen greeter-answer (spawn ^waiting introducer) #:wants-partial? #t)

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

(let loop ([pipeline-ok? #f] [gift-ok? #f])
  (define msg (sync/timeout 40.0 response-ch))
  (case (and (pair? msg) (car msg))
    [(queued)
     (printf "PIPELINE QUEUED~n")
     (loop pipeline-ok? gift-ok?)]
    [(pipeline-ok)
     (printf "PIPELINE OK: ~v~n" (cadr msg))
     (if gift-ok? (exit 0) (loop #t gift-ok?))]
    [(ok)
     (printf "GIFT OK: ~v~n" (cadr msg))
     (if pipeline-ok? (exit 0) (loop pipeline-ok? #t))]
    [(err)
     (printf "GIFT ERR: ~v~n" (cadr msg))
     (exit 1)]
    [else
     (printf "GIFT TIMEOUT~n")
     (exit 1)]))
