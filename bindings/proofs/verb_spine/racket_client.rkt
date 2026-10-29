#lang racket/base
;; The Racket half of the verb-spine proof family: one process that walks the
;; promise, dial, listen, and GC verbs against the fixed peer and prints one
;; `VERB-SPINE <marker>` line per scene. `harness.ts` owns the marker contract
;; and the two locators appended to argv; read its header before changing a
;; scene here.
;;
;; Run via `zig build racket-verb-spine`.

(require "../../racket/glowcap.rkt"
         "../../racket/glowcap-tcp.rkt")

(define (fail message)
  (eprintf "FAIL: ~a\n" message)
  (exit 1))

(define (mark marker [detail #f])
  (if detail
      (printf "VERB-SPINE ~a ~a\n" marker detail)
      (printf "VERB-SPINE ~a\n" marker))
  (flush-output))

(define (expect-string what actual wanted)
  (unless (equal? actual wanted)
    (fail (format "~a: expected ~s, got ~s" what wanted actual))))

;; A diagnostic to put after a marker word. The harness reads the marker and
;; ignores the rest of the line, so keep the rest on that one line.
(define (one-line raised)
  (regexp-replace* #px"\\s+" (if (exn? raised) (exn-message raised) (format "~a" raised)) " "))

;; Send, and require that the call itself hands back a handle. A binding that
;; raises here has put a synchronous failure channel on a handle-returning verb,
;; which is the trap this family exists to catch.
(define (send-handle c target verb args what)
  (with-handlers ([(lambda (_) #t)
                   (lambda (raised)
                     (fail (format "~a: session-send-promise raised instead of returning a handle: ~a"
                                   what (one-line raised))))])
    (apply session-send-promise c target verb args)))

;; The published object of this client's own listener, for `listen-served`.
(define (echoer bcom)
  (methods [(echo what) what]))

(define argv (current-command-line-arguments))
(when (< (vector-length argv) 2)
  (fail "usage: racket_client.rkt <peerUri> <deadUri>"))
(define peer-uri (vector-ref argv (- (vector-length argv) 2)))
(define dead-uri (vector-ref argv (- (vector-length argv) 1)))

(define runtime (open-runtime #:providers (list (tcp-provider))))

;; ── dial-ok ──────────────────────────────────────────────────────────────────
(define session (runtime-connect runtime (parse-locator peer-uri)))
(void (session-with-gc! session))
(define spine (session-fetch session "spine"))
(mark "dial-ok" peer-uri)

;; `session-await` answers a value that was never a handle with one particular
;; code. Reading that code back out of the API keeps the two failures below
;; apart: a handle reporting its own failure, and no handle to report one.
(define not-a-handle-code
  (with-handlers ([exn:fail:glowcap? exn:fail:glowcap-code])
    (session-await session 'not-a-handle)
    #f))
(unless (number? not-a-handle-code)
  (fail "session-await accepted a value that was never a handle"))

;; Await a handle whose scene requires a reported failure, and require the
;; report to come from the handle rather than from `session-await` refusing
;; something that was never a handle at all.
(define (require-reported-failure c handle what)
  (define outcome
    (with-handlers ([(lambda (_) #t) (lambda (raised) (cons 'raised raised))])
      (cons 'settled (session-await c handle))))
  (when (eq? (car outcome) 'settled)
    (fail (format "~a: the handle settled with ~s instead of reporting the failure"
                  what (cdr outcome))))
  (define raised (cdr outcome))
  (when (and (exn:fail:glowcap? raised)
             (equal? (exn:fail:glowcap-code raised) not-a-handle-code))
    (fail (format "~a: the call returned something that is not an awaitable handle" what)))
  raised)

;; ── promise-handle ───────────────────────────────────────────────────────────
(expect-string "greet"
               (session-await session (send-handle session spine 'greet '("spine") "greet"))
               "hello, spine")
(for* ([selector (in-list (list #f '|| 'call))]
       [payload (in-list (list '() '("payload")))])
  (define label (cond [(not selector) "direct"] [(eq? selector '||) "empty"] [else "call"]))
  (expect-string "invocation shape" (apply session-send session spine selector payload)
                 (format "~a:~a" label (length payload))))
(define shape-target
  (session-spawn session
    (lambda (_bcom)
      (lambda (selector . args)
        (format "~a:~a" (cond [(not selector) "direct"] [(eq? selector '||) "empty"] [else selector])
                (length args))))))
(define shape-proxy (session-caretaker session shape-target))
(expect-string "forwarded callback shapes" (session-send session spine 'shapes shape-proxy) "shapes preserved")
(mark "promise-handle")

;; ── promise-index / promise-untag / promise-get ──────────────────────────────
;; Each projection is issued at the unsettled answer, before anything awaits it:
;; that is what makes a dependent read one round trip rather than two.
(define listing (session-send-promise session spine 'list))
(define second-element (session-index session listing 1))
(expect-string "list index 1" (session-await session second-element) "beta")
(mark "promise-index")

(define boxed (session-send-promise session spine 'boxed))
(define cell-tail (session-index session (session-untag session boxed "cell") 1))
(expect-string "boxed untag then index 1" (session-await session cell-tail) "cell-1")
(mark "promise-untag")

(define record (session-send-promise session spine 'record))
(define record-name (session-get session record "name"))
(expect-string "record field name" (session-await session record-name) "spine-record")
(mark "promise-get")

;; ── gc-released ──────────────────────────────────────────────────────────────
(define minted (session-send session spine 'mint))
(unless (ref? minted)
  (fail (format "mint did not answer with a capability: ~s" minted)))
(expect-string "minted ping" (session-send session minted 'ping) "pong")
(session-release! session minted)
(define second-release-accepted?
  (with-handlers ([(lambda (_) #t) (lambda (_) #f)])
    (session-release! session minted)
    #t))
(when second-release-accepted?
  (fail "releasing a spent capability twice was accepted"))
(void
 (require-reported-failure
  session
  (send-handle session minted 'ping '() "send through a released capability")
  "send through a released capability"))
(mark "gc-released")

;; ── promise-failed ───────────────────────────────────────────────────────────
;; The documented escape, as behavior: a send that could never be issued comes
;; back as a settled failure, never as a raised error at the call.
(session-close! session)
(define ghost (send-handle session spine 'greet '("ghost") "send on a closed session"))
(void (require-reported-failure session ghost "send on a closed session"))
(mark "promise-failed")

;; ── listen-served ────────────────────────────────────────────────────────────
;; The accept parks until the dial below reaches it, so it runs on its own green
;; thread. Each session owns its own reader, so this thread serving the accepted
;; side and the main thread pumping the dialed side never contend.
(define server (listen "127.0.0.1" 0))
;; A closed listener has no locator to read, so name it while it lives.
(define own-uri (server-uri server))
(define published (make-semaphore 0))
(define serving
  (thread
   (lambda ()
     (define served (accept server))
     (session-publish served "echo" echoer)
     (semaphore-post published)
     (session-serve served))))
(define own (runtime-connect runtime (server-locator server)))
(semaphore-wait published)
(define echo (session-fetch own "echo"))
(expect-string "own listener echo" (session-send own echo 'echo "heard") "heard")
(session-close! own)
(thread-wait serving)
(server-close! server)
(mark "listen-served" own-uri)

;; ── dial-refused ─────────────────────────────────────────────────────────────
(define stray
  (with-handlers ([(lambda (_) #t)
                   (lambda (refusal) (mark "dial-refused" (one-line refusal)) #f)])
    (runtime-connect runtime (parse-locator dead-uri))))
(when stray
  (session-close! stray)
  (fail (format "dialing ~a opened a session; nothing is listening there" dead-uri)))

(runtime-close! runtime)
(mark "ok")
