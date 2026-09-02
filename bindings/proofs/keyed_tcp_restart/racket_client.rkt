#lang racket/base
;; Per-binding keyed-tcp restart proof (ADR-0075): happy path, key-squatter
;; refusal, and same-seed-fresh-port restart — the Racket sibling of
;; `test/driver/keyed_tcp_restart_test.zig`.
;;
;; Needs racket and the installed glowcap archives; run via
;; `zig build racket-keyed-tcp-restart`.

(require racket/tcp
         file/sha1
         "../../racket/glowcap.rkt"
         "../../racket/glowcap-tcp.rkt")

(define GREETING "hello from the keyed listener")
(define SEED-HAPPY (make-bytes 32 #x71))
(define SEED-HONEST (make-bytes 32 #x72))
(define SEED-SQUATTER (make-bytes 32 #x73))
(define SEED-RESTART (make-bytes 32 #x74))
(define runtime (open-runtime #:providers (list (tcp-provider))))

(define (greeter bcom)
  (methods [(greet) GREETING]))

;; Accept one partner, publish the greeter, signal `ready`, then serve until
;; the client closes. `connect` must run concurrently so accept unblocks.
(define (serve-once! s ready)
  (define c (accept s))
  (session-publish c "greeter" greeter)
  (semaphore-post ready)
  (session-serve c))

(define (call-greeter! uri ready expected)
  (define c (runtime-connect runtime uri))
  (semaphore-wait ready)
  ;; Keyed TCP carries a key-shaped designator. The verified session hello must
  ;; claim the dial target, but the cleartext channel does not prove control of
  ;; that durable key.
  (define proved (session-partner-identity c))
  (unless (equal? (partner-identity-designator proved) expected)
    (error 'keyed-tcp-restart "partner claimed ~a, not the dialed ~a"
           (partner-identity-designator proved) expected))
  ;; Every session signs with a fresh key (ADR-0097), distinct from
  ;; the claimed durable designator.
  (when (equal? (bytes->hex-string (partner-identity-session-key proved)) expected)
    (error 'keyed-tcp-restart
           "session key still equals the durable designator; sessions are not independently keyed"))
  ;; Raw keyed TCP carries the stable key-shaped locator but does not prove that
  ;; whoever answered controls it.
  (unless (eq? (partner-identity-provenance proved) 'unauthenticated)
    (error 'keyed-tcp-restart "keyed-tcp durable provenance is ~a, not unauthenticated"
           (partner-identity-provenance proved)))
  (when (partner-identity-durable-authenticated? proved)
    (error 'keyed-tcp-restart "raw keyed-tcp authenticated an unproved locator claim"))
  (define g (session-fetch c "greeter"))
  (define reply (session-send c g 'greet))
  (unless (equal? reply GREETING)
    (error 'keyed-tcp-restart "unexpected greeting: ~a" reply))
  (session-close! c))

(define (scene-happy!)
  (define s (listen-keyed-tcp "127.0.0.1" 0 #:seed SEED-HAPPY))
  (define ready (make-semaphore 0))
  (define host (thread (lambda () (serve-once! s ready))))
  (call-greeter! (server-uri s) ready
                 (locator-designator (server-locator s)))
  (thread-wait host)
  (server-close! s)
  (displayln "racket-keyed-tcp-restart: happy path ok"))

(define (scene-squatter!)
  (define honest (listen-keyed-tcp "127.0.0.1" 0 #:seed SEED-HONEST))
  (define designator (locator-designator (server-locator honest)))
  (server-close! honest)
  (define squatter (listen-keyed-tcp "127.0.0.1" 0 #:seed SEED-SQUATTER))
  (define host (thread (lambda ()
                         (with-handlers ([exn:fail? (lambda (_) (void))])
                           (define c (accept squatter))
                           (session-publish c "greeter" greeter)
                           (session-serve c)))))
  (define uri (keyed-tcp-locator designator "127.0.0.1" (server-port squatter)))
  (with-handlers ([exn:fail? (lambda (e)
                               (printf "racket-keyed-tcp-restart: squatter refused (~a)~n" e))])
    (define c (runtime-connect runtime uri))
    (session-close! c)
    (error 'keyed-tcp-restart "squatter dial should have been refused"))
  (server-close! squatter)
  (thread-wait host)
  (displayln "racket-keyed-tcp-restart: squatter refusal ok"))

(define (scene-restart!)
  (define first (listen-keyed-tcp "127.0.0.1" 0 #:seed SEED-RESTART))
  (define designator (locator-designator (server-locator first)))
  (define ready1 (make-semaphore 0))
  (define host1 (thread (lambda () (serve-once! first ready1))))
  (call-greeter! (server-uri first) ready1 designator)
  (thread-wait host1)
  (server-close! first)
  (define second (listen-keyed-tcp "127.0.0.1" 0 #:seed SEED-RESTART))
  (unless (equal? designator (locator-designator (server-locator second)))
    (error 'keyed-tcp-restart "restart designator drifted"))
  (define ready2 (make-semaphore 0))
  (define host2 (thread (lambda () (serve-once! second ready2))))
  (call-greeter! (keyed-tcp-locator designator "127.0.0.1" (server-port second))
                 ready2 designator)
  (thread-wait host2)
  (server-close! second)
  (displayln "racket-keyed-tcp-restart: restart ok"))

(scene-happy!)
(scene-squatter!)
(scene-restart!)
(runtime-close! runtime)
(displayln "racket-keyed-tcp-restart: all scenes ok")
