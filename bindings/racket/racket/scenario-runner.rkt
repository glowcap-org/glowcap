#lang racket/base

;; scenario-runner.rkt — single Racket entry point for the
;; pancake-ffi-bindings catalog. Per the C2 design (§ 6.1), this
;; consolidates the per-scenario standalone scripts into one
;; dispatcher; each scenario's logic lives as a function below (or
;; in a submodule, for the sides whose requires conflict with the
;; main module's pancake-ffi imports).
;;
;; The catalog at reference/tests/pancake-ffi-bindings/ orchestrates
;; invocations via the binding's pixi.toml `scenario` task, which
;; shells out to `racket scenario-runner.rkt <scenario-id> [--side <side>]`.
;;
;; Submodules carry isolated requires:
;;   pancake-host-side  — Goblins-on-pancake-captp (require "captp.rkt")
;;   stock-client-side  — stock Spritely Goblins (require goblins/ocapn/captp)
;;
;; Both submodules require Goblins; loading them is heavy. Main-module
;; scenarios (handshake-self-in-process / -tcp / -as-client-vs-spritely
;; / graceful-abort-send) don't trigger that load — dynamic-require
;; only fires when the dispatcher reaches an echo-as-host-vs-spritely
;; side.

;; ─── Submodule: pancake-backed Goblins host ────────────────────────

