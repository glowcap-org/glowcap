#lang racket/base
;; One family of the Racket binding's test suite, loadable on its own: a Host
;; spawns, sends to, and tells actors with no session, and a behavior's Host
;; verbs join its turn. A turn-time send answers after the turn, and a
;; collected actor's behavior leaves the Host, including under concurrent
;; spawns. `on` hears a Host send's vow. A Host send to a far reference
;; pumps the session that homes it, and a driver-owned session refuses the
;; far-promise break. A partner's op:abort stays readable after its session is
;; released.

(require "prelude.rkt")

(define m (make-fresh-host))
(define count 0)
(define counter
  (host-spawn m (lambda (method . args)
                  (case method
                    [(add) (set! count (+ count (car args))) count]
                    [(get) count]
                    [else (error 'counter "unexpected verb ~a" method)]))))
(expect (equal? 2 (host-send m counter 'add 2)) "host-send reaches a spawned actor")
(host-tell m counter 'add 3)
(expect (equal? 5 (host-send m counter 'get)) "a Host tell runs before the later send")

;; Inside a behavior, the tell, the send, and the spawn commit with its turn.
;; A waiting send is refused there before it queues anything, and the vow a
;; turn-time send returns is awaited after the turn.
(define refused-wait #f)
(define turn-vow #f)
(define factory
  (host-spawn m (lambda (method . args)
                  (set! refused-wait
                        (with-handlers ([exn:fail:glowcap? exn:fail:glowcap-code])
                          (host-send m counter 'add 100)
                          #f))
                  (host-tell m counter 'add 1)
                  (set! turn-vow (host-send-promise m counter 'add 1))
                  (list (host-spawn m (lambda (method . args) "made"))))))
(define made (host-send m factory 'make))
(expect (and (list? made) (ref? (car made))) "a turn-time Host spawn replies with its capability")
(expect (equal? "made" (host-send m (car made) 'probe)) "the turn-spawned actor answers")
(expect (equal? 7 (host-await m turn-vow)) "the turn-time send answers after its tell")
(expect (equal? 7 (host-send m counter 'get)) "turn-time tell and send both committed")
(expect (equal? ERR-INVALID-ARGUMENT refused-wait) "a waiting send inside a turn is refused")

(define broken
  (with-handlers ([exn:fail:glowcap? values])
    (host-send m counter 'unknown)
    #f))
(expect (and broken (= ERR-BROKEN (exn:fail:glowcap-code broken)))
        "a failing Host actor breaks the send with a typed ERR-BROKEN")

;; Collection crosses a finalizer, the Host's GC drain, and the Vat's next
;; turn, which the send to `counter` drives. A Host send's answer is owned, so
;; dropping the capability it carried collects the actor it names.
(define (settled-keep-count want)
  (let loop ([round 0])
    (collect-garbage)
    (sleep 0)
    (drain-host-gc! m)
    (host-send m counter 'get)
    (define now (hash-count (host-keep m)))
    (if (or (= now want) (= round 60)) now (loop (add1 round)))))
(define baseline (hash-count (host-keep m)))
(set! made #f)
(expect (= (- baseline 1) (settled-keep-count (- baseline 1)))
        "dropping a Host send's capability collected its actor and behavior")
(let ([probe (host-spawn m (lambda (method . args) "alive"))])
  (expect (equal? "alive" (host-send m probe 'ping)) "the probe actor answers"))
(expect (= (- baseline 1) (settled-keep-count (- baseline 1)))
        "a collected Host actor released its behavior")

;; Two threads spawning at once each take their own ctx id. A shared id would
;; let one actor's collection retire the other's live behavior, or leave a
;; collected actor's behavior held forever.
(define (spawn-racer tag)
  (define kept (box '()))
  (define racer
    (thread
     (lambda ()
       (for ([i (in-range 40)])
         (define name (format "~a~a" tag i))
         (define actor (host-spawn m (lambda (method . args) name)))
         (when (odd? i) (set-box! kept (cons (cons actor name) (unbox kept))))))))
  (lambda () (thread-wait racer) (unbox kept)))
(define survivors
  (apply append (map (lambda (finish) (finish)) (list (spawn-racer 'a) (spawn-racer 'b)))))
(define spawn-baseline (- baseline 1))
(expect (= (+ spawn-baseline (length survivors))
           (settled-keep-count (+ spawn-baseline (length survivors))))
        "concurrent spawns released exactly the collected actors' behaviors")
(expect (for/and ([s (in-list survivors)]) (equal? (cdr s) (host-send m (car s) 'who)))
        "every concurrently spawned survivor still answers")
(set! survivors '())
(expect (= spawn-baseline (settled-keep-count spawn-baseline))
        "collecting the concurrent survivors released every behavior")

;; A local answer that never settles ends at the pump deadline.
(define parked #f)
(define parker (host-spawn m (lambda (method . args) (set! parked (host-defer-turn m)) (void))))
(define parked-vow (host-send-promise m parker 'park))
(define timed-out
  (parameterize ([current-pump-deadline (+ (current-inexact-milliseconds) 50)])
    (with-handlers ([exn:fail:glowcap? exn:fail:glowcap-code])
      (host-await m parked-vow)
      #f)))
(expect (equal? ERR-TIMEOUT timed-out) "a Host wait honors the pump deadline")
(resolver-fulfill! parked "late")
(host-close! m)
(printf "racket test OK: a Host spawned, sent to, and told actors with no session\n")

;; A byte-fed client with no serve thread: the Host send must pump the session
;; that homes the far reference, or its answer never arrives. The deadline
;; bounds the wait if it does not.
(define far-server (listen "127.0.0.1" 0))
(define far-ready (make-semaphore 0))
(define far-accepted (box #f))
(define far-serving
  (thread
   (lambda ()
     (define hsession (accept far-server))
     (set-box! far-accepted hsession)
     (session-publish hsession "svc" (lambda (bcom) (methods [(greet who) (string-append "hi " who)])))
     (semaphore-post far-ready)
     (session-serve hsession))))
(define far-session
  (open-test-session (tcp-locator "127.0.0.1" (server-port far-server))
                     #:connector (tcp-connector)))
(semaphore-wait far-ready)
(define far-host (session-host far-session))
(define far-svc (session-fetch far-session "svc"))
(define far-answer
  (parameterize ([current-pump-deadline (+ (current-inexact-milliseconds) 10000)])
    (host-send far-host far-svc 'greet "host")))
(expect (equal? "hi host" far-answer) "a Host send to a far reference pumped its session")

;; A Host send's vow has no home session, and `on` listens through its Host
;; whether the target is local or far.
(define (heard-through-on target . args)
  (define heard (box #f))
  (define v (apply host-send-promise far-host target args))
  (with-vat (session-vat far-session) (on v (lambda (value) (set-box! heard value))))
  (parameterize ([current-pump-deadline (+ (current-inexact-milliseconds) 10000)])
    (host-await far-host v))
  (unbox heard))
(define far-echo (host-spawn far-host (lambda (method . args) (car args))))
(expect (equal? "local" (heard-through-on far-echo 'echo "local"))
        "on heard a Host send's vow to a local actor")
(expect (equal? "hi on" (heard-through-on far-svc 'greet "on"))
        "on heard a Host send's vow to a far reference")
(expect (not (session-partner-abort (unbox far-accepted))) "no partner abort before close")
;; The close sends op:abort, and its kind and message outlive the released
;; handle that retained them.
(session-close! far-session)
(void (sync/timeout 5 (thread-dead-evt far-serving)))
(session-close! (unbox far-accepted))
(expect (session-released? (unbox far-accepted)) "the accepted session released its handle")
(expect (equal? (partner-abort "NormalShutdown" "session closing")
                (session-partner-abort (unbox far-accepted)))
        "the partner's abort survives release")
(expect (not (session-partner-abort far-session)) "the closing side received no abort")

;; A driver-owned session refuses the far-promise break and stays usable.
(define driven-ready (make-semaphore 0))
(define driven-serving
  (thread
   (lambda ()
     (define hsession (accept far-server))
     (session-publish hsession "svc" (lambda (bcom) (methods [(greet who) (string-append "hi " who)])))
     (semaphore-post driven-ready)
     (session-serve hsession))))
(define driven (open-test-session (tcp-locator "127.0.0.1" (server-port far-server))))
(semaphore-wait driven-ready)
(define driven-svc (session-fetch driven "svc"))
(define refused-break
  (with-handlers ([exn:fail:glowcap? exn:fail:glowcap-code])
    (break-far-vows! (session-vat driven) "not ours to break")
    #f))
(expect (equal? ERR-INVALID-ARGUMENT refused-break) "a driver-owned session refuses the far-promise break")
(expect (equal? "hi again" (session-send driven driven-svc 'greet "again"))
        "the refused break left the session usable")
(session-close! driven)
(void (sync/timeout 5 (thread-dead-evt driven-serving)))
(server-close! far-server)
(printf "racket test OK: a Host send pumped a far reference's session, a close left its partner abort, and a driver-owned session refused the break\n")
