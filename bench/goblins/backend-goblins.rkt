#lang racket/base
;; Goblins backend for the bench suite. Wraps the native `goblins` actor verbs and
;; a TCP server/client lifecycle (via the conformance tcp-netlayer) behind the
;; suite's substrate-blind API. The server registers the app root under a fixed
;; swiss-num so a client in another process can reconstruct the sturdyref from the
;; server's node plus that swiss-num and enliven it. No application logic here.
(require goblins
         goblins/vat
         goblins/ocapn/captp
         goblins/ocapn/structs-urls
         "../../conformance/goblins-peer/racket/tcp-netlayer.rkt"
         racket/async-channel)

(provide server-run client-connect client-fetch client-call client-close)

;; A fixed swiss-num the bench server registers its root under. The client knows
;; it (the bench always publishes one root named "root"), so nothing has to travel
;; through the readiness line except the listen address.
(define BENCH-SWISS (string->bytes/latin-1 "pancakeBenchRootSwissnum00000001"))

;; build-root : mint-cap -> root-ctor. On Goblins a returned actor reference
;; auto-marshals, so mint-cap is just `spawn`.
(define (server-run name host port build-root)
  (define a-vat (make-vat))
  (a-vat
   'run
   (lambda ()
     (define nl (spawn ^tcp-netlayer host port))
     (define mycapn (spawn-mycapn nl))
     (define registry ($ mycapn 'get-registry))
     (define (mint-cap ctor) (spawn ctor))
     (define root (spawn (build-root mint-cap)))
     ($ registry 'register root BENCH-SWISS)
     (on (<- nl 'our-location)
         (lambda (_loc)
           (printf "{\"v\":1,\"event\":\"ready\",\"listen\":\"~a:~a\"}\n" host port)
           (flush-output)))))
  (sync (make-semaphore)))

;; A client owns its own vat + netlayer (ephemeral listen port) + mycapn, so each
;; client-connect is a distinct CapTP session — the same shape as one pancake
;; connection. The server's host/port are kept to rebuild the sturdyref. One
;; settle channel is reused across all (sequential) calls so the driver adds no
;; per-call allocation overhead beyond what entering the vat requires — the
;; pancake side's `session-send` likewise reuses a single result cell per call.
(struct gclient (run mycapn host port ch))

(define (client-connect host port)
  (define vat (make-vat))
  (define mycapn
    (vat 'run
         (lambda ()
           (define nl (spawn ^tcp-netlayer host 0)) ; ephemeral client listen port
           (spawn-mycapn nl))))
  (gclient vat mycapn host port (make-async-channel)))

;; Run a thunk in the client vat (it posts its settled outcome to the handle's
;; channel) and block, yielding to the vat threads, for that outcome.
(define (settle handle thunk what)
  ((gclient-run handle) 'run thunk)
  (define r (async-channel-get (gclient-ch handle)))
  (if (eq? (car r) 'ok) (cdr r) (error 'backend-goblins "~a broke: ~a" what (cdr r))))

;; Enliven the root sturdyref and block until it resolves to a live capability.
(define (client-fetch handle _name)
  (define ch (gclient-ch handle))
  (settle handle
          (lambda ()
            (define node (ocapn-node 'tcp (format "~a:~a" (gclient-host handle) (gclient-port handle)) #f))
            (define sref (ocapn-sturdyref node BENCH-SWISS))
            (on (<- (gclient-mycapn handle) 'enliven sref)
                (lambda (cap) (async-channel-put ch (cons 'ok cap)))
                #:catch (lambda (e) (async-channel-put ch (cons 'err e)))))
          'enliven))

;; Synchronous eventual-send + settle in the client vat, returning the value.
(define (client-call handle ref method . args)
  (define ch (gclient-ch handle))
  (settle handle
          (lambda ()
            (on (apply <- ref method args)
                (lambda (v) (async-channel-put ch (cons 'ok v)))
                #:catch (lambda (e) (async-channel-put ch (cons 'err e)))))
          method))

(define (client-close handle) (void))