(module pancake-host-side racket/base
  ;; The Goblins-on-pancake-captp host side of echo-as-host-vs-spritely.
  ;; Lives in a submodule because `captp.rkt` provides `spawn-mycapn`
  ;; under a name that conflicts with stock `goblins/ocapn/captp`.
  ;; Isolated requires keep the main module free of the conflict.
  (require goblins
           goblins/vat
           "captp.rkt"
           "pancake-tcp-netlayer.rkt")
  (provide run-echo-host)

  ;; Standard OCapN conformance-suite echo swissnum — same value as
  ;; goblins-peer/racket/seven-caps-peer.rkt.
  (define ECHO-SWISS-NUM
    (string->bytes/latin-1 "IO58l1laTyhcrgDKbEzFOO32MDd6zE5w"))

  ;; Second swissnum for the ^add cap — load-bearing for the
  ;; real-result-routing proof. Echo's "result == input" hides
  ;; the difference between echoing-input-args and surfacing-
  ;; actor-result; an add cap has result ≠ input, so a correct
  ;; reply MUST come from the actor's invocation, not from any
  ;; fire-and-forget echo path.
  (define ADD-SWISS-NUM
    (string->bytes/latin-1 "addaddaddaddaddaddaddaddaddaddad"))

  ;; Echo actor behavior — identical to upstream Spritely's
  ;; seven-caps-peer.rkt's ^echo. Takes its args, returns them.
  (define (^echo _bcom)
    (lambda args
      (printf "[echo] received ~v; echoing back~n" args)
      args))

  ;; Add actor — Goblins-style positional method: `((<- add) a b)`
  ;; returns `(+ a b)`. Demonstrates that the captp pump routes
  ;; the actor's ACTUAL result back to the partner (not the
  ;; input args). Pre-dispatcher-pattern this would have
  ;; replied with `(a b)` (input echo); post-dispatcher it
  ;; replies with the sum.
  (define (^add _bcom)
    (lambda (a b)
      (define sum (+ a b))
      (printf "[add] (+ ~a ~a) → ~a~n" a b sum)
      sum))

  ;; Counter behavior — closed-over state. Each method invocation
  ;; reads-then-writes the state via bcom. Used by car-factory to
  ;; demonstrate cap-passing: factory returns a fresh counter
  ;; cap (a Goblins refr); client invokes the returned cap;
  ;; multiple invocations return incrementing values, proving
  ;; (a) the returned ref points to the SAME stateful actor on
  ;; the host, (b) the partner's import-id correctly routes to
  ;; the host's allocated export-id across multiple op:deliver
  ;; calls.
  (define (^counter bcom [n 0])
    (lambda ()
      (printf "[counter] tick → ~a~n" n)
      (bcom (^counter bcom (+ n 1)) n)))

  ;; Car-factory — invocation returns a freshly-spawned counter
  ;; cap. Exercises cap-passing: the actor's RESULT is a
  ;; Goblins refr, which captp.rkt's racket->pcakearg must
  ;; recognize via live-refr? + register via
  ;; pancake-peer-register-export. The wire encoding for the
  ;; reply payload becomes Reference(Near(eid)) where eid is
  ;; the per-connection export-id captp.rkt allocated.
  (define CAR-FACTORY-SWISS-NUM
    (string->bytes/latin-1 "carcarcarcarcarcarcarcarcarcarc1"))
  (define (^car-factory _bcom)
    (lambda ()
      (define c (spawn ^counter))
      (printf "[car-factory] spawned new counter cap → ~v~n" c)
      c))

  ;; Boom — actor that always throws. Exercises the Break reply
  ;; route in send-actor-reply: vow breaks → op:resolve(Break,
  ;; error) (pre-V1.0) or op:deliver-to-resolver-cap with
  ;; args=[Symbol("break"), <message>] (Goblins V1.0). Without
  ;; this test, the Break route in captp.rkt's send-actor-reply
  ;; is dead code — only covered by tests, not real scenarios.
  (define BOOM-SWISS-NUM
    (string->bytes/latin-1 "boomboomboomboomboomboomboomboo1"))
  (define (^boom _bcom)
    (lambda args
      (printf "[boom] received ~v; throwing~n" args)
      (error 'boom "intentional Break-route test")))

  ;; Cap-in-args (^greeter that calls back a client-provided cap)
  ;; is INTENTIONALLY NOT WIRED in this MVP. The wire-shape gap
  ;; is on the projection side: `pcakearg->racket` would need to
  ;; turn inbound Reference(Far(host=partner, import_id=N))
  ;; arguments into Goblins-invokable proxies that forward
  ;; via `pancake-peer-send-deliver` and route ResolveReceived
  ;; events back to the proxy's vow. That requires synthesizing
  ;; a host-side proxy actor + maintaining an answer-id →
  ;; proxy-resolver table — multiple round-trips of plumbing
  ;; beyond what the current MVP captp surface supports. Live
  ;; refrs as RETURN values work (cap-passing landed in
  ;; commit 7394d15); live refrs as INBOUND args is the
  ;; symmetric next step. See the "no actor for 0" comment in
  ;; captp.rkt's handle-deliver! for the related gap on the
  ;; dispatch side.

  ;; Host two Goblins actors on the pancake-backed captp module —
  ;; echo (result==input) + add (result!=input). The body is
  ;; byte-identical to a stock-Spritely-Goblins host for the
  ;; spawn-mycapn / get-registry / nonce-registry / register
  ;; surface; the only difference from upstream is the
  ;; pancake-backed captp.rkt + pancake-tcp-netlayer.rkt
  ;; imports above.
  (define (run-echo-host listen-host listen-port)
    (file-stream-buffer-mode (current-output-port) 'line)
    (file-stream-buffer-mode (current-error-port) 'line)
    (define a-vat (make-vat))
    (a-vat
     'run
     (lambda ()
       (define nl (spawn ^tcp-netlayer listen-host listen-port))
       (define mycapn (spawn-mycapn nl))
       (define nonce-registry ($ mycapn 'get-registry))
       (define echo (spawn ^echo))
       (define add (spawn ^add))
       (define car-factory (spawn ^car-factory))
       (define boom (spawn ^boom))
       ($ nonce-registry 'register echo ECHO-SWISS-NUM)
       ($ nonce-registry 'register add ADD-SWISS-NUM)
       ($ nonce-registry 'register car-factory CAR-FACTORY-SWISS-NUM)
       ($ nonce-registry 'register boom BOOM-SWISS-NUM)
       (printf "[echo-host] listening on ~a:~a~n" listen-host listen-port)
       (printf "[echo-host] echo        cap registered at swiss ~v~n"
               (bytes->string/latin-1 ECHO-SWISS-NUM))
       (printf "[echo-host] add         cap registered at swiss ~v~n"
               (bytes->string/latin-1 ADD-SWISS-NUM))
       (printf "[echo-host] car-factory cap registered at swiss ~v~n"
               (bytes->string/latin-1 CAR-FACTORY-SWISS-NUM))
       (printf "[echo-host] boom        cap registered at swiss ~v~n"
               (bytes->string/latin-1 BOOM-SWISS-NUM))
       (printf "[echo-host] dial URL: ocapn://~a.tcp-testing-only?host=~a&port=~a~n"
               (bytes->string/latin-1 ECHO-SWISS-NUM)
               listen-host listen-port)
       (printf "[echo-host] ready; press Ctrl-C to stop~n")))
    ;; Sit until killed; the host is a long-running peer for the
    ;; client-side scenario task to dial. Catalog's scenario task
    ;; spawns the host in one terminal + the client in another;
    ;; pass criterion is the CLIENT's "OK: ..." line.
    (sync (make-semaphore))))

;; ─── Submodule: stock Spritely Goblins client ──────────────────────

(module stock-client-side racket/base
  ;; The stock-Spritely client side of echo-as-host-vs-spritely.
  ;; Uses upstream Spritely Goblins UNCHANGED — `goblins/ocapn/captp`
  ;; imported directly without going through the pancake-backed
  ;; captp.rkt. The literal claim this side carries: a standard
  ;; Goblins consumer (no pancake-ffi loaded at all) can dial a
  ;; pancake-backed echo-host over OCapN's wire protocol and invoke
  ;; the registered cap.
  (require racket/async-channel
           racket/match
           goblins
           goblins/vat
           goblins/ocapn/captp                          ; UPSTREAM stock
           goblins/ocapn/structs-urls                   ; UPSTREAM stock
           "../../goblins-peer/racket/tcp-netlayer.rkt") ; UPSTREAM stock
  (provide run-stock-echo-client)

  (define ECHO-SWISS-NUM
    (string->bytes/latin-1 "IO58l1laTyhcrgDKbEzFOO32MDd6zE5w"))
  (define ADD-SWISS-NUM
    (string->bytes/latin-1 "addaddaddaddaddaddaddaddaddaddad"))
  (define CAR-FACTORY-SWISS-NUM
    (string->bytes/latin-1 "carcarcarcarcarcarcarcarcarcarc1"))
  (define BOOM-SWISS-NUM
    (string->bytes/latin-1 "boomboomboomboomboomboomboomboo1"))

  (define (run-stock-echo-client host port)
    (file-stream-buffer-mode (current-output-port) 'line)
    (define a-vat (make-vat))
    (define result-ch (make-async-channel))
    (a-vat
     'run
     (lambda ()
       (define nl
         (spawn ^tcp-netlayer "127.0.0.1" (+ port 100) ; client binds its own port
                "127.0.0.1"))
       (define mycapn (spawn-mycapn nl))
       (define target-location
         (ocapn-node 'tcp (format "~a:~a" host port) #f))
       (define echo-sturdyref
         (ocapn-sturdyref target-location ECHO-SWISS-NUM))
       (define add-sturdyref
         (ocapn-sturdyref target-location ADD-SWISS-NUM))
       (define car-factory-sturdyref
         (ocapn-sturdyref target-location CAR-FACTORY-SWISS-NUM))
       (define boom-sturdyref
         (ocapn-sturdyref target-location BOOM-SWISS-NUM))
       (printf "[client] enlivening echo sturdyref at ~a:~a~n" host port)
       (define echo-vow (<- mycapn 'enliven echo-sturdyref))
       (on echo-vow
           (lambda (echo)
             (printf "[client] enlivened echo; invoking echo \"hello\" \"world\"~n")
             (on (<- echo "hello" "world")
                 (lambda (echo-result)
                   (printf "[client] echo returned: ~v~n" echo-result)
                   ;; Stage 2: invoke add cap (result != input).
                   ;; If real result routing works, returns 5;
                   ;; if the host fell back to input-echo, would
                   ;; return (2 3).
                   (printf "[client] enlivening add sturdyref~n")
                   (define add-vow (<- mycapn 'enliven add-sturdyref))
                   (on add-vow
                       (lambda (add)
                         (printf "[client] invoking (add 2 3); expecting 5~n")
                         (on (<- add 2 3)
                             (lambda (add-result)
                               (printf "[client] add returned: ~v~n" add-result)
                               ;; Stage 3: cap-passing. Enliven the car-
                               ;; factory; invoke it; the result is a
                               ;; CAP (a Goblins refr). Invoke the
                               ;; returned cap twice; both calls must
                               ;; route to the same host-side actor.
                               (printf "[client] enlivening car-factory sturdyref~n")
                               (define cf-vow (<- mycapn 'enliven car-factory-sturdyref))
                               (on cf-vow
                                   (lambda (cf)
                                     (printf "[client] invoking car-factory; expecting fresh cap~n")
                                     (on (<- cf)
                                         (lambda (counter-ref)
                                           (printf "[client] car-factory returned: ~v~n" counter-ref)
                                           ;; First tick.
                                           (on (<- counter-ref)
                                               (lambda (n0)
                                                 (printf "[client] counter tick 1 → ~v~n" n0)
                                                 ;; Second tick (should be n0+1 if same actor).
                                                 (on (<- counter-ref)
                                                     (lambda (n1)
                                                       (printf "[client] counter tick 2 → ~v~n" n1)
                                                       ;; Stage 4: Break route — invoke ^boom; expect a Break.
                                                       (printf "[client] enlivening boom sturdyref~n")
                                                       (on (<- mycapn 'enliven boom-sturdyref)
                                                           (lambda (boom)
                                                             (printf "[client] invoking boom; expecting Break~n")
                                                             (on (<- boom "trigger")
                                                                 (lambda (unexpected)
                                                                   (async-channel-put result-ch
                                                                     `(err boom-should-have-broken ,unexpected)))
                                                                 #:catch
                                                                 (lambda (boom-err)
                                                                   (printf "[client] boom broke as expected: ~v~n" boom-err)
                                                                   (async-channel-put result-ch
                                                                     `(ok (echo ,echo-result)
                                                                          (add ,add-result)
                                                                          (counter ,n0 ,n1)
                                                                          (boom-broke #t))))))
                                                           #:catch
                                                           (lambda (err)
                                                             (async-channel-put result-ch
                                                               `(err boom-enliven ,err)))))
                                                     #:catch
                                                     (lambda (err)
                                                       (async-channel-put result-ch
                                                         `(err counter-tick-2 ,err)))))
                                               #:catch
                                               (lambda (err)
                                                 (async-channel-put result-ch
                                                   `(err counter-tick-1 ,err)))))
                                         #:catch
                                         (lambda (err)
                                           (async-channel-put result-ch
                                             `(err car-factory-invoke ,err)))))
                                   #:catch
                                   (lambda (err)
                                     (async-channel-put result-ch
                                       `(err car-factory-enliven ,err)))))
                             #:catch
                             (lambda (err)
                               (async-channel-put result-ch
                                 `(err add-invoke ,err)))))
                       #:catch
                       (lambda (err)
                         (async-channel-put result-ch
                           `(err add-enliven ,err)))))
                 #:catch
                 (lambda (err)
                   (printf "[client] echo invocation broke: ~v~n" err)
                   (async-channel-put result-ch `(err invoke ,err)))))
           #:catch
           (lambda (err)
             (printf "[client] enliven broke: ~v~n" err)
             (async-channel-put result-ch `(err enliven ,err))))))
    ;; Wait up to 15s for all four round-trips (echo + add +
    ;; cap-passing + break).
    (define reply (sync/timeout 15.0 result-ch))
    (cond
      [(and (pair? reply) (eq? (car reply) 'ok))
       (match-define
         `(ok (echo ,_echo-r)
              (add ,add-r)
              (counter ,n0 ,n1)
              (boom-broke ,boom-broke?))
         reply)
       (cond
         [(not (equal? add-r 5))
          (printf "FAIL: add returned ~v, expected 5 (real result routing failed)~n" add-r)
          (exit 1)]
         [(not (and (equal? n0 0) (equal? n1 1)))
          (printf "FAIL: counter ticks (~v, ~v), expected (0, 1) (cap-passing or stateful-cap-routing failed)~n"
                  n0 n1)
          (exit 1)]
         [(not boom-broke?)
          (printf "FAIL: boom should have broken (Break route failed)~n")
          (exit 1)]
         [else
          (printf "OK: pancake-backed Goblins echo + add + cap-passing + break round-tripped via stock Goblins client~n")])]
      [reply
       (printf "FAIL: ~v~n" reply)
       (exit 1)]
      [else
       (printf "FAIL: timeout~n")
       (exit 2)])))

;; ─── Main module — dispatch + main-module scenarios ────────────────

(require racket/list
         racket/match
         "pancake-ffi.rkt"
         "tcp-bridge.rkt")

(file-stream-buffer-mode (current-output-port) 'line)
(file-stream-buffer-mode (current-error-port) 'line)

;; ─── Shared helpers ────────────────────────────────────────────────

(define (state-name s)
  (cond
    [(= s PANCAKE_SESSION_NEGOTIATING) "Negotiating"]
    [(= s PANCAKE_SESSION_OPEN) "Open"]
    [(= s PANCAKE_SESSION_CLOSED) "Closed"]
    [else (format "Unknown(~a)" s)]))

(define (abort-reason-name k)
  (cond
    [(= k PANCAKE_ABORT_REASON_GRACEFUL_SHUTDOWN) "GracefulShutdown"]
    [(= k PANCAKE_ABORT_REASON_VERSION_MISMATCH) "VersionMismatch"]
    [(= k PANCAKE_ABORT_REASON_PROTOCOL_ERROR) "ProtocolError"]
    [else (format "AbortReasonKind(~a)" k)]))

(define (await-open! peer label [timeout-s 5])
  (define deadline (+ (current-inexact-milliseconds) (* timeout-s 1000)))
  (let loop ([prev #f])
    (define s (pancake-peer-session-state peer))
    (unless (equal? prev s)
      (printf "[~a] session-state → ~a~n" label (state-name s)))
    (cond
      [(= s PANCAKE_SESSION_OPEN) (printf "[~a] ✓ Open~n" label)]
      [(= s PANCAKE_SESSION_CLOSED)
       (error 'await-open! "[~a] session Closed before Open" label)]
      [(> (current-inexact-milliseconds) deadline)
       (error 'await-open! "[~a] timeout after ~as in state ~a"
              label timeout-s (state-name s))]
      [else (sleep 0.05) (loop s)])))

(define (drain-session-established peer label)
  (define ev (pancake-peer-poll-event-session-established peer))
  (when ev
    (printf "[~a] SessionEstablished — partner-locator=~v~n"
            label (cadr ev))))

;; A deterministic seed lets paired processes log matching pubkeys
;; (cosmetic; the keys are independent per side, just predictable).
(define (seed-bytes-for label)
  (define b (make-bytes 32 0))
  (define src (string->bytes/utf-8 label))
  (bytes-copy! b 0 src 0 (min 32 (bytes-length src)))
  b)

(define (make-tcp-peer-for! label partner-label)
  (cond
    [(equal? (getenv "PANCAKE_STUB_KEYS") "1")
     (printf "[~a] using stub-keyed handshake (PANCAKE_STUB_KEYS=1)~n" label)
     (pancake-peer-new-advanced label partner-label
                                PANCAKE_CODEC_SYRUP
                                PANCAKE_CAPTP_VERSION_PRESPEC)]
    [else
     (define kp (pancake-keypair-from-seed (seed-bytes-for label)))
     (printf "[~a] using Ed25519-keyed handshake; pubkey first 4 bytes: ~v~n"
             label (subbytes (pancake-keypair-pubkey kp) 0 4))
     (pancake-peer-new kp PANCAKE_CODEC_SYRUP)]))

;; ─── handshake-self-in-process ─────────────────────────────────────

(define (run-handshake-self-in-process)
  ;; Two stub-keyed peers shuttle bytes directly between their inbound
  ;; / outbound queues — no socket, no real crypto. Sanity-checks the
  ;; pancake-ffi bindings end-to-end + lays the groundwork for the
  ;; graceful-abort-send scenario (which extends the same setup with
  ;; an Abort exchange).
  (define (shuttle! from to label)
    (let loop ([n 0])
      (cond
        [(pancake-peer-has-outbound from)
         (define frame (pancake-peer-take-outbound from))
         (when frame
           (printf "  [~a] frame size=~a bytes~n" label (bytes-length frame))
           (pancake-peer-feed-inbound to frame)
           (loop (add1 n)))]
        [else n])))
  (define (step! peer label)
    (define-values (kind _deadline) (pancake-peer-step peer))
    (printf "  step(~a) → kind=~a~n" label kind))
  (printf "pancake-ffi version: ~a~n" (pancake-version))
  (printf "Using libpancake at: ~a~n" (current-pancake-lib))
  (define a (pancake-peer-new-advanced "alice" "bob"
                                       PANCAKE_CODEC_SYRUP
                                       PANCAKE_CAPTP_VERSION_PRESPEC))
  (define b (pancake-peer-new-advanced "bob" "alice"
                                       PANCAKE_CODEC_SYRUP
                                       PANCAKE_CAPTP_VERSION_PRESPEC))
  (printf "✓ Created two pancake peers~n")
  ;; Stub-keyed peers still need a locator argument (the API requires
  ;; transport + designator uniformly even when no signing happens).
  (pancake-peer-send-start-session a "memory" "alice-vat")
  (pancake-peer-send-start-session b "memory" "bob-vat")
  (let loop ([rounds 0])
    (step! a "a")
    (step! b "b")
    (shuttle! a b "a→b")
    (shuttle! b a "b→a")
    (define sa (pancake-peer-session-state a))
    (define sb (pancake-peer-session-state b))
    (printf "  state(a)=~a state(b)=~a (round ~a)~n" sa sb rounds)
    (cond
      [(and (= sa PANCAKE_SESSION_OPEN) (= sb PANCAKE_SESSION_OPEN))
       (printf "✓ Both sessions Open after ~a rounds~n" rounds)]
      [(> rounds 10)
       (error 'run-handshake-self-in-process
              "handshake didn't open after 10 rounds; sa=~a sb=~a" sa sb)]
      [else (loop (add1 rounds))]))
  (drain-session-established a "a")
  (drain-session-established b "b")
  ;; Closing dance — send typed Abort from a to b; b's typed Abort
  ;; event fires. (graceful-abort-send isolates this for stricter
  ;; assertions; here it's the natural teardown after handshake.)
  (printf "→ Sending typed Abort from a to b…~n")
  (pancake-peer-send-abort a PANCAKE_ABORT_REASON_GRACEFUL_SHUTDOWN "goodbye")
  (step! a "a")
  (shuttle! a b "a→b")
  (step! b "b")
  (let ([abort-event (pancake-peer-poll-event-abort b)])
    (cond
      [abort-event
       (printf "✓ b received Abort kind=~a message=~v~n"
               (car abort-event) (cadr abort-event))]
      [else (error 'run-handshake-self-in-process "b did not receive Abort event")]))
  (pancake-peer-free a)
  (pancake-peer-free b)
  (printf "OK: handshake-self-in-process~n"))

;; ─── handshake-self-tcp ────────────────────────────────────────────

(define (run-handshake-self-tcp-server [port 22050])
  (printf "[server] pancake-ffi version: ~a~n" (pancake-version))
  (printf "[server] binding 127.0.0.1:~a, waiting for one client~n" port)
  (define listener (pancake-endpoint-tcp-listen "127.0.0.1" port))
  (define ep (pancake-endpoint-tcp-accept listener))
  (pancake-endpoint-tcp-listener-close listener)
  (printf "[server] accepted~n")
  (define peer (make-tcp-peer-for! "server" "client"))
  (define bridge
    (start-tcp-bridge! #:peer peer #:endpoint ep
                       #:transport "tcp-testing-only"
                       #:designator (format "127.0.0.1:~a" port)
                       #:label "server"))
  (await-open! peer "server")
  (drain-session-established peer "server")
  (sleep 0.5)
  (printf "[server] handshake complete; tearing down~n")
  (stop-tcp-bridge! bridge)
  (pancake-peer-free peer)
  (printf "OK: handshake-self-tcp (server)~n"))

(define (run-handshake-self-tcp-client [host "127.0.0.1"] [port 22050])
  (printf "[client] pancake-ffi version: ~a~n" (pancake-version))
  (printf "[client] dialing ~a:~a~n" host port)
  (define ep
    (let retry ([attempts 20])
      (with-handlers ([exn:fail?
                       (lambda (_)
                         (cond
                           [(zero? attempts)
                            (error 'run-handshake-self-tcp-client
                                   "could not connect to ~a:~a" host port)]
                           [else
                            (sleep 0.1)
                            (retry (sub1 attempts))]))])
        (pancake-endpoint-tcp-connect host port))))
  (printf "[client] connected~n")
  (define peer (make-tcp-peer-for! "client" "server"))
  (define bridge
    (start-tcp-bridge! #:peer peer #:endpoint ep
                       #:transport "tcp-testing-only"
                       #:designator "client-side-no-listen"
                       #:label "client"))
  (await-open! peer "client")
  (drain-session-established peer "client")
  (sleep 0.5)
  (printf "[client] handshake complete; tearing down~n")
  (stop-tcp-bridge! bridge)
  (pancake-peer-free peer)
  (printf "OK: handshake-self-tcp (client)~n"))

;; ─── handshake-as-client-vs-spritely ───────────────────────────────

(define (run-handshake-as-client-vs-spritely [host "127.0.0.1"] [port 22045])
  (define (poll-and-print-events! peer label)
    (let loop ()
      (cond
        [(pancake-peer-poll-event-session-established peer)
         =>
         (lambda (ev)
           (printf "[~a] SessionEstablished — partner-locator=~v~n" label (cadr ev))
           (loop))]
        [(pancake-peer-poll-event-abort peer)
         =>
         (lambda (ev)
           (printf "[~a] !! Abort received: kind=~a (~a) message=~v~n"
                   label (car ev) (abort-reason-name (car ev)) (cadr ev))
           (loop))]
        [else (void)])))
  (printf "[dialer] pancake-ffi version: ~a~n" (pancake-version))
  (printf "[dialer] dialing Spritely Goblins at ~a:~a~n" host port)
  (define ep (pancake-endpoint-tcp-connect host port))
  (printf "[dialer] connected TCP~n")
  ;; Production-signed via the typed pancake-peer-new — pins V1_0 +
  ;; goblins_v1_0 (what Spritely speaks); the peer takes ownership
  ;; of the keypair (no explicit free later).
  (define kp (pancake-keypair-new))
  (printf "[dialer] pubkey first 8 bytes: ~v~n"
          (subbytes (pancake-keypair-pubkey kp) 0 8))
  (define peer (pancake-peer-new kp PANCAKE_CODEC_SYRUP))
  (define bridge
    (start-tcp-bridge! #:peer peer #:endpoint ep
                       #:transport "tcp-testing-only"
                       #:designator (format "~a:~a" host port)
                       #:label "dialer"))
  (define deadline (+ (current-inexact-milliseconds) 5000))
  (let loop ([prev #f])
    (define s (pancake-peer-session-state peer))
    (unless (equal? prev s)
      (printf "[dialer] session-state → ~a~n" (state-name s)))
    (poll-and-print-events! peer "dialer")
    (cond
      [(= s PANCAKE_SESSION_OPEN)
       (printf "[dialer] ✓ Open — Spritely accepted pancake's signed StartSession~n")
       (stop-tcp-bridge! bridge)
       (pancake-peer-free peer)
       (printf "OK: handshake-as-client-vs-spritely~n")]
      [(= s PANCAKE_SESSION_CLOSED)
       (printf "[dialer] !! Closed before Open~n")
       (stop-tcp-bridge! bridge)
       (pancake-peer-free peer)
       (exit 1)]
      [(> (current-inexact-milliseconds) deadline)
       (printf "[dialer] !! timeout after 5s in state ~a~n" (state-name s))
       (stop-tcp-bridge! bridge)
       (pancake-peer-free peer)
       (exit 2)]
      [else (sleep 0.05) (loop s)])))

;; ─── argument-roundtrip-string-int-list ───────────────────────────

(define (run-argument-roundtrip-string-int-list [host "127.0.0.1"] [port 22045])
  ;; C1 scenario: dial Spritely's seven-caps-peer; enliven the Echo
  ;; cap (the OCapN conformance suite's variadic-args target);
  ;; deliver a payload mixing String + Integer + List; assert the
  ;; resolution carries the same args back (the cap echoes).
  ;;
  ;; Low-level: drives pancake-ffi typed primitives directly
  ;; (pancake-peer-enliven-sturdyref + pancake-peer-send-deliver +
  ;; pancake-peer-poll-event-resolve). Doesn't go through captp.rkt
  ;; — the captp MVP is listen-only today; this scenario tests the
  ;; typed FFI shape that captp would eventually wrap.
  (define ECHO-SWISS-NUM
    (string->bytes/latin-1 "IO58l1laTyhcrgDKbEzFOO32MDd6zE5w"))
  (define ANSWER-ENLIVEN 100)
  (define ANSWER-DELIVER 200)
  (define DEADLINE-MS 5000)

  (printf "[arg-rt] pancake-ffi version: ~a~n" (pancake-version))
  (printf "[arg-rt] dialing Spritely seven-caps-peer at ~a:~a~n" host port)
  (define ep (pancake-endpoint-tcp-connect host port))
  (define kp (pancake-keypair-new))
  (define peer (pancake-peer-new kp PANCAKE_CODEC_SYRUP))
  (define bridge
    (start-tcp-bridge! #:peer peer #:endpoint ep
                       #:transport "tcp-testing-only"
                       #:designator (format "~a:~a" host port)
                       #:label "arg-rt"))

  ;; ── Handshake ────────────────────────────────────────────────
  (await-open! peer "arg-rt")
  (drain-session-established peer "arg-rt")

  ;; ── Enliven the Echo cap ─────────────────────────────────────
  ;; Construct a sturdyref pointing at Spritely's cap. The peer-id
  ;; field is unresolved (Spritely emits its own); use the receive-
  ;; only #f shape via a 0-length peer-id buffer if needed. The
  ;; current pancake-ffi enliven path requires a resolved peer-id;
  ;; use the partner peer-id we learned from the handshake (it's the
  ;; canonical SHA²-of-pubkey via A2/A3's accessor).
  (define partner-peer-id (pancake-peer-get-partner-peer-id peer))
  (unless partner-peer-id
    (error 'run-argument-roundtrip-string-int-list
           "partner peer-id not yet learned after Open"))
  (define sturdyref (pcakeref PANCAKE_REF_STURDY (vector partner-peer-id ECHO-SWISS-NUM)))
  (printf "[arg-rt] enlivening echo cap (swiss=~v)~n"
          (bytes->string/latin-1 ECHO-SWISS-NUM))
  (pancake-peer-enliven-sturdyref peer sturdyref)

  ;; Wait for the enliven Resolve event.
  (define enliven-deadline (+ (current-inexact-milliseconds) DEADLINE-MS))
  (define echo-far-ref
    (let loop ()
      (define ev (pancake-peer-poll-event-resolve peer))
      (cond
        [ev
         (define res (cadr ev))
         (unless (= (pcakeres-kind res) PANCAKE_RES_FULFILL)
           (error 'run-argument-roundtrip-string-int-list
                  "enliven resolved as Break: ~v" (pcakeres-payload res)))
         (define arg (pcakeres-payload res))
         (unless (= (pcakearg-kind arg) PANCAKE_ARG_REFERENCE)
           (error 'run-argument-roundtrip-string-int-list
                  "enliven Fulfill carried unexpected arg kind ~a; expected REFERENCE"
                  (pcakearg-kind arg)))
         (pcakearg-payload arg)]
        [(> (current-inexact-milliseconds) enliven-deadline)
         (error 'run-argument-roundtrip-string-int-list "timeout waiting for enliven Resolve")]
        [else (sleep 0.02) (loop)])))
  (printf "[arg-rt] ✓ echo cap enlivened (Far ref kind=~a)~n"
          (pcakeref-kind echo-far-ref))

  ;; ── Send Deliver with mixed-type args ────────────────────────
  ;; The payload exercises C1's typed List variant: a top-level
  ;; arg-list wrapping the String + Integer + nested-List shape
  ;; the scenario name announces.
  (define test-args
    (list
     (arg-list (list (arg-string "hello")
                     (arg-integer 42)
                     (arg-list (list (arg-string "nested-a")
                                     (arg-string "nested-b")))))))
  (printf "[arg-rt] sending Deliver with mixed-type list args + answer=~a~n" ANSWER-DELIVER)
  (pancake-peer-send-deliver peer echo-far-ref test-args ANSWER-DELIVER)

  ;; ── Wait for the Resolve event ───────────────────────────────
  (define deliver-deadline (+ (current-inexact-milliseconds) DEADLINE-MS))
  (define deliver-result
    (let loop ()
      (define ev (pancake-peer-poll-event-resolve peer))
      (cond
        [(and ev (= (car ev) ANSWER-DELIVER))
         (define res (cadr ev))
         (unless (= (pcakeres-kind res) PANCAKE_RES_FULFILL)
           (error 'run-argument-roundtrip-string-int-list
                  "deliver resolved as Break: ~v" (pcakeres-payload res)))
         (pcakeres-payload res)]
        [ev
         ;; Some other Resolve; ignore + keep polling.
         (loop)]
        [(> (current-inexact-milliseconds) deliver-deadline)
         (error 'run-argument-roundtrip-string-int-list "timeout waiting for deliver Resolve")]
        [else (sleep 0.02) (loop)])))

  ;; ── Assert structural round-trip ─────────────────────────────
  ;; Spritely's Echo cap is shaped `(lambda args args)` — it returns
  ;; its arglist. The OCapN spec's resolve wraps that arglist in a
  ;; single Fulfill arg. Different OCapN implementations make
  ;; slightly different choices about whether the outer wrap is
  ;; itself a List or just the first inner element; assert
  ;; structurally on the shape we sent.
  (printf "[arg-rt] result kind=~a~n" (pcakearg-kind deliver-result))
  (define (project pa)
    ;; Convert pcakearg to a Racket-native value for structural compare.
    (define k (pcakearg-kind pa))
    (define p (pcakearg-payload pa))
    (cond
      [(= k PANCAKE_ARG_STRING) (cons 'string p)]
      [(= k PANCAKE_ARG_INTEGER) (cons 'integer p)]
      [(= k PANCAKE_ARG_LIST) (cons 'list (map project p))]
      [(= k PANCAKE_ARG_SYMBOL) (cons 'symbol p)]
      [(= k PANCAKE_ARG_BYTES) (cons 'bytes p)]
      [(= k PANCAKE_ARG_BOOL) (cons 'bool p)]
      [(= k PANCAKE_ARG_VOID) '(void)]
      [else (list 'unknown k)]))
  (define projected (project deliver-result))
  (printf "[arg-rt] projected echo result: ~v~n" projected)

  ;; Spritely's Echo cap returns its arglist as a SEQUENCE (each
  ;; arg of the resolve is one of the original args). The resolve's
  ;; Fulfill carries a SINGLE arg; with a single op:deliver arg
  ;; that arg is the input wrapped in a list, OR the input list
  ;; directly. We sent ONE outer list containing String+Integer+List.
  ;; Spritely's echo returns the args as a record; depending on
  ;; encoding we expect either:
  ;;   (list (string . "hello") (integer . 42) (list . (...)))
  ;; OR the outer arg-list directly.
  ;;
  ;; Walk down through any single-list wrapping to find the
  ;; matching shape.
  (define (find-string-int-list arg)
    ;; Match `(cons 'list items)` (the pair shape `project` produces:
    ;; car='list, cdr=the projected items list).
    (match arg
      [(cons 'list items)
       (cond
         [(and (= (length items) 3)
               (equal? (car (first items)) 'string)
               (equal? (car (second items)) 'integer))
          items]
         [(and (= (length items) 1) (pair? (first items))
               (eq? (car (first items)) 'list))
          (find-string-int-list (first items))]
         [else #f])]
      [_ #f]))
  (define found (find-string-int-list projected))
  (unless found
    (error 'run-argument-roundtrip-string-int-list
           "expected String+Integer+List shape in echo response; got ~v" projected))

  ;; Assert the specific values.
  (unless (equal? (cdr (first found)) "hello")
    (error 'run-argument-roundtrip-string-int-list
           "expected String \"hello\" at index 0; got ~v" (first found)))
  (unless (= (cdr (second found)) 42)
    (error 'run-argument-roundtrip-string-int-list
           "expected Integer 42 at index 1; got ~v" (second found)))
  (define nested (cdr (third found)))
  (unless (and (= (length nested) 2)
               (equal? (cdr (first nested)) "nested-a")
               (equal? (cdr (second nested)) "nested-b"))
    (error 'run-argument-roundtrip-string-int-list
           "expected nested List [\"nested-a\", \"nested-b\"] at index 2; got ~v" (third found)))
  (printf "[arg-rt] ✓ String / Integer / nested-List all round-tripped intact~n")

  (stop-tcp-bridge! bridge)
  (pancake-peer-free peer)
  (printf "OK: argument-roundtrip-string-int-list~n"))

;; ─── graceful-abort-send ───────────────────────────────────────────

(define (run-graceful-abort-send)
  ;; Isolated test of the typed-Abort path through A4's
  ;; peek-before-consume idiom. Setup is the in-process shuttle from
  ;; handshake-self-in-process; assertions tighten on the Abort
  ;; specifically.
  (define (shuttle-once! from to)
    (let loop ()
      (cond
        [(pancake-peer-has-outbound from)
         (define f (pancake-peer-take-outbound from))
         (when f (pancake-peer-feed-inbound to f) (loop))]
        [else (void)])))
  (define (step! peer)
    (define-values (kind _) (pancake-peer-step peer))
    kind)
  (printf "→ Setting up two stub-keyed peers + handshake…~n")
  (define a (pancake-peer-new-advanced "alice" "bob"
                                       PANCAKE_CODEC_SYRUP
                                       PANCAKE_CAPTP_VERSION_PRESPEC))
  (define b (pancake-peer-new-advanced "bob" "alice"
                                       PANCAKE_CODEC_SYRUP
                                       PANCAKE_CAPTP_VERSION_PRESPEC))
  (pancake-peer-send-start-session a "memory" "alice-vat")
  (pancake-peer-send-start-session b "memory" "bob-vat")
  (let loop ([rounds 0])
    (step! a) (step! b)
    (shuttle-once! a b)
    (shuttle-once! b a)
    (cond
      [(and (= (pancake-peer-session-state a) PANCAKE_SESSION_OPEN)
            (= (pancake-peer-session-state b) PANCAKE_SESSION_OPEN))
       (printf "✓ Both Open after ~a rounds~n" rounds)]
      [(> rounds 10) (error 'run-graceful-abort-send "handshake stalled")]
      [else (loop (add1 rounds))]))
  ;; Drain SessionEstablished so the Abort is the next pending event
  ;; on b's queue.
  (drain-session-established a "a")
  (drain-session-established b "b")
  (printf "→ Sending typed Abort (GracefulShutdown) from a to b…~n")
  (pancake-peer-send-abort a PANCAKE_ABORT_REASON_GRACEFUL_SHUTDOWN "goodbye")
  (step! a)
  (shuttle-once! a b)
  (step! b)
  ;; A4 peek-before-consume — assert (a) the peek returns the
  ;; dedicated AbortReceived discriminator (the post-C2 follow-up
  ;; that gave inbound op:abort its own PancakeEventKind variant
  ;; rather than the PeerReady catch-all), AND (b) two consecutive
  ;; peeks return the same kind (no consume on either peek).
  (define peek1 (pancake-peer-peek-event-kind b))
  (define peek2 (pancake-peer-peek-event-kind b))
  (unless peek1
    (error 'run-graceful-abort-send "peek 1 returned #f; expected a pending event"))
  (unless (equal? peek1 peek2)
    (error 'run-graceful-abort-send
           "peek not idempotent: first ~a vs second ~a" peek1 peek2))
  (unless (= peek1 PANCAKE_EVENT_KIND_ABORT_RECEIVED)
    (error 'run-graceful-abort-send
           "expected peek-event-kind = ABORT_RECEIVED (~a); got ~a"
           PANCAKE_EVENT_KIND_ABORT_RECEIVED peek1))
  (unless (pancake-peer-has-event b)
    (error 'run-graceful-abort-send "has-event 0 after two peeks; peek consumed"))
  (printf "✓ peek-event-kind idempotent + matches ABORT_RECEIVED (event still pending)~n")
  ;; Now consume via the typed accessor; assert kind + message
  ;; round-trip.
  (define ev (pancake-peer-poll-event-abort b))
  (unless ev
    (error 'run-graceful-abort-send "typed poll-event-abort returned #f after peek"))
  (define abort-kind (car ev))
  (define abort-msg (cadr ev))
  (unless (= abort-kind PANCAKE_ABORT_REASON_GRACEFUL_SHUTDOWN)
    (error 'run-graceful-abort-send
           "expected abort kind GRACEFUL_SHUTDOWN, got ~a (~a)"
           abort-kind (abort-reason-name abort-kind)))
  (unless (equal? abort-msg "goodbye")
    (error 'run-graceful-abort-send
           "expected abort message \"goodbye\", got ~v" abort-msg))
  (printf "✓ typed Abort projected: kind=~a (~a) message=~v~n"
          abort-kind (abort-reason-name abort-kind) abort-msg)
  ;; The Abort closed b's session by side effect of record_recv +
  ;; the abort-projection. Drive one more step on b so the close
  ;; transition fully propagates onto session state.
  (step! b)
  (define sb (pancake-peer-session-state b))
  (unless (= sb PANCAKE_SESSION_CLOSED)
    (error 'run-graceful-abort-send
           "expected b session-state = CLOSED post-abort, got ~a (~a)"
           sb (state-name sb)))
  (printf "✓ b session-state = CLOSED post-abort~n")
  (pancake-peer-free a)
  (pancake-peer-free b)
  (printf "OK: graceful-abort-send~n"))

;; ─── ocapn-uri-parse ───────────────────────────────────────────────

(define (run-ocapn-uri-parse)
  ;; Unit-test exercise of the C3 FFI URI parser (pancake-ocapn-uri-parse).
  ;; Verifies both shapes the OCapN spec admits:
  ;;
  ;;   1. peer-locator form (Spritely's bootstrap-cap convention) —
  ;;      `ocapn://<designator>.<transport>?<hints>` with no `/s/`
  ;;      path. Designator IS the swissnum-as-string for seven-caps-
  ;;      peer style URLs; swissnum field projects to #f.
  ;;
  ;;   2. spec sturdyref form — `ocapn://<designator>.<transport>/s/<base64url>`
  ;;      with the swissnum carried in the `/s/` path; the parser
  ;;      base64url-no-pad decodes it into the swissnum field.
  ;;
  ;; Also checks reject-on-bad-URI returns #f + populates last-error.
  ;;
  ;; Replaces what otherwise would be ~50 lines of Racket-side URL
  ;; parsing per binding — pancake-runtime's URI parser is the single
  ;; source of truth.

  (printf "→ Parsing Spritely bootstrap-cap URL (peer-locator form)…~n")
  (define u1
    (pancake-ocapn-uri-parse
     "ocapn://IO58l1laTyhcrgDKbEzFOO32MDd6zE5w.tcp-testing-only?host=127.0.0.1&port=22045"))
  (unless (equal? (ocapn-uri-transport u1) "tcp-testing-only")
    (error 'run-ocapn-uri-parse
           "expected transport=\"tcp-testing-only\", got ~v" (ocapn-uri-transport u1)))
  (unless (equal? (ocapn-uri-designator u1) "IO58l1laTyhcrgDKbEzFOO32MDd6zE5w")
    (error 'run-ocapn-uri-parse
           "expected designator=\"IO58l1laTyhcrgDKbEzFOO32MDd6zE5w\", got ~v"
           (ocapn-uri-designator u1)))
  (unless (eq? (ocapn-uri-swissnum u1) #f)
    (error 'run-ocapn-uri-parse
           "peer-locator URI must project swissnum=#f, got ~v" (ocapn-uri-swissnum u1)))
  (printf "  ✓ transport=~v designator=~v swissnum=#f (peer-locator form)~n"
          (ocapn-uri-transport u1) (ocapn-uri-designator u1))

  (printf "→ Parsing OCapN spec sturdyref form…~n")
  ;; base64url-no-pad of [0,1,2,3,0xff,0xfe,0xfd,0xfc] = "AAECA__-_fw"
  ;; (matches the fixture in crates/runtime/pancake-runtime/src/locator_uri.rs).
  (define u2 (pancake-ocapn-uri-parse "ocapn://abc.iroh/s/AAECA__-_fw"))
  (unless (equal? (ocapn-uri-transport u2) "iroh")
    (error 'run-ocapn-uri-parse
           "expected transport=\"iroh\", got ~v" (ocapn-uri-transport u2)))
  (unless (equal? (ocapn-uri-designator u2) "abc")
    (error 'run-ocapn-uri-parse
           "expected designator=\"abc\", got ~v" (ocapn-uri-designator u2)))
  (define expected-swiss (bytes 0 1 2 3 #xff #xfe #xfd #xfc))
  (unless (equal? (ocapn-uri-swissnum u2) expected-swiss)
    (error 'run-ocapn-uri-parse
           "expected swissnum=~v, got ~v" expected-swiss (ocapn-uri-swissnum u2)))
  (printf "  ✓ transport=~v designator=~v swissnum=~v (sturdyref form, base64url decoded)~n"
          (ocapn-uri-transport u2) (ocapn-uri-designator u2) (ocapn-uri-swissnum u2))

  (printf "→ Asserting parse-rejects-non-ocapn-scheme raises…~n")
  (define raised?
    (with-handlers ([exn:fail? (lambda (e) #t)])
      (pancake-ocapn-uri-parse "http://example.com/")
      #f))
  (unless raised?
    (error 'run-ocapn-uri-parse
           "expected http:// URL to be rejected; got no error"))
  (printf "  ✓ non-ocapn scheme rejected (raised exn:fail with parse-failure diagnostic)~n")

  (printf "OK: ocapn-uri-parse~n"))

;; ─── Dispatcher ────────────────────────────────────────────────────
;;
;; CLI parsing is hand-rolled rather than via `racket/cmdline`'s
;; `command-line` macro because that macro requires all flags to
;; precede positional args. Catalog-side pixi tasks follow the
;; documented natural shape `bash run.sh scenario <id> [--side <name>]`
;; (scenario id first; flags after); the runner has to accept that
;; order. Walk argv: first non-flag bare arg is the scenario id;
;; remaining bare args are positional rest; --side <value> sets the
;; side parameter wherever it appears.

(define side (make-parameter #f))

(define (parse-args argv)
  ;; argv: vector of strings → (values scenario-id positional-rest)
  ;; Side effect: sets `side` parameter when --side <value> is found.
  (define positional '())
  (let loop ([i 0])
    (cond
      [(>= i (vector-length argv)) (void)]
      [(equal? (vector-ref argv i) "--side")
       (unless (< (+ i 1) (vector-length argv))
         (error 'scenario-runner "--side requires an argument"))
       (side (vector-ref argv (+ i 1)))
       (loop (+ i 2))]
      [else
       (set! positional (cons (vector-ref argv i) positional))
       (loop (+ i 1))]))
  (set! positional (reverse positional))
  (when (null? positional)
    (error 'scenario-runner
           "expected scenario-id as first positional arg; got argv=~v" argv))
  (values (car positional) (cdr positional)))

(define-values (scenario-id positional-rest)
  (parse-args (current-command-line-arguments)))

(case scenario-id
  [("handshake-self-in-process")
   (run-handshake-self-in-process)]

  [("handshake-self-tcp")
   (case (side)
     [("server")
      (cond [(pair? positional-rest)
             (run-handshake-self-tcp-server (string->number (car positional-rest)))]
            [else (run-handshake-self-tcp-server)])]
     [("client")
      (cond [(>= (length positional-rest) 2)
             (run-handshake-self-tcp-client
              (car positional-rest)
              (string->number (cadr positional-rest)))]
            [else (run-handshake-self-tcp-client)])]
     [else (error 'scenario-runner
                  "handshake-self-tcp requires --side server|client; got ~v" (side))])]

  [("handshake-as-client-vs-spritely")
   (cond [(>= (length positional-rest) 2)
          (run-handshake-as-client-vs-spritely
           (car positional-rest)
           (string->number (cadr positional-rest)))]
         [else (run-handshake-as-client-vs-spritely)])]

  [("echo-as-host-vs-spritely")
   (case (side)
     [("host")
      (define run-host (dynamic-require '(submod "scenario-runner.rkt" pancake-host-side)
                                        'run-echo-host))
      (cond [(>= (length positional-rest) 2)
             (run-host (car positional-rest)
                       (string->number (cadr positional-rest)))]
            [else (run-host "127.0.0.1" 22046)])]
     [("client")
      (define run-client (dynamic-require '(submod "scenario-runner.rkt" stock-client-side)
                                          'run-stock-echo-client))
      (cond [(>= (length positional-rest) 2)
             (run-client (car positional-rest)
                         (string->number (cadr positional-rest)))]
            [else (run-client "127.0.0.1" 22046)])]
     [else (error 'scenario-runner
                  "echo-as-host-vs-spritely requires --side host|client; got ~v" (side))])]

  [("graceful-abort-send")
   (run-graceful-abort-send)]

  [("argument-roundtrip-string-int-list")
   (cond [(>= (length positional-rest) 2)
          (run-argument-roundtrip-string-int-list
           (car positional-rest)
           (string->number (cadr positional-rest)))]
         [else (run-argument-roundtrip-string-int-list)])]

  [("ocapn-uri-parse")
   (run-ocapn-uri-parse)]

  [else
   (error 'scenario-runner
          "unknown scenario ~v; see reference/tests/pancake-ffi-bindings/SCENARIOS.md"
          scenario-id)])
