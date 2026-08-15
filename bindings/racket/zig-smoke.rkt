#lang racket/base
;; Racket dogfood of the Zig pancake C ABI archives, through the idiomatic
;; composable modules — the CapTP session surface in `pancake.rkt` plus one
;; module per transport archive (`pancake-tcp.rkt`, `pancake-inproc.rkt`),
;; composed à la carte exactly as a C consumer links the archives. Everything
;; rides the byte-fed host archive (libpancake_host, ADR-0072 / ADR-0079)
;; with native Racket values — no FFI in sight for an application; the
;; plumbing sections below reach the binding's own `private/` modules to
;; script wire faults and to shuttle host frames over the C transport
;; endpoints, which is dogfood work, not application surface. This is the
;; consumer `zig build bindings` runs.

(require net/base64
         racket/random
         racket/runtime-path
         "pancake.rkt"
         "pancake-tcp.rkt"
         "pancake-inproc.rkt"
         "pancake-onion.rkt"
         "pancake-iroh.rkt"
         ;; Binding-internal plumbing, for the scripted sections only: the
         ;; byte-fed session constructors and pump pieces, the host FFI's
         ;; open/fetch verbs, the local vat half (`bind-export!` / `vat-resolve-target`),
         ;; and the shared cstruct vocabulary.
         "private/session.rkt"
         "private/host.rkt"
         (only-in "private/iroh.rkt" iroh-endpoint-record-failure!)
         "private/locator.rkt"
         "private/async.rkt"
         "private/byte-channel.rkt"
         (only-in "private/finalizer-diagnostics.rkt"
                  record-runtime-failure! run-native-finalizer!)
         (only-in "private/ws-transport.rkt" ws-transport)
         (only-in "relay.rkt" relay-pump exn:fail:relay?
                  exn:fail:relay-primary exn:fail:relay-secondary)
         "private/pump.rkt"
         "private/action.rkt"
         (only-in "private/dial.rkt" retain-host-cleanup-failure!)
         "private/promise.rkt"
         "private/gc.rkt"
         "private/vat.rkt"
         "private/ffi-host.rkt"
         "private/ffi-shared.rkt"
         "private/errors.rkt"
         "private/constants.rkt"
         "private/codec.rkt"
         (only-in "private/loop.rkt"
                  open-driver-loop driver-loop-start! driver-loop-abort!
                  loop-background-failed!
                  driver-loop-has-transport?
                  loop-listen! loop-listener-ready! loop-listener-locator
                  loop-listener-close!)
         "private/native-parent.rkt"
         (only-in "private/value.rkt" make-ref/internal)
         racket/tcp)

;; Line-buffer the OK lines so a failure can never swallow the progress that
;; preceded it.
(file-stream-buffer-mode (current-output-port) 'line)

;; Each call models a distinct peer unless it explicitly supplies a Host.
;; Accordingly each helper call opens one test-owned Runtime; sharing one here
;; would silently reuse peer identity and reject a second session to the same
;; partner as a duplicate pair. The suite retires every Runtime at teardown.
(define tcp-provider-for-smoke (tcp-provider))
(define extra-runtimes (box '()))
(define (open-test-session loc #:provider [provider tcp-provider-for-smoke]
                           #:connector [connector #f] #:adopt-host [adopted-host #f]
                           #:codec [codec #f] #:captp-version [captp-version #f]
                           #:features [features #f]
                           #:handshake-timeout-ms
                           [handshake-timeout-ms HANDSHAKE-TIMEOUT-MS])
  (define runtime
    (open-runtime
     #:providers (and (not connector) (list provider))
     #:connectors (and connector (list connector))
     #:adopt-host adopted-host #:codec codec
     #:captp-version captp-version #:features features
     #:handshake-timeout-ms handshake-timeout-ms))
  (set-box! extra-runtimes (cons runtime (unbox extra-runtimes)))
  (runtime-connect runtime loc))

(define (fail msg) (eprintf "racket zig-smoke FAILED: ~a\n" msg) (exit 1))
(define (expect cond msg) (unless cond (fail msg)))

;; The generated return-code inventory is the same reflected C ABI family the
;; binding branches on. `check-with` must leave OK alone and translate every
;; other member without collapsing its number, rereading its diagnostic, or
;; adding retry policy at the translation seam.
(for ([entry (in-list ABI-RETURN-CODES)])
  (define name (car entry))
  (define code (cdr entry))
  (define reads (box 0))
  (define diagnostic (format "exact diagnostic for ~a" name))
  (define translated
    (with-handlers ([exn:fail:pancake? values])
      (check-with code
                  (lambda ()
                    (set-box! reads (add1 (unbox reads)))
                    diagnostic))
      'ok))
  (cond
    [(= code OK)
     (expect (and (eq? translated 'ok) (zero? (unbox reads)))
             "ABI translation read a diagnostic or raised for OK")]
    [else
     (expect (and (exn:fail:pancake? translated)
                  (= code (exn:fail:pancake-code translated))
                  (= 1 (unbox reads))
                  (regexp-match? (regexp-quote diagnostic)
                                 (exn-message translated)))
             (format "ABI translation changed or retried ~a" name))]))

(printf "racket zig-smoke OK: every reflected C ABI return code translates exactly once\n")

(expect (with-handlers ([exn:fail? (lambda (_) #t)])
          (make-byte-connector '() void)
          #f)
        "byte connectors reject an empty transport advertisement")
(expect (with-handlers ([exn:fail? (lambda (_) #t)])
          (make-byte-connector '("tcp" "tcp") void)
          #f)
        "byte connectors reject duplicate transport symbols")

(define explicit-grace-host (make-fresh-host))
(expect (with-handlers ([exn:fail? (lambda (_) #t)])
          (host-close! explicit-grace-host #:pending 'finish)
          #f)
        "finish close requires an explicit finite or unbounded grace budget")
(expect (not (unbox (host-released? explicit-grace-host)))
        "an invalid finish close left its Host usable")
(host-close! explicit-grace-host)

;; A Host-owned background worker has no caller stack. Its exact first failure
;; survives on the Host and is returned by explicit close rather than becoming
;; an unobserved thread exception.
(define background-failure-host (make-fresh-host))
(define background-failure
  (exn:fail "background exporter serve failed" (current-continuation-marks)))
(void (record-host-runtime-failure! background-failure-host background-failure))
(define background-consequence
  (exn:fail "second exporter failure" (current-continuation-marks)))
(void (record-host-runtime-failure! background-failure-host background-consequence))
(define background-chain (unbox (host-runtime-failure background-failure-host)))
(expect (and (eq? (terminal-failure-chain-primary background-chain)
                  background-failure)
             (eq? (terminal-failure-chain-secondary background-chain)
                  background-consequence)
             (= (terminal-failure-chain-secondary-count background-chain) 1))
        "Host background failures retain the first consequence and total")
(define observed-background-failure
  (with-handlers ([exn:fail? values])
    (host-close! background-failure-host)
    #f))
(expect (eq? observed-background-failure background-failure)
        "Host close returns its exact background worker failure")
(define repeated-background-failure
  (with-handlers ([exn:fail? values])
    (host-close! background-failure-host)
    #f))
(expect (eq? repeated-background-failure background-failure)
        "repeated Host close returns the same background worker failure")

;; Failed-dial cleanup has its own failure channel. An earlier cleanup failure
;; cannot stop the remaining rollback/report work or be replaced by a later
;; failure, and explicit Host close remains its deterministic observer.
(define dial-cleanup-failure-host (make-fresh-host))
(define first-dial-cleanup-failure
  (exn:fail "dial session rollback failed" (current-continuation-marks)))
(define later-dial-cleanup-failure
  (exn:fail "dial refusal report failed" (current-continuation-marks)))
(define dial-cleanup-continued? (box #f))
(retain-host-cleanup-failure!
 dial-cleanup-failure-host
 (lambda () (raise first-dial-cleanup-failure)))
(set-box! dial-cleanup-continued? #t)
(retain-host-cleanup-failure!
 dial-cleanup-failure-host
 (lambda () (raise later-dial-cleanup-failure)))
(expect (unbox dial-cleanup-continued?)
        "a failed dial cleanup does not stop later rollback work")
(define observed-dial-cleanup-failure
  (with-handlers ([exn:fail? values])
    (host-close! dial-cleanup-failure-host)
    #f))
(expect (eq? observed-dial-cleanup-failure first-dial-cleanup-failure)
        "Host close returns the first exact failed-dial cleanup failure")

;; The native driver loop owns both its resident park thread and its retirement
;; worker. A failure on either background stack settles onto the adopted Host
;; rather than ending as an unobserved Racket thread exception.
(define loop-background-failure-host (make-fresh-host))
(define loop-for-background-failure
  (open-driver-loop #:host loop-background-failure-host))
(define loop-background-failure
  (exn:fail "driver loop background failed" (current-continuation-marks)))
(loop-background-failed! loop-for-background-failure loop-background-failure)
(define observed-loop-background-failure
  (with-handlers ([exn:fail? values])
    (host-close! loop-background-failure-host)
    #f))
(expect (eq? observed-loop-background-failure loop-background-failure)
        "Host close returns its exact driver-loop background failure")

;; The sidecar iroh readiness thread has the raw endpoint as its owner. Its
;; exact first failure wakes parked work and is re-observed at endpoint close,
;; including after native resources have already been released.
(define iroh-background-failure-endpoint
  (open-iroh-endpoint (make-iroh-config IROH-REACH-LOCAL-DISCOVERY)))
(define iroh-background-failure
  (exn:fail "iroh readiness loop failed" (current-continuation-marks)))
(void
 (iroh-endpoint-record-failure! iroh-background-failure-endpoint
                                iroh-background-failure))
(define observed-iroh-background-failure
  (with-handlers ([exn:fail? values])
    (iroh-endpoint-close! iroh-background-failure-endpoint)
    #f))
(expect (eq? observed-iroh-background-failure iroh-background-failure)
        "iroh endpoint close returns its exact readiness-loop failure")
(define repeated-iroh-background-failure
  (with-handlers ([exn:fail? values])
    (iroh-endpoint-close! iroh-background-failure-endpoint)
    #f))
(expect (eq? repeated-iroh-background-failure iroh-background-failure)
        "repeated iroh endpoint close retains its readiness-loop failure")

;; A WebSocket read exception is not EOF. The transport preserves it exactly,
;; joins its close worker, and keeps the earlier read failure ahead of a later
;; close failure at every observing surface.
(define websocket-read-failure
  (exn:fail "WebSocket receive failed" (current-continuation-marks)))
(define websocket-close-failure
  (exn:fail "WebSocket close failed" (current-continuation-marks)))
(define failed-websocket-transport
  (ws-transport
   "ws://failure.invalid/"
   #:connect (lambda (_url) 'fake-websocket)
   #:recv (lambda (_connection #:payload-type _payload-type)
            (raise websocket-read-failure))
   #:send (lambda (_connection _bytes #:payload-type _payload-type) (void))
   #:close (lambda (_connection) (raise websocket-close-failure))))
(define observed-websocket-read-failure
  (with-handlers ([exn:fail? values])
    ((async-transport-read-some! failed-websocket-transport) (make-semaphore 0))
    #f))
(expect (eq? observed-websocket-read-failure websocket-read-failure)
        "WebSocket read preserves its exact receive exception")
(define observed-websocket-close-failure
  (with-handlers ([exn:fail? values])
    ((async-transport-close! failed-websocket-transport))
    #f))
(expect (eq? observed-websocket-close-failure websocket-read-failure)
        "WebSocket close retains the earlier receive exception")
(define repeated-websocket-close-failure
  (with-handlers ([exn:fail? values])
    ((async-transport-close! failed-websocket-transport))
    #f))
(expect (eq? repeated-websocket-close-failure websocket-read-failure)
        "repeated WebSocket close retains its first task failure")

;; Callerless drain fires belong to their Host. One failed fire cannot stop a
;; sibling, and explicit close returns the exact first scheduling failure.
(define drain-fire-failure-host (make-fresh-host))
(define drain-fire-failure
  (exn:fail "deferred drain fire failed" (current-continuation-marks)))
(define later-drain-fire-ran? (box #f))
(run-drain-effects!
 drain-fire-failure-host
 (drain-effects '()
                (list (lambda () (raise drain-fire-failure))
                      (lambda () (set-box! later-drain-fire-ran? #t)))
                #f
                #t))
(expect (unbox later-drain-fire-ran?)
        "a failed drain fire does not strand sibling effects")
(define observed-drain-fire-failure
  (with-handlers ([exn:fail? values])
    (host-close! drain-fire-failure-host)
    #f))
(expect (eq? observed-drain-fire-failure drain-fire-failure)
        "Host close returns the exact deferred-fire failure")

;; Establishment keeps its operation failure primary while retaining a failed
;; transport rollback on the Host that owns the attempted session.
(define establish-cleanup-host (make-fresh-host))
(define establish-primary-failure
  (exn:fail "session establishment failed" (current-continuation-marks)))
(define establish-close-failure
  (exn:fail "failed establishment transport close failed"
            (current-continuation-marks)))
(define failed-establish-transport
  (async-transport void void (lambda (_wake) eof)
                   (lambda () (raise establish-close-failure))))
(define observed-establish-primary
  (with-handlers ([exn:fail? values])
    (establish-closing-transport
     establish-cleanup-host
     failed-establish-transport
     (lambda () (raise establish-primary-failure)))
    #f))
(expect (eq? observed-establish-primary establish-primary-failure)
        "establishment preserves its primary operation failure")
(define observed-establish-close-failure
  (with-handlers ([exn:fail? values])
    (host-close! establish-cleanup-host)
    #f))
(expect (eq? observed-establish-close-failure establish-close-failure)
        "Host close returns failed-establishment cleanup failure")

;; A collected wrapper cannot own its own release failure, and the collector
;; is not an application exception boundary. The process journal normalizes
;; the failure into the same typed vocabulary without escaping the callback.
(void (take-runtime-failures!))
(define finalizer-release-failure
  (exn:fail "native finalizer release failed" (current-continuation-marks)))
(run-native-finalizer! "test.finalize" (lambda () (raise finalizer-release-failure)))
(define recorded-finalizer-failures (take-runtime-failures!))
(expect (and (= (length recorded-finalizer-failures) 1)
             (equal? (failure-event-operation (car recorded-finalizer-failures))
                     "test.finalize")
             (equal? (failure-event-primary-message (car recorded-finalizer-failures))
                     "native finalizer release failed"))
        "native finalizer journal retains the normalized release failure")
(for ([index (in-range 65)])
  (run-native-finalizer!
   "test.saturation"
   (lambda () (raise (exn:fail (format "failure ~a" index)
                               (current-continuation-marks))))))
(define saturated-runtime-failures (take-runtime-failures!))
(expect (and (= (length saturated-runtime-failures) 64)
             (= (failure-event-dropped-before
                 (car saturated-runtime-failures))
                1)
             (equal? (failure-event-primary-message
                      (car saturated-runtime-failures))
                     "failure 1"))
        "runtime failure saturation reports loss on the first survivor")
(run-native-finalizer!
 (make-string 600 #\x)
 (lambda () (raise (exn:fail "unretained" (current-continuation-marks)))))
(define bounded-runtime-failure (car (take-runtime-failures!)))
(expect (and (positive?
              (bitwise-and (failure-event-truncated-fields bounded-runtime-failure) 1))
             (<= (for/sum ([text (in-list
                                  (list (failure-event-operation bounded-runtime-failure)
                                        (failure-event-primary-name bounded-runtime-failure)
                                        (failure-event-primary-message bounded-runtime-failure)
                                        (failure-event-secondary-name bounded-runtime-failure)
                                        (failure-event-secondary-message bounded-runtime-failure)))])
                   (bytes-length (string->bytes/utf-8 text)))
                 512))
        "runtime failure payloads share the native bounded schema")
(run-native-finalizer!
 (make-string 600 #\☃)
 (lambda () (raise (exn:fail "unretained" (current-continuation-marks)))))
(define unicode-runtime-failure (car (take-runtime-failures!)))
(expect (and (<= (bytes-length
                  (string->bytes/utf-8
                   (failure-event-operation unicode-runtime-failure)))
                 512)
             (not (regexp-match? #rx"�" (failure-event-operation unicode-runtime-failure))))
        "runtime failure truncation ends at a UTF-8 boundary")

(define original-callerless-failure
  (exn:fail "observer failed" (current-continuation-marks)))
(define diagnostic-recorder-failure
  (exn:fail "Context recorder failed" (current-continuation-marks)))
(record-callerless-with-fallback!
 'application-observer "trace.sink" original-callerless-failure
 (lambda () (raise diagnostic-recorder-failure)))
(define callerless-fallback (take-runtime-failures!))
(expect (and (= (length callerless-fallback) 2)
             (eq? (failure-event-layer (car callerless-fallback))
                  'application-observer)
             (equal? (failure-event-primary-message (car callerless-fallback))
                     "observer failed")
             (eq? (failure-event-layer (cadr callerless-fallback)) 'binding)
             (equal? (failure-event-operation (cadr callerless-fallback))
                     "trace.sink.diagnostic"))
        "a refused Context recorder preserves the original and recorder failures")

(define typed-runtime-failure
  (exn:fail:pancake "typed primary" (current-continuation-marks)
                    ERR-IO #f ERR-INTERNAL "PancakeError" 2))
(record-runtime-failure! 'transport "listener.close" typed-runtime-failure)
(define typed-runtime-event (car (take-runtime-failures!)))
(expect (and (= (failure-event-primary-result typed-runtime-event) ERR-IO)
             (= (failure-event-secondary-result typed-runtime-event) ERR-INTERNAL)
             (= (failure-event-secondary-count typed-runtime-event) 2)
             (equal? (failure-event-secondary-name typed-runtime-event)
                     "PancakeError"))
        "runtime diagnostics preserve stable typed primary and secondary causes")

;; The reference relay owns two pump legs, a watchdog, and both transport
;; closes. It joins every worker and exposes the exact occurrence-ordered
;; failure objects instead of letting cleanup replace the failed leg.
(define relay-leg-failure
  (exn:fail "relay WebSocket read failed" (current-continuation-marks)))
(define relay-channel-close-failure
  (exn:fail "relay byte-channel close failed" (current-continuation-marks)))
(define relay-websocket-close-failure
  (exn:fail "relay WebSocket close failed" (current-continuation-marks)))
(define blocked-relay-read (make-semaphore 0))
(define failing-relay-channel
  (byte-channel
   (lambda () (semaphore-wait blocked-relay-read) eof)
   (lambda (_bytes) (void))
   (lambda () (raise relay-channel-close-failure))
   #f))
(define observed-relay-failure
  (with-handlers ([exn:fail:relay? values])
    (relay-pump
     'fake-relay-websocket
     failing-relay-channel
     #:ws-recv (lambda (_connection #:payload-type _payload-type)
                 (raise relay-leg-failure))
     #:ws-send (lambda (_connection _bytes #:payload-type _payload-type) (void))
     #:ws-close (lambda (_connection) (raise relay-websocket-close-failure)))
    #f))
(expect (eq? (exn:fail:relay-primary observed-relay-failure) relay-leg-failure)
        "relay aggregate retains the exact first leg failure")
(define relay-secondary (exn:fail:relay-secondary observed-relay-failure))
(expect (and (= (length relay-secondary) 2)
             (eq? (car relay-secondary) relay-channel-close-failure)
             (eq? (cadr relay-secondary) relay-websocket-close-failure))
        "relay aggregate retains both exact close failures in order")

(define maximum-close-options
  (close-options 'grace-boundary 'finish #xffffffff))
(expect (= #xffffffff
           (PancakeCloseOptions-grace-ms maximum-close-options))
        "finite close grace preserves the C field maximum")
(define excessive-grace
  (with-handlers ([exn:fail:pancake? values])
    (close-options 'grace-boundary 'finish #x100000000)
    #f))
(expect (and (exn:fail:pancake? excessive-grace)
             (= ERR-INVALID-ARGUMENT (exn:fail:pancake-code excessive-grace)))
        "finite close grace rejects values outside its C field")

;; The linked library reports a real ABI version.
(let-values ([(major minor patch) (abi-version)])
  (expect (positive? (+ major minor patch)) "abi-version is nonzero"))

(define parsed-sturdyref
  (parse-sturdyref
   "ocapn://wy46gxdweyqn5m7ntzwlxinhdia2jjanlsh37gxklwhfec7yxqr4k3qd.onion/s/eQjP4nR28ffX5eoNCK5DWH6DT_d7BIqD3-My459CUbU"
   #:captp-version 'v1_0))
(expect (string=? "onion" (locator-transport (sturdyref-locator parsed-sturdyref)))
        "sturdyref locator transport survives parsing")
(expect (bytes=? (sturdyref-swissnum parsed-sturdyref)
                 (bytes #x79 #x08 #xcf #xe2 #x74 #x76 #xf1 #xf7
                        #xd7 #xe5 #xea #x0d #x08 #xae #x43 #x58
                        #x7e #x83 #x4f #xf7 #x7b #x04 #x8a #x83
                        #xdf #xe3 #x32 #xe3 #x9f #x42 #x51 #xb5))
        "sturdyref swiss authority survives parsing")
(define formatted-sturdyref
  (format-sturdyref (tcp-locator "127.0.0.1" 9045)
                    #"durable:0123456789abcdef"
                    #:captp-version 'next))
(expect (bytes=? (sturdyref-swissnum
                  (parse-sturdyref formatted-sturdyref #:captp-version 'next))
                 #"durable:0123456789abcdef")
        "sturdyref formatting round-trips opaque authority")

(for ([invalid-seed (list (make-bytes 31) (make-bytes 33))])
  (define refused
    (with-handlers ([exn:fail:pancake? values])
      (make-host invalid-seed)
      #f))
  (expect (and (exn:fail:pancake? refused)
               (= ERR-INVALID-ARGUMENT (exn:fail:pancake-code refused)))
          "Host must reject a seed that is not 32 bytes"))

(define caller-seed (make-bytes 32 7))
(define owned-seed-host (make-host caller-seed))
(bytes-set! caller-seed 0 8)
(expect (immutable? (host-seed owned-seed-host))
        "Host must expose an immutable seed")
(expect (= 7 (bytes-ref (host-seed owned-seed-host) 0))
        "Host must retain an owned seed copy")
(host-close! owned-seed-host)

(define locator-host (make-fresh-host))
(host-set-advertised-locator!
 locator-host
 (locator "tcp" "127.0.0.1:7441" (hash) 'map))
(host-remove-advertised-locator! locator-host "tcp")
(host-close! locator-host)

(define profile-host (make-fresh-host))
(define profile-conflict
  (with-handlers ([exn:fail:pancake? values])
    (open-test-session (tcp-locator "127.0.0.1" 1)
             #:adopt-host profile-host
             #:captp-version 'next)
    #f))
(expect (and (exn:fail:pancake? profile-conflict)
             (= ERR-INVALID-ARGUMENT (exn:fail:pancake-code profile-conflict)))
        "connect: shared Host refuses a conflicting CapTP profile")
(host-close! profile-host)

;; A listener close races with a parked accept in real servers during
;; custodian shutdown. The close must wake the green thread and wait for its
;; accept gate before freeing native authority.
(define (expect-parked-accept-closes make-nl listen-one accept-one close-listener close-nl label)
  (define nl (make-nl))
  (define lst (listen-one nl))
  (define result (make-channel))
  (define accepter
    (thread
     (lambda ()
       (channel-put
        result
        (with-handlers ([exn:fail? values])
          (accept-one lst)
          'accepted)))))
  (sleep 0.02)
  (close-listener lst)
  (define outcome (sync/timeout 2 result))
  (expect (exn:fail? outcome)
          (format "~a: listener release wakes a parked accept" label))
  (thread-wait accepter)
  (close-nl nl))

(expect-parked-accept-closes
 make-netlayer
 (lambda (nl) (netlayer-listen nl "127.0.0.1" 0))
 listener-accept listener-release! netlayer-release! "TCP")
(expect-parked-accept-closes
 make-inproc-netlayer
 (lambda (nl) (inproc-netlayer-listen nl "release-race"))
 inproc-listener-accept inproc-listener-release! inproc-netlayer-release! "inproc")

;; The parent owns that same shutdown transaction. Two close callers join one
;; terminal transition while the parent interrupts and drains a child accept;
;; neither may return through a second native release.
(define (expect-parent-release-joins make-nl listen-one accept-one close-nl label)
  (define nl (make-nl))
  (define lst (listen-one nl))
  (define accepted (make-channel))
  (define accepter
    (thread
     (lambda ()
       (channel-put accepted
                    (with-handlers ([exn:fail? values])
                      (accept-one lst)
                      'accepted)))))
  (sleep 0.02)
  (define released (make-channel))
  (define closers
    (for/list ([i (in-range 2)])
      (thread (lambda () (close-nl nl) (channel-put released i)))))
  (expect (sync/timeout 2 released) (format "~a: first parent release returned" label))
  (expect (sync/timeout 2 released) (format "~a: concurrent parent release joined" label))
  (expect (exn:fail? (sync/timeout 2 accepted))
          (format "~a: parent release wakes a parked accept" label))
  (for-each thread-wait closers)
  (thread-wait accepter))

(expect-parent-release-joins
 make-netlayer
 (lambda (nl) (netlayer-listen nl "127.0.0.1" 0))
 listener-accept netlayer-release! "TCP")
(expect-parent-release-joins
 make-inproc-netlayer
 (lambda (nl) (inproc-netlayer-listen nl "parent-release-race"))
 inproc-listener-accept inproc-netlayer-release! "inproc")

;; A child completed after close sealed admission still borrows the parent's
;; native backend until its own release returns. Keep that cleanup parked and
;; prove parent destruction cannot pass the outstanding operation lease.
(define child-created (make-semaphore 0))
(define allow-child-return (make-semaphore 0))
(define child-release-started (make-semaphore 0))
(define allow-child-release (make-semaphore 0))
(define parent-closing (make-semaphore 0))
(define parent-released? (box #f))
(define child-released? (box #f))
(define test-parent
  (make-native-parent
   'parent
   (lambda (_)
     (expect (unbox child-released?)
             "native parent waits through rejected-child cleanup")
     (set-box! parent-released? #t))
   (lambda (_) (semaphore-post parent-closing))))
(define opener
  (thread
   (lambda ()
     (with-handlers ([exn:fail? void])
       (native-parent-open-child
        test-parent
        'late-child
        (lambda (_)
          (semaphore-post child-created)
          (semaphore-wait allow-child-return)
          'child)
        (lambda (_)
          (semaphore-post child-release-started)
          (semaphore-wait allow-child-release)
          (set-box! child-released? #t)))))))
(semaphore-wait child-created)
(define parent-closer
  (thread (lambda () (native-parent-release! test-parent void))))
(semaphore-wait parent-closing)
(semaphore-post allow-child-return)
(semaphore-wait child-release-started)
(sleep 0.01)
(expect (not (unbox parent-released?))
        "native parent keeps the lease until late-child release finishes")
(semaphore-post allow-child-release)
(thread-wait opener)
(thread-wait parent-closer)
(expect (unbox parent-released?) "native parent releases after late-child cleanup")

;; The parent is the native lifetime authority, so its registry must keep an
;; otherwise unreachable child alive until ordered teardown releases the child
;; before the parent backend. A weak registry makes finalizer order decide
;; whether the child still borrows freed native state.
(define retained-child-release-count (box 0))
(define retaining-parent (make-native-parent 'parent void))
(define retained-child-weak #f)
(let ([child (box 'child)])
  (set! retained-child-weak (make-weak-box child))
  (native-parent-open-child retaining-parent 'retained-child
                            (lambda (_) child) void)
  (void))
(collect-garbage)
(collect-garbage)
(expect (weak-box-value retained-child-weak)
        "native parent strongly retains children through teardown")
(native-parent-release!
 retaining-parent
 (lambda (_)
   (set-box! retained-child-release-count
             (add1 (unbox retained-child-release-count)))))
(expect (= 1 (unbox retained-child-release-count))
        "native parent releases each retained child exactly once")

;; ── Goblins for Racket: a counter actor, near-called and eventual-sent ────────
;; A Goblins-faithful actor: a constructor `(^counter bcom n)` the vat calls once
;; at spawn, returning a behavior built with `methods` that dispatches on a
;; leading method symbol. `add` becomes a fresh behavior over the new total via
;; `bcom`; `get` reports the current total. We spawn it in a vat, near-call it
;; with `$`, then eventual-send with `<-` and observe the vow with `on`.
(define (^counter bcom n)
  (methods
   [(add k) (bcom (^counter bcom (+ n k)) (+ n k))]
   [(get)   n]))

(define demo-vat (make-vat))
(with-vat demo-vat
  ;; Near-call: `$` runs the behavior synchronously, here and now.
  (define counter (spawn ^counter 10))
  (expect (= 10 ($ counter 'get)) "actor: spawned counter starts at 10")
  (expect (= 15 ($ counter 'add 5)) "actor: ($ counter 'add 5) returns 15")
  (expect (= 15 ($ counter 'get)) "actor: bcom updated the count to 15")

  ;; Eventual-send: `<-` queues a turn and returns a vow; `on` observes it; the
  ;; turn (and the listener) run when we `drive` the vat.
  (define observed (box #f))
  (define add-vow (<- counter 'add 100))
  (on add-vow (lambda (total) (set-box! observed total)))
  (drive demo-vat)
  (expect (= 115 (unbox observed)) "actor: <- counter 'add 100 fulfilled the vow with 115"))

(printf "racket zig-smoke OK: Goblins-idiom actor, spawn, $, <-, on, bcom\n")

;; ── The local export table: bind-export! + vat-resolve-target ─────────────────
;; Hosting a behavior for a partner is the session's job (`session-spawn` /
;; `session-publish`). The vat still records which export id names which local
;; actor so a near reference resolves in-process (`vat-resolve-target`) instead
;; of going out on the wire to its own export — the same self-routing the
;; sibling bindings perform through their hosted tables.
(define lv (make-vat))
(define lv-counter (with-vat lv (spawn ^counter 10)))
(bind-export! lv lv-counter 7)
(expect (equal? (vat-resolve-target lv (make-ref/internal 7)) lv-counter)
        "local export: vat-resolve-target maps a bound Host ref to its actor")
(expect (equal? (vat-resolve-target lv (make-ref/internal 99)) (make-ref/internal 99))
        "local export: an unbound Host ref comes back unchanged")
(with-vat lv
  (expect (= 15 ($ lv-counter 'add 5)) "local export: the bound actor still near-calls"))

(printf "racket zig-smoke OK: bind-export! + vat-resolve-target self-route a Host ref\n")

;; ── The local|far seam: `<-` and `on` across a live session ────────────────
;; A host publishes a counter; the client reaches it through the vat verbs —
;; `(<- svc 'add 5)` through the session's vat is the same
;; location-transparent eventual-send a local actor gets, and `on` observes the
;; far vow. `session-await` pumps the wire until the partner's resolution fires it.
(define fs-server (listen "127.0.0.1" 0))
(define fs-ready (make-semaphore 0))
(define fs-ch (make-channel))
(define fs-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (e) (channel-put fs-ch e))])
       (define hsession (accept fs-server))
       (session-publish hsession "counter" ^counter 10)
       (semaphore-post fs-ready)
       (session-serve hsession)
       (channel-put fs-ch 'served)))))
(define fs-session (open-test-session (tcp-locator "127.0.0.1" (server-port fs-server))))
(semaphore-wait fs-ready)
(define fs-svc (session-fetch fs-session "counter"))
(define fs-observed (box #f))
(define fs-vow (with-vat (session-vat fs-session) (<- fs-svc 'add 5)))
(with-vat (session-vat fs-session) (on fs-vow (lambda (total) (set-box! fs-observed total))))
(expect (= 15 (session-await fs-session fs-vow)) "far: (<- svc 'add 5) settled over the wire with 15")
(expect (= 15 (unbox fs-observed)) "far: the on listener observed the same settlement")
(session-close! fs-session)
(define fs-host-result (channel-get fs-ch))
(when (exn? fs-host-result) (raise fs-host-result))
(expect (eq? 'served fs-host-result) "far: host served to a clean close")
(server-close! fs-server)

(printf "racket zig-smoke OK: far-send round-trip across the local|far seam\n")

;; ── Disconnect: break-far-vows! settles a pending far vow as broken ───────────
;; A far vow waits on a resolve that rides the wire; if the connection drops it
;; can never arrive, so `break-far-vows!` settles the vow broken and the
;; `#:catch` handler runs instead of the awaiter waiting forever.
(define dc-server (listen "127.0.0.1" 0))
(define dc-ready (make-semaphore 0))
(define dc-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (_e) (void))])
       (define hsession (accept dc-server))
       (session-publish hsession "svc" (lambda (bcom) (methods [(greet who) "hi"])))
       (semaphore-post dc-ready)
       (session-serve hsession)))))
(define dc-session
  (open-test-session (tcp-locator "127.0.0.1" (server-port dc-server))
                     #:connector (tcp-connector)))
(semaphore-wait dc-ready)
(define dc-svc (session-fetch dc-session "svc"))
(define dc-broken (box #f))
;; The send is queued but never pumped to settlement, so the vow is pending
;; when the break fires.
(define dc-vow (with-vat (session-vat dc-session) (<- dc-svc 'greet "x")))
(with-vat (session-vat dc-session) (on dc-vow #f #:catch (lambda (msg) (set-box! dc-broken msg))))
(break-far-vows! (session-vat dc-session) "connection closed")
(expect (equal? "connection closed" (unbox dc-broken))
        "disconnect: break-far-vows! fired the far vow's #:catch handler")
(session-close! dc-session)
(void (sync/timeout 2 (thread-dead-evt dc-host)))
(server-close! dc-server)

(printf "racket zig-smoke OK: break-far-vows! settles a pending far vow on disconnect\n")

;; ── Cross-thread send: session-flush! puts another thread's bytes on the wire ────
;; A `<-` only enqueues; the bytes leave when something pumps. Work queued by a
;; green thread that is NOT the connection's pumping thread — a server pushing
;; a broadcast to a subscriber parked reading — must call `session-flush!` to put
;; the bytes on the wire now. The client's inbox capability travels to the
;; server as an argument; a separate server thread tells it and flushes.
(define xf-server (listen "127.0.0.1" 0))
(define xf-ready (make-semaphore 0))
(define xf-session-box (box #f))
(define xf-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (_e) (void))])
       (define hsession (accept xf-server))
       (set-box! xf-session-box hsession)
       (session-publish hsession "registry"
                     (lambda (bcom)
                       (methods
                        [(register cap)
                         ;; Hand the far inbox to a DIFFERENT green thread, which
                         ;; tells it and flushes — the cross-thread send seam.
                         (thread
                          (lambda ()
                            (define c (unbox xf-session-box))
                            (session-tell c cap 'note "broadcast")
                            (session-flush! c)))
                         "registered"])))
       (semaphore-post xf-ready)
       (session-serve hsession)))))
(define xf-session (open-test-session (tcp-locator "127.0.0.1" (server-port xf-server))))
(semaphore-wait xf-ready)
(define xf-notes (box '()))
(define xf-inbox
  (session-spawn xf-session
              (lambda (bcom)
                (methods [(note text) (set-box! xf-notes (cons text (unbox xf-notes)))]))))
(define xf-registry (session-fetch xf-session "registry"))
(expect (equal? "registered" (session-send xf-session xf-registry 'register xf-inbox))
        "cross-thread: the inbox capability registered")
;; Pump until the broadcast lands (the far tell arrives as a wire deliver into
;; our inbox actor).
(let loop ([i 0])
  (when (and (null? (unbox xf-notes)) (< i 200))
    (with-handlers ([exn:fail:pancake? void])
      (session-send xf-session xf-registry 'register xf-inbox))
    (loop (add1 i))))
(expect (member "broadcast" (unbox xf-notes))
        "cross-thread: session-flush! put the other thread's tell on the wire")
(session-close! xf-session)
(void (sync/timeout 2 (thread-dead-evt xf-host)))
(server-close! xf-server)

(printf "racket zig-smoke OK: a cross-thread tell reaches the wire through session-flush!\n")

;; ── Hosting: high-level listen/accept against connect ─────────────────────────
;; A host thread listens on an ephemeral port, accepts one partner on the
;; high-level surface, publishes `svc`, and serves. The main thread `connect`s,
;; fetches `svc`, and calls it — a keyed op:start-session handshake on both
;; ends, no peer or vat wired by hand.
(define hl-server (listen "127.0.0.1" 0))
(define hl-ready (make-semaphore 0))
(define hl-ch (make-channel))
(define hl-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (e) (channel-put hl-ch e))])
       (define hsession (accept hl-server))
       (session-publish hsession "svc"
                     (lambda (bcom)
                       (methods
                        [(greet who) (string-append "hello " who)])))
       (semaphore-post hl-ready)
       (session-serve hsession)
       (channel-put hl-ch 'served)))))

;; `accept` blocks until someone dials, so connect first, then wait for the
;; publish before fetching.
(define hl-session (open-test-session (tcp-locator "127.0.0.1" (server-port hl-server))))
(semaphore-wait hl-ready)
(expect (equal? (partner-identity-locator-record (session-partner-identity hl-session))
                (encode-peer-locator
                 (locator TRANSPORT-TCP
                          (tcp-address-designator "127.0.0.1" (server-port hl-server))
                          (hash)
                          'boolean-false)))
        "listen/accept: the host advertised the listener's complete locator record")
(define hl-svc (session-fetch hl-session "svc"))
(expect (equal? "hello pancake" (session-send hl-session hl-svc 'greet "pancake"))
        "listen/accept: high-level call round-tripped")
(session-close! hl-session)
(define hl-host-result (channel-get hl-ch))
(when (exn? hl-host-result) (raise hl-host-result))
(expect (eq? 'served hl-host-result) "listen/accept: host served to a clean close")
(server-close! hl-server)

(printf "racket zig-smoke OK: high-level listen/accept hosted a keyed session\n")

;; ── The live timeline producer ────────────────────────────────────────────────
;; The veneer stamps and forwards the native tap's facts, one flat record per
;; fact — session-opened with the codec the handshake actually negotiated,
;; the same verb outbound at the client and inbound at the server, and
;; session-closed. Endpoint labeling belongs to the consumer, so the records
;; carry only the session and direction.
(define trace-events (box '()))
(define trace-callback-failure
  (exn:fail "trace observer failed" (current-continuation-marks)))
(define trace-uninstall
  (enable-trace! (lambda (ev)
                   (set-box! trace-events (cons ev (unbox trace-events)))
                   (raise trace-callback-failure))
                 #:self-label "smoke"))
;; The native host retains a C function pointer, so the binding must retain the
;; actual callback object, not only the Racket procedure it was made from.
(collect-garbage)
(collect-garbage)
(define tr-server (listen "127.0.0.1" 0))
(define tr-ready (make-semaphore 0))
(define tr-serve
  (thread
   (lambda ()
     (define hsession (accept tr-server))
     (host-publish-giftable (session-host hsession) "tracer"
                            (lambda (method . args) "hello trace"))
     (semaphore-post tr-ready)
     (session-serve hsession))))
(define tr-session (open-test-session (tcp-locator "127.0.0.1" (server-port tr-server))))
(semaphore-wait tr-ready)
(define tr-cap (session-fetch tr-session "tracer"))
(expect (equal? "hello trace" (session-send tr-session tr-cap 'trace-me))
        "trace: the traced call still answers")
(define trace-failures (host-take-failures! (session-host tr-session)))
(expect (for/or ([failure (in-list trace-failures)])
          (and (equal? (failure-event-operation failure) "trace.sink")
               (positive? (failure-event-scope-id failure))
               (equal? (failure-event-primary-message failure)
                       "trace observer failed")))
        "trace: callback failure enters the Host diagnostic seam")
;; The annotation channel: the application states which partner a
;; session carries, named for the same session row the tap names.
(session-annotate! tr-session #:label "greeter-server")
(session-close! tr-session)
(server-close! tr-server)
(trace-uninstall)
(let* ([events (reverse (unbox trace-events))]
       [kinds (map (lambda (ev) (hash-ref ev 'kind)) events)]
       [msg? (lambda (ev) (equal? (hash-ref ev 'kind) "ocapn.message-decoded"))]
       [opened (filter (lambda (ev) (equal? (hash-ref ev 'kind) "ocapn.session-opened")) events)])
  (expect (>= (length opened) 2) "trace: both hosts' opens reached the one sink")
  (expect (andmap (lambda (ev) (and (equal? (hash-ref ev 'codec) "syrup")
                                    (equal? (hash-ref ev 'a_label #f) "smoke")))
                  opened)
          "trace: opens carry the codec and the application's display label")
  ;; And what this producer RUNS, because this schema is not pancake's alone: a
  ;; consumer must not read an implementation off the fact that a record
  ;; arrived, so a pancake host says so in words.
  (expect (andmap (lambda (ev) (equal? (hash-ref ev 'a_profile #f) "pancake")) opened)
          "trace: an open states the implementation this producer runs")
  ;; Identity and label are two facts. `a` is the host's own key designator —
  ;; the name a partner knows it by, and so the only name two producers can
  ;; agree on — and the label never stands in for it.
  (expect (andmap (lambda (ev) (regexp-match? #px"^[0-9a-f]{64}$" (hash-ref ev 'a "")))
                  opened)
          "trace: an open's `a` endpoint is the reporting host's key designator")
  ;; The OCapN Session ID is what lets a consumer merging two producers' feeds
  ;; tell one session watched twice from two unrelated ones: both peers of a
  ;; session derive it to the same value.
  (expect (let ([ids (map (lambda (ev) (hash-ref ev 'session_id #f)) opened)])
            (and (andmap (lambda (id) (and id (regexp-match? #px"^[0-9a-f]{64}$" id))) ids)
                 (andmap (lambda (id) (equal? id (car ids))) ids)))
          "trace: both peers of one session report the same OCapN Session ID")
  (define outbound
    (findf (lambda (ev) (and (msg? ev) (equal? (hash-ref ev 'op #f) "trace-me")
                             (hash-ref ev 'outbound)))
           events))
  (define inbound
    (findf (lambda (ev) (and (msg? ev) (equal? (hash-ref ev 'op #f) "trace-me")
                             (not (hash-ref ev 'outbound))))
           events))
  (expect outbound "trace: the client's send traced outbound")
  (expect inbound "trace: the server's deliver traced inbound")
  (expect (not (equal? (hash-ref outbound 'session) (hash-ref inbound 'session)))
          "trace: each host names its own session row")
  (expect (and (regexp-match? #px"^[0-9a-f]{32}$" (hash-ref outbound 'digest ""))
               (equal? (hash-ref outbound 'digest) (hash-ref inbound 'digest)))
          "trace: both observers derive the same 128-bit wire-message digest")
  ;; Payload: both fact sites sit at the wire boundary (inbound dispatch,
  ;; the outbound drain), so both records carry the whole (sub-cap) frame
  ;; with its true length and the verb inside it.
  (for ([rec (list inbound outbound)])
    (let ([frame (base64-decode
                  (string->bytes/latin-1 (hash-ref rec 'bytes_b64)))])
      (expect (= (hash-ref rec 'len) (bytes-length frame))
              "trace: true length rides beside the frame")
      (expect (regexp-match? #rx#"trace-me" frame)
              "trace: the frame bytes contain the delivered verb")))
  (expect (member "ocapn.session-closed" kinds) "trace: the close reached the sink")
  (let ([meta (findf (lambda (ev) (equal? (hash-ref ev 'kind) "ocapn.session-meta"))
                     events)])
    (expect (and meta (equal? (hash-ref (hash-ref meta 'meta) 'label) "greeter-server"))
            "trace: the annotation reached the sink with its label")
    (expect (equal? (hash-ref meta 'session) (hash-ref outbound 'session))
            "trace: the annotation names the same session row the tap names"))
  (expect (let loop ([last -1] [rest events])
            (cond [(null? rest) #t]
                  [(< (hash-ref (car rest) 'sim_t_ns) last) #f]
                  [else (loop (hash-ref (car rest) 'sim_t_ns) (cdr rest))]))
          "trace: sim_t_ns is monotone"))
(printf "racket zig-smoke OK: the live trace produced the timeline schema for a whole conversation\n")

;; ── Off-turn settlement: a behavior defers onto a resolver vow ────────────────
;; The worker's behavior atomically defers its turn (`host-defer-turn`), parks
;; the resolver, and returns; the main
;; thread settles it later, top level, and the caller's send completes only
;; then. The broken arm exercises a second call's fresh resolver and the
;; caller hears the worker's own words.
(define rv-server (listen "127.0.0.1" 0))
(define rv-ready (make-semaphore 0))
(define rv-parked (box #f))
(define rv-serve
  (thread
   (lambda ()
     (define hsession (accept rv-server))
     (define worker-host (session-host hsession))
     (host-publish-giftable worker-host "worker"
                            (lambda (method . args)
                              (define pair (host-defer-turn worker-host))
                              (set-box! rv-parked pair)
                              (void)))
     (semaphore-post rv-ready)
     (session-serve hsession))))
(define rv-session (open-test-session (tcp-locator "127.0.0.1" (server-port rv-server))))
(semaphore-wait rv-ready)
(define rv-worker (session-fetch rv-session "worker"))

(define rv-reply-ch (make-channel))
(void (thread (lambda () (channel-put rv-reply-ch (session-send rv-session rv-worker 'work)))))
(let loop () (unless (unbox rv-parked) (sleep 0.005) (loop)))
(resolver-fulfill! (unbox rv-parked) "computed off-turn")
(expect (equal? "computed off-turn" (channel-get rv-reply-ch))
        "resolver: the deferred answer settled off-turn")

(set-box! rv-parked #f)
(define rv-broke-ch (make-channel))
(void (thread
       (lambda ()
         (channel-put rv-broke-ch
                      (with-handlers ([(lambda (_) #t) (lambda (e) (exn-message e))])
                        (session-send rv-session rv-worker 'work))))))
(let loop () (unless (unbox rv-parked) (sleep 0.005) (loop)))
(resolver-break! (unbox rv-parked) "worker gave up")
(define rv-broke (channel-get rv-broke-ch))
(expect (and (string? rv-broke) (regexp-match? #rx"worker gave up" rv-broke))
        "resolver: the break carries the worker's words")
(session-close! rv-session)
(server-close! rv-server)

(printf "racket zig-smoke OK: a behavior deferred its answer onto a resolver vow and settled off-turn\n")

;; ── Sturdyref enliven: durable (peer, swissnum) brought to life, then cached ──
;; The swissnum keys the bootstrap fetch, so a host publish under that name
;; answers the enliven (ADR-0012). The client enlivens a sturdyref, calls the
;; live capability, then enlivens the same swissnum again and gets the cached
;; reference with no new wire fetch.
(define en-server (listen "127.0.0.1" 0))
(define en-ready (make-semaphore 0))
(define en-ch (make-channel))
(define en-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (e) (channel-put en-ch e))])
       (define hsession (accept en-server))
       (session-publish hsession "greeter"
                     (lambda (bcom)
                       (methods
                        [(hello) (sym "alive")])))
       ;; The host-wide porter answers every session, including the fresh
       ;; connection host-enliven's dial arm opens below.
       (host-publish-giftable (session-host hsession) "porter"
                              (lambda (method . args) (sym "ported")))
       (semaphore-post en-ready)
       ;; Serve the first client here while a sibling accepts the dial arm's
       ;; connection.
       (define second
         (thread
          (lambda ()
            (with-handlers ([(lambda (_) #t) void])
              (session-serve (accept en-server))))))
       (session-serve hsession)
       (thread-wait second)
       (channel-put en-ch 'served)))))

(define en-locator (tcp-locator "127.0.0.1" (server-port en-server)))
(define en-session (open-test-session en-locator))
(semaphore-wait en-ready)
(expect (with-handlers ([exn:fail? (lambda (_) #t)])
          (session-enliven en-session "ocapn://127.0.0.1%3A1.tcp/s/Z3JlZXRlcg")
          #f)
        "enliven: a sturdyref for another peer is refused")
;; The complete sturdyref must name this selected session's peer.
(define en-sturdyref (string-append (format-locator-uri en-locator) "/s/Z3JlZXRlcg"))
(define en-cap (session-enliven en-session en-sturdyref))
(expect (ref? en-cap) "enliven: a sturdyref enlivened to a capability")
(expect (equal? (sym "alive") (session-send en-session en-cap 'hello)) "enliven: the live capability answers hello")
;; A repeat enliven hits the dedup cache: the same live reference, no wire fetch.
(define en-again (session-enliven en-session en-sturdyref))
(expect (equal? en-again en-cap) "enliven: a repeat enliven hits the cache")
(expect (equal? (sym "alive") (session-send en-session en-again 'hello)) "enliven: the cached capability answers hello")
;; Listen (CapTP op:listen): a held capability's resolution comes back through
;; the vow — a listen on an already-settled capability answers at once.
(define en-listened (session-await en-session (session-listen en-session en-cap)))
(expect (ref? en-listened) "listen: the vow settles naming the capability")

;; Host-level select-or-dial enliven (ADR-0098). SELECT: the sturdyref names
;; a peer this host already dialed, so the enliven rides `en-session` and the
;; capability answers there.
(define hs-cap (host-enliven (session-host en-session) en-sturdyref))
(expect (ref? hs-cap) "host-enliven: selected a live dialed session")
(expect (equal? (sym "alive") (session-send en-session hs-cap 'hello))
        "host-enliven: the selected capability answers")
;; DIAL: a fresh host with no session stages a dial through the action queue,
;; the executor opens the exporter session on its own serve thread, and the
;; host-scoped wait settles over it.
(define dial-host (make-fresh-host))
(define dial-cap
  (host-enliven dial-host (string-append (format-locator-uri en-locator) "/s/cG9ydGVy")
                #:connector (tcp-connector)))
(expect (ref? dial-cap) "host-enliven: a cold sturdyref staged a dial and settled")
(host-close! dial-host)

(session-close! en-session)
(define en-host-result (channel-get en-ch))
(when (exn? en-host-result) (raise en-host-result))
(expect (eq? 'served en-host-result) "enliven: host served to a clean close")
(server-close! en-server)

(printf "racket zig-smoke OK: a sturdyref enlivens to a live capability, a repeat enliven hits the cache, and a listen settles\n")

;; ── The codec host option: a Cap'n Proto session end to end ──────────────────
;; `listen`/`connect` take `#:codec`: both ends here negotiate Cap'n Proto, so
;; the keyed handshake, the fetch, and the reply all ride capnp frames (the
;; core's stream delimiter splits them behind the pump's byte feed, word shape
;; and all). The echoed args
;; include a big integer past int64 and a keyword, so the two rare marshal
;; arms are witnessed alongside the codec.
(define cx-server (listen "127.0.0.1" 0 #:codec 'capnp))
(define cx-ready (make-semaphore 0))
(define cx-ch (make-channel))
(define cx-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (e) (channel-put cx-ch e))])
       (define hsession (accept cx-server))
       (session-publish hsession "board"
                     (lambda (bcom)
                       (methods
                        [(echo big k bs) (list big k bs)])))
       (semaphore-post cx-ready)
       (session-serve hsession)
       (channel-put cx-ch 'served)))))
(define cx-session (open-test-session (tcp-locator "127.0.0.1" (server-port cx-server)) #:codec 'capnp))
(semaphore-wait cx-ready)
(define cx-svc (session-fetch cx-session "board"))
(define cx-big (expt 2 80))
(expect (equal? (list cx-big (kw "prio") #"hi")
                (session-send cx-session cx-svc 'echo cx-big (kw "prio") #"hi"))
        "capnp: big-integer + keyword + bytes args round-trip a Cap'n Proto session")
(session-close! cx-session)
(define cx-host-result (channel-get cx-ch))
(when (exn? cx-host-result) (raise cx-host-result))
(expect (eq? 'served cx-host-result) "capnp: host served to a clean close")
(server-close! cx-server)

(printf "racket zig-smoke OK: a capnp session opens through #:codec and big-integer + keyword args round-trip\n")

;; ── A byte-sniffing TCP relay ─────────────────────────────────────────────────
;; A relay between a dialing client and `target-port` that watches every
;; client→server chunk with `on-chunk`: return 'close to drop both sides on the
;; spot (a scripted network fault), anything else to forward. Both endpoints
;; stay fully high-level; the relay is how the dogfood observes — or severs —
;; the wire between them without a raw peer.
(define (start-sniffing-relay target-port on-chunk
                              #:before-connect [before-connect void])
  (define lst (tcp-listen 0 4 #t "127.0.0.1"))
  (define-values (_h port _rh _rp) (tcp-addresses lst #t))
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) void])
       (define-values (cin cout) (tcp-accept lst))
       (before-connect)
       (define-values (sin sout) (tcp-connect "127.0.0.1" target-port))
       (define (close-all!)
         (for-each (lambda (p) (with-handlers ([(lambda (_) #t) void])
                                 (if (input-port? p) (close-input-port p) (close-output-port p))))
                   (list cout sout cin sin)))
       (define (pump-side in out watch)
         (thread
          (lambda ()
           (with-handlers ([(lambda (_) #t) void])
             (let loop ()
               (define buf (make-bytes 65536))
               (define n (read-bytes-avail! buf in))
               (cond
                 [(eof-object? n) (close-all!)]
                 [else
                  (define chunk (subbytes buf 0 n))
                  (cond
                    [(and watch (eq? 'close (watch chunk))) (close-all!)]
                    [else (write-bytes chunk out) (flush-output out) (loop)])]))))))
       (pump-side cin sout on-chunk)
       (pump-side sin cout #f))))
  (values lst port))

;; ── Distributed GC (ADR-0063): a dropped fetched import releases its export ──
;; Opt the client into GC; once on, a far capability returned by `session-fetch`
;; releases its import — one `op:gc-export` — when the collector reclaims the
;; last reference to it. Both ends are fully high-level; the release is
;; asserted on the wire itself, through a sniffing relay between them (the
;; partner's engine consumes `op:gc-export` internally, so only the bytes in
;; flight prove it shipped). The client fetches a cap inside a thunk so it
;; falls out of scope, drops it, and forces collection; the finalizer parks the
;; release, and the next `session-fetch` drains it to the wire where the relay
;; sees it.
(define gc-server (listen "127.0.0.1" 0))
(define gc-ready (make-semaphore 0))
(define gc-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (_e) (void))])
       (define hsession (accept gc-server))
       (session-publish hsession "svc" (lambda (bcom) (methods [(ping) (sym "alive")])))
       (semaphore-post gc-ready)
       (session-serve hsession)))))
(define gc-saw (box #f))
(define-values (gc-relay gc-relay-port)
  (start-sniffing-relay (server-port gc-server)
                        (lambda (chunk)
                          (when (regexp-match? #rx#"op:gc-export" chunk) (set-box! gc-saw #t))
                          #f)))
(define gc-session (session-with-gc! (open-test-session (tcp-locator "127.0.0.1" gc-relay-port))))
(semaphore-wait gc-ready)
;; Fetch and drop inside a thunk so the capability falls out of scope (a
;; module-level binding would root it forever and never finalize).
(define (gc-fetch-and-drop!)
  (define cap (session-fetch gc-session "svc"))
  (expect (ref? cap) "gc: fetched a capability")
  (void))
(gc-fetch-and-drop!)
;; Force collection, then re-fetch to drain the parked release, until the relay
;; sees the gc-export on the wire (or we exhaust the budget).
(let loop ([i 0])
  (collect-garbage)
  (sleep 0.02)
  (session-fetch gc-session "svc")
  (unless (or (unbox gc-saw) (>= i 100)) (loop (add1 i))))
(expect (unbox gc-saw) "gc: the wire carried op:gc-export for the dropped fetched import")
(session-close! gc-session)
(void (sync/timeout 2 (thread-dead-evt gc-host)))
(tcp-close gc-relay)
(server-close! gc-server)

(printf "racket zig-smoke OK: a dropped fetched import releases its export when GC is opted in\n")

;; ── Byte-fed sessions: minting a Host session over any transport ──────────────
;; The host archive is byte-fed (ADR-0072), so a session needs no socket:
;; these two constructors open the dialing / accepting half over an arbitrary
;; `async-transport`, the same seam the iroh companion uses. The scripted
;; sections below use them to inject hostile bytes directly and to shuttle host
;; frames over the C transport endpoints.
(define (open-dialed-over m transport-name designator tr)
  ;; Mint only — the smoke drives both hellos by hand before finish-establish!.
  ;; The host retains its own dial default; the locator travels whole.
  (call-with-locator-view (locator transport-name designator (hash) 'boolean-false)
    (lambda (view)
      (call-with-host m
        (lambda ()
          (define-values (rc ptr)
            (pancake_host_session_open_dialed_locator (host-ptr m) view))
          (check/host rc)
          (build-session m ptr tr #f))))))

;; A bare pending-session mint for the close-lifecycle scenarios below.
(define (open-pending-dialed! m)
  (call-with-locator-view (locator "tcp" "pending-session" (hash) 'boolean-false)
    (lambda (view)
      (call-with-host m
        (lambda ()
          (define-values (rc _session)
            (pancake_host_session_open_dialed_locator (host-ptr m) view))
          (check/host rc))))))

(define (open-accepted-over m transport-name designator tr #:designator-scheme designator-scheme)
  (define tb (string->bytes/utf-8 transport-name))
  (define db (string->bytes/utf-8 designator))
  ;; These byte-fed tcp scenarios know the accepted endpoint they model. Feed
  ;; it as the accepted address so the signed locator matches what the dialer
  ;; selected; an empty address deliberately means unreachable-client.
  (define hb db)
  (call-with-host m
    (lambda ()
      (define tpin (pin-immobile tb))
      (define dbpin (pin-immobile db))
      (define hbpin (pin-immobile hb))
      (define-values (rc ptr)
        (pancake_host_session_open_accepted (host-ptr m)
                                             tpin (bytes-length tb)
                                             designator-scheme
                                             dbpin (bytes-length db)
                                             hbpin (bytes-length hb)))
      (check/host rc)
      (build-session m ptr tr #f))))

;; A transport read exception is not EOF. The byte pump retains the exact
;; object, reports physical loss to the core, retires the native Session, and
;; makes a later close re-observe that same cause.
(define rf-host (make-fresh-host))
(define rf-first-failure
  (exn:fail "injected exact read failure" (current-continuation-marks)))
(define rf-close-count (box 0))
(define rf-session
  (open-dialed-over
   rf-host
   "tcp"
   (tcp-address-designator "127.0.0.1" 9)
   (async-transport
    (lambda (_frame) (void))
    void
    (lambda (_wake) (raise rf-first-failure))
    (lambda () (set-box! rf-close-count (add1 (unbox rf-close-count)))))))
(drain-host! rf-host)
(define rf-read-failure
  (with-handlers ([(lambda (_) #t) values])
    (pump-read-once! rf-session)
    'no-error))
(define rf-close-failure
  (with-handlers ([(lambda (_) #t) values])
    (session-close! rf-session)
    'no-error))
(expect (eq? rf-first-failure rf-read-failure)
        "read failure: the pump converted an exact transport exception to EOF")
(expect (eq? rf-first-failure rf-close-failure)
        "read failure: close lost the exact transport exception")
(expect (and (session-released? rf-session) (= 1 (unbox rf-close-count)))
        "read failure: the Session was not physically retired exactly once")
(host-close! rf-host)

(printf "racket zig-smoke OK: a transport read exception stays exact through retirement\n")

;; ── Bounded tail: an over-cap frame is a typed refusal, not "read more" ──────
;; The core's stream delimiter (`pancake_host_session_feed_bytes`) buffers a
;; partial frame in the session only while the frame stays admissible; a frame
;; declaring more than the frame cap must surface as the typed FRAME_TOO_LARGE
;; error, or a hostile partner could grow the session's tail without
;; bound. This feeds the hostile prefix through the exact byte path the
;; connection pump uses, into a byte-fed connection whose transport discards
;; the projected outbound abort.
(define oc-host (make-fresh-host))
(define oc-session (open-accepted-over oc-host "tcp" (tcp-address-designator "127.0.0.1" 9)
                                    (async-transport (lambda (_f) (void)) void
                                                     (lambda (_wake) eof) void)
                                    #:designator-scheme DESIGNATOR-SCHEME-ADDRESS))
(drain-host! oc-host) ; the signed op:start-session leaves into the discard transport
(define oc-failure
  (with-handlers ([exn:fail:pancake? values])
    (feed-bytes! oc-session #"2000000:")
    'no-error))
(expect (and (exn:fail:pancake? oc-failure)
             (= ERR-FRAME-TOO-LARGE (exn:fail:pancake-code oc-failure)))
        "over-cap frame: typed FRAME_TOO_LARGE refusal")
(define oc-close-failure
  (with-handlers ([exn:fail:pancake? values])
    (session-close! oc-session)
    'no-error))
(expect (eq? oc-failure oc-close-failure)
        "over-cap frame: close retained the exact refusal")

(printf "racket zig-smoke OK: an over-cap frame refuses typed instead of buffering\n")

;; ── last-abort: a refused frame carries its typed cause ───────────────────────
;; The flat return code names the failure family; the `abort` field on the exn
;; a feeding connection raises names the member: domain, projected op:abort
;; kind, and the originating error. The hostile bytes are fed straight into a
;; byte-fed connection through the core's stream delimiter, whose transport
;; discards the projected outbound abort.
(define la-host (make-fresh-host))
(define la-session (open-accepted-over la-host "tcp" (tcp-address-designator "127.0.0.1" 9)
                                    (async-transport (lambda (_f) (void)) void
                                                     (lambda (_wake) eof) void)
                                    #:designator-scheme DESIGNATOR-SCHEME-ADDRESS))
(drain-host! la-host) ; the signed op:start-session leaves into the discard transport
(expect (not (session-last-abort la-session)) "last-abort: nothing recorded before a failure")
(define la-exn
  (with-handlers ([exn:fail:pancake? values])
    (feed-bytes! la-session #"this is not a frame")
    'no-error))
(expect (exn:fail:pancake? la-exn) "last-abort: a refused frame raised exn:fail:pancake")
(define la-info (exn:fail:pancake-abort la-exn))
(expect (abort-info? la-info) "last-abort: the exn carries the typed abort detail")
(expect (eq? 'codec (abort-info-domain la-info)) "last-abort: domain is codec")
(expect (equal? "MalformedFrame" (abort-info-kind la-info)) "last-abort: kind is MalformedFrame")
(expect (equal? "MalformedFrame" (abort-info-error-name la-info)) "last-abort: error-name is MalformedFrame")
(expect (not (abort-info-abort-delivery-error-name la-info))
        "last-abort: successful abort delivery has no consequence error")
(expect (not (abort-info-secondary-error-name la-info))
        "last-abort: successful cleanup has no secondary error")
(expect (zero? (abort-info-secondary-error-count la-info))
        "last-abort: successful cleanup has no secondary failures")
(expect (abort-info? (session-last-abort la-session)) "last-abort: the reader reads the same recorded cause")
(define la-close-exn
  (with-handlers ([exn:fail:pancake? values])
    (session-close! la-session)
    'no-error))
(expect (eq? la-exn la-close-exn) "last-abort: close retained the exact refused-frame failure")

(printf "racket zig-smoke OK: a refused frame carries its typed last-abort cause\n")

;; ── Session parity: self-spawned sends resolve in process; failures are typed ─
;; A host publishes `svc` (whose `boom` method raises) and serves. The client
;; proves three contracts the other bindings already pin: a send/tell to a Ref
;; this same session spawned resolves in process (the server hosts no such
;; export, so a wire route would never reply, mirroring Rust's
;; send_to_a_self_spawned_actor_resolves_in_process); a partner break raises a
;; typed exn:fail:pancake carrying PANCAKE_ERR_BROKEN; and a failed fetch
;; re-raises that typed failure untouched.
(define cp-server (listen "127.0.0.1" 0))
(define cp-ready (make-semaphore 0))
(define cp-ch (make-channel))
(define cp-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (e) (channel-put cp-ch e))])
       (define hsession (accept cp-server))
       (define published
         (session-publish hsession "svc"
                          (lambda (bcom)
                            (methods
                             [(boom) (error 'svc "deliberate failure")]))))
       (define observed (session-published-ref hsession "svc"))
       (expect (and (ref? observed) (= (ref-id observed) (ref-id published)))
               "published-ref reuses the opaque Host identity")
       (semaphore-post cp-ready)
       (session-serve hsession)
       (channel-put cp-ch 'served)))))

(define cp-session (open-test-session (tcp-locator "127.0.0.1" (server-port cp-server))))
(semaphore-wait cp-ready)

;; Self-spawned send and tell: the client never runs a serve loop, so only an
;; in-process turn can settle these.
(define cp-me (session-spawn cp-session ^counter 10))
(expect (ref? cp-me) "self-spawn: session-spawn returns a capability")
(expect (= 15 (session-send cp-session cp-me 'add 5)) "self-spawn: session-send resolved in process")
(session-tell cp-session cp-me 'add 100)
(expect (= 115 (session-send cp-session cp-me 'get)) "self-spawn: session-tell ran the local turn")
(define cp-failing
  (session-spawn cp-session
                 (lambda (_bcom)
                   (lambda (_method . _args) (error 'notice "local tell failed")))))
(session-tell cp-session cp-failing 'notify)
(define cp-tell-failures (host-take-failures! (session-host cp-session)))
(expect (and (= (length cp-tell-failures) 1)
             (equal? (failure-event-operation (car cp-tell-failures)) "tell.behavior")
             (positive? (failure-event-scope-id (car cp-tell-failures)))
             (regexp-match? #rx"local tell failed"
                            (failure-event-primary-message (car cp-tell-failures))))
        "self-spawn: local tell failure enters the Host diagnostic seam")

;; A partner break is a typed pancake failure carrying PANCAKE_ERR_BROKEN.
(define cp-svc (session-fetch cp-session "svc"))
(define cp-broken
  (with-handlers ([exn:fail:pancake? values])
    (session-send cp-session cp-svc 'boom)
    'no-error))
(expect (exn:fail:pancake? cp-broken) "break: session-send raised exn:fail:pancake")
(expect (equal? ERR-BROKEN (exn:fail:pancake-code cp-broken)) "break: code is PANCAKE_ERR_BROKEN")
(expect (regexp-match? #rx"deliberate failure" (exn-message cp-broken))
        "break: the partner's own diagnostic crossed the wire")

;; A fetch of an unpublished name breaks too, and session-fetch re-raises the typed
;; failure untouched instead of flattening it to a generic exn:fail.
(define cp-missing
  (with-handlers ([exn:fail:pancake? values])
    (session-fetch cp-session "no-such-name")
    'no-error))
(expect (exn:fail:pancake? cp-missing) "fetch: an unknown name raised exn:fail:pancake")
(expect (equal? ERR-BROKEN (exn:fail:pancake-code cp-missing)) "fetch: code is PANCAKE_ERR_BROKEN")

(session-close! cp-session)
(define cp-host-result (channel-get cp-ch))
(when (exn? cp-host-result) (raise cp-host-result))
(expect (eq? 'served cp-host-result) "connection parity: host served to a clean close")
(server-close! cp-server)

(printf "racket zig-smoke OK: self-spawned sends resolve in process and failures are typed\n")

;; ── Foreign argument: a capability from another connection fails closed ───────
;; A capability fetched on one connection cannot ride another connection's send
;; as an argument — the host refuses the send whole (typed INVALID_ARGUMENT)
;; rather than mis-encode a reference the partner never imported — and the
;; refusal walks containers, so hiding the foreign capability inside a list
;; changes nothing. Two listens give two partner designators so one client host
;; can hold both sessions (a second dial to the same address refuses
;; SessionPairExists).
(define fa-server-1 (listen "127.0.0.1" 0))
(define fa-server-2 (listen "127.0.0.1" 0))
(define fa-ready-1 (make-semaphore 0))
(define fa-ready-2 (make-semaphore 0))
(define (fa-serve! server ready)
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (_e) (void))])
       (define hsession (accept server))
       (session-publish hsession "svc" (lambda (bcom) (methods [(echo x) x])))
       (semaphore-post ready)
       (with-handlers ([(lambda (_) #t) void]) (session-serve hsession))))))
(void (fa-serve! fa-server-1 fa-ready-1))
(void (fa-serve! fa-server-2 fa-ready-2))
(define fa-session-1 (open-test-session (tcp-locator "127.0.0.1" (server-port fa-server-1))))
(semaphore-wait fa-ready-1)
(define fa-session-2 (open-test-session (tcp-locator "127.0.0.1" (server-port fa-server-2))
                           #:adopt-host (session-host fa-session-1)))
(semaphore-wait fa-ready-2)
(define fa-cap-1 (session-fetch fa-session-1 "svc"))
(define fa-cap-2 (session-fetch fa-session-2 "svc"))
(define fa-refused
  (with-handlers ([exn:fail:pancake? values])
    (session-send fa-session-2 fa-cap-2 'echo (list 1 fa-cap-1 2))
    'no-error))
(expect (exn:fail:pancake? fa-refused) "foreign arg: the cross-connection send was refused")
(expect (equal? ERR-INVALID-ARGUMENT (exn:fail:pancake-code fa-refused)) "foreign arg: code is PANCAKE_ERR_INVALID_ARGUMENT")
(session-close! fa-session-1)
(session-close! fa-session-2)
(server-close! fa-server-1)
(server-close! fa-server-2)

(printf "racket zig-smoke OK: a foreign capability in argument position fails closed, containers included\n")

;; ── Promise pipelining: the questioner's half (ADR-0007) ──────────────────────
;; `session-send-promise` returns a far vow that is itself a `send` target, so
;; a create -> assign -> complete -> status chain is issued against the
;; *unresolved* create answer and the four delivers travel as one batch on the
;; settling `session-send`'s pump. The board's `create` spawns a fresh task
;; mid-turn and returns it; the partner's engine queues the pipelined calls on
;; that pending answer and drains them onto the task once create resolves. A
;; status of `done` proves the chain crossed the wire without round-tripping
;; per link.
(define (^task bcom [done #f])
  (methods
   [(assign who) "assigned"]
   [(complete)   (bcom (^task bcom #t) "done")]
   [(status)     (if done "done" "open")]))

(define pl-server (listen "127.0.0.1" 0))
(define pl-ready (make-semaphore 0))
(define pl-ch (make-channel))
(define pl-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (e) (channel-put pl-ch e))])
       (define hsession (accept pl-server))
       (session-publish hsession "root"
                     (lambda (bcom)
                       (methods
                        [(create name) (session-spawn hsession ^task)])))
       (semaphore-post pl-ready)
       (session-serve hsession)
       (channel-put pl-ch 'served)))))

(define pl-session (open-test-session (tcp-locator "127.0.0.1" (server-port pl-server))))
(semaphore-wait pl-ready)
(define pl-root (session-fetch pl-session "root"))
;; The four verbs leave together: none waits for create's reply, and assign /
;; complete / status target the create answer directly.
(define pl-task (session-send-promise pl-session pl-root 'create "benchmark"))
(void (session-send-promise pl-session pl-task 'assign "alice"))
(void (session-send-promise pl-session pl-task 'complete))
(define pl-status (session-send pl-session pl-task 'status))
(expect (equal? "done" pl-status) "pipelining: the chained status settled to done")

(session-close! pl-session)
(define pl-host-result (channel-get pl-ch))
(when (exn? pl-host-result) (raise pl-host-result))
(expect (eq? 'served pl-host-result) "pipelining: host served to a clean close")
(server-close! pl-server)

(printf "racket zig-smoke OK: promise pipelining drives create->assign->complete->status as one batch\n")

;; ── Promise-pipeline saturation stays typed and terminal ─────────────────────
;; A queue cap of one admits the first call aimed at an unresolved answer and
;; refuses the second. Both calls travel in the same feed batch, before the
;; create behavior can settle its answer. The refusal must remain the Session's
;; one terminal result through serve and every close observer.
(define qs-host (make-fresh-host))
(host-set-session-limits! qs-host 0 1)
(define qs-server (listen "127.0.0.1" 0 #:host qs-host))
(define qs-ready (make-semaphore 0))
(define qs-parked (box #f))
(define qs-result (make-channel))
(define qs-server-thread
  (thread
   (lambda ()
     (define hsession (accept qs-server))
     (host-publish-giftable
      (session-host hsession) "root"
      (lambda (method . _args)
        (unless (eq? method 'create) (error 'queue-saturation "unexpected method"))
        (define pair (host-defer-turn (session-host hsession)))
        (set-box! qs-parked pair)
        (void)))
     (semaphore-post qs-ready)
     (define serve-failure
       (with-handlers ([exn:fail:pancake? values])
         (session-serve hsession)
         'served))
     (define close-failure
       (with-handlers ([exn:fail:pancake? values])
         (session-close! hsession)
         'closed))
     (define repeated-close-failure
       (with-handlers ([exn:fail:pancake? values])
         (session-close! hsession)
         'closed))
     (channel-put qs-result
                  (list serve-failure close-failure repeated-close-failure
                        (session-released? hsession))))))

(define qs-session
  (open-test-session (tcp-locator "127.0.0.1" (server-port qs-server))))
(semaphore-wait qs-ready)
(define qs-root (session-fetch qs-session "root"))
(define qs-task (session-send-promise qs-session qs-root 'create))
(let await-deferred-answer ()
  (unless (unbox qs-parked) (sleep 0.001) (await-deferred-answer)))
(void (session-send-promise qs-session qs-task 'assign "first"))
(define qs-saturated
  (session-send-promise qs-session qs-task 'assign "saturated"))
(define qs-client-failure
  (with-handlers ([exn:fail:pancake? values])
    (session-await qs-session qs-saturated)
    'settled))
(define qs-observed (sync/timeout 10 qs-result))
(expect qs-observed "queue saturation: exporter serve did not terminate")
(define qs-serve-failure (list-ref qs-observed 0))
(define qs-close-failure (list-ref qs-observed 1))
(define qs-repeated-close-failure (list-ref qs-observed 2))
(define qs-abort
  (and (exn:fail:pancake? qs-serve-failure)
       (exn:fail:pancake-abort qs-serve-failure)))
(expect (and (exn:fail:pancake? qs-client-failure)
             (= ERR-CLOSED (exn:fail:pancake-code qs-client-failure))
             (exn:fail:pancake? qs-serve-failure)
             (= ERR-SESSION (exn:fail:pancake-code qs-serve-failure))
             (abort-info? qs-abort)
             (equal? "QueueCapExceeded" (abort-info-kind qs-abort)))
        (format "queue saturation: exact terminal results missing (client ~a, server ~a, abort ~a)"
                qs-client-failure qs-serve-failure qs-abort))
(expect (and (eq? qs-serve-failure qs-close-failure)
             (eq? qs-serve-failure qs-repeated-close-failure)
             (list-ref qs-observed 3))
        "queue saturation: close lost the terminal exception or retired state")
(session-close! qs-session)
(server-close! qs-server)
(host-close! qs-host)
(thread-wait qs-server-thread)

(printf "racket zig-smoke OK: queue saturation stays exact through serve and repeated close\n")

;; ── Pipelined projections (ADR-0050/ADR-0052) ─────────────────────────────────
;; `session-untag`/`session-index` project a tag/element out of a far
;; vow *before it settles*, each returning a new pipelinable vow. The board's
;; `make` returns a `("assigned" label 7)` row wrapped in a "task" tag; `untag`
;; unwraps the single-value tag to that row and `index 1` takes the label, a
;; two-hop chain riding the unresolved `make` answer, no extra round trip. The
;; source vow is then awaited to prove a far reply that landed *before* its
;; listener (while a sibling projection pumped the loop) still settles from the
;; vow's recorded state. (`get` projects a Struct, which the Racket value model
;; surfaces as a tagged/struct arg; index and untag are the
;; cross-binding-comparable pair, so they are what this dogfood asserts,
;; matching Python.)
(define pj-server (listen "127.0.0.1" 0 #:captp-version 'next))
(define pj-ready (make-semaphore 0))
(define pj-ch (make-channel))
(define pj-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (e) (channel-put pj-ch e))])
       (define hsession (accept pj-server))
       (session-publish hsession "root"
                     (lambda (bcom)
                       (methods
                        [(make label) (tagged-arg "task" (list (list "assigned" label 7)))])))
       (semaphore-post pj-ready)
       (session-serve hsession)
       (channel-put pj-ch 'served)))))

(define pj-session (open-test-session (tcp-locator "127.0.0.1" (server-port pj-server))
                            #:captp-version 'next))
(semaphore-wait pj-ready)
(define pj-root (session-fetch pj-session "root"))
;; Neither projection waits for make's reply: they ride the unresolved make
;; answer and the whole chain leaves on one pump.
(define pj-made (session-send-promise pj-session pj-root 'make "alice"))
(define pj-label (session-await pj-session (session-index pj-session (session-untag pj-session pj-made "task") 1)))
(expect (equal? "alice" pj-label) "projections: pipelined untag->index reached the label")
;; The source answer settled while the projection pumped the loop; awaiting it
;; now must still resolve from the vow's recorded state.
(define pj-full (session-await pj-session pj-made))
(expect (and (tagged-arg? pj-full) (equal? "task" (tagged-arg-tag pj-full)))
        "projections: the late source await still settled to the tagged row")

(session-close! pj-session)
(define pj-host-result (channel-get pj-ch))
(when (exn? pj-host-result) (raise pj-host-result))
(expect (eq? 'served pj-host-result) "projections: host served to a clean close")
(server-close! pj-server)

(printf "racket zig-smoke OK: pipelined projections untag->index reach a field, and a late source await still settles\n")

;; ── Unawaited break + a real disconnect ───────────────────────────────────────
;; Two failure contracts over a real socket. First: an unawaited
;; `session-send-promise` whose reply breaks stays silent — no listener means the
;; broken vow crashes nothing, and the connection keeps answering. Second: a
;; partner that hangs up mid-question settles the pending `session-send` with a
;; typed PANCAKE_ERR_CLOSED failure instead of hanging it forever.
(define ub-server (listen "127.0.0.1" 0))
(define ub-ready (make-semaphore 0))
(define ub-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (_e) (void))])
       (define hsession (accept ub-server))
       (session-publish hsession "svc"
                     (lambda (bcom)
                       (methods
                        [(boom) (error "kaboom: refused")]
                        [(ok) (sym "fine")])))
       (semaphore-post ub-ready)
       (session-serve hsession)))))
(define ub-session (open-test-session (tcp-locator "127.0.0.1" (server-port ub-server))))
(semaphore-wait ub-ready)
(define ub-cap (session-fetch ub-session "svc"))
;; Fire the failing verb and never await it; the break arrives while the next
;; call pumps and must stay silent.
(void (session-send-promise ub-session ub-cap 'boom))
(expect (equal? (sym "fine") (session-send ub-session ub-cap 'ok))
        "unawaited: a later call still settles after an unawaited break")
(session-close! ub-session)
(server-close! ub-server)

;; Real disconnect: both ends are high-level; a sniffing relay between them
;; drops the wire the moment the `hang` deliver crosses it, so the client's
;; question is pending when the transport dies and can never be answered.
(define dcs-server (listen "127.0.0.1" 0))
(define dcs-ready (make-semaphore 0))
(define dcs-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (_e) (void))])
       (define hsession (accept dcs-server))
       (session-publish hsession "svc" (lambda (bcom) (methods [(hang) (sym "never")])))
       (semaphore-post dcs-ready)
       (session-serve hsession)))))
(define-values (dcs-relay dcs-relay-port)
  (start-sniffing-relay (server-port dcs-server)
                        (lambda (chunk) (if (regexp-match? #rx#"hang" chunk) 'close #f))))
(define dcs-session (open-test-session (tcp-locator "127.0.0.1" dcs-relay-port)))
(semaphore-wait dcs-ready)
(define dcs-cap (session-fetch dcs-session "svc"))
(define dcs-err
  (with-handlers ([exn:fail:pancake? (lambda (e) e)])
    (session-send dcs-session dcs-cap 'hang)
    #f))
(expect (and dcs-err (= ERR-CLOSED (exn:fail:pancake-code dcs-err)))
        "disconnect: the pending send failed typed ERR-CLOSED, never hung")
(session-close! dcs-session)
(void (sync/timeout 2 (thread-dead-evt dcs-host)))
(tcp-close dcs-relay)
(server-close! dcs-server)

(printf "racket zig-smoke OK: an unawaited break stays silent, and a real disconnect fails a pending send typed\n")

;; ── A rude probe cannot close the listener ────────────────────────────────────
;; A rude TCP probe — connect, say nothing, hang up — is that connection's
;; failure, not the listener's. `accept` completes the keyed handshake, so the
;; probe fails inside the accept; the accept skips it, waits for the next
;; partner, and returns the real client to the caller. Without that isolation
;; one port scan takes a long-lived server down.
(define rp-server (listen "127.0.0.1" 0))
(define rp-ready (make-semaphore 0))
(define rp-host
  (thread
   (lambda ()
     ;; The handler posts `rp-ready` so a regression fails the fetch below
     ;; loudly instead of parking this scene on an unposted semaphore.
     (with-handlers ([(lambda (_) #t) (lambda (_e) (semaphore-post rp-ready))])
       ;; One accept, no retry loop: skipping the probe is `accept`'s own job.
       (define hsession (accept rp-server))
       (session-publish hsession "svc" (lambda (bcom) (methods [(ping) (sym "alive")])))
       (semaphore-post rp-ready)
       (with-handlers ([(lambda (_) #t) (lambda (_e) (void))])
         (session-serve hsession))))))
;; The probe: open a socket and immediately hang up.
(define-values (rp-in rp-out) (tcp-connect "127.0.0.1" (server-port rp-server)))
(close-output-port rp-out)
(close-input-port rp-in)
(define rp-session (open-test-session (tcp-locator "127.0.0.1" (server-port rp-server))))
(semaphore-wait rp-ready)
(define rp-cap (session-fetch rp-session "svc"))
(expect (equal? (sym "alive") (session-send rp-session rp-cap 'ping))
        "probe: the listener survived the rude probe and served the next client")
(session-close! rp-session)
(server-close! rp-server)

(printf "racket zig-smoke OK: a rude probe cannot close the listener\n")

;; Host teardown owns the native loop. An accept at the public boundary must
;; wake terminally before native Host state disappears, never retain the place.
(define hc-server (listen "127.0.0.1" 0))
(define hc-started (make-semaphore 0))
(define hc-result (make-channel))
(define hc-accept
  (thread
   (lambda ()
     (semaphore-post hc-started)
     (channel-put
      hc-result
      (with-handlers ([exn? values])
        (accept hc-server)
        'accepted)))))
(semaphore-wait hc-started)
(host-close! (server-host hc-server))
(define hc-terminal (sync/timeout 2 hc-result))
(expect (exn? hc-terminal)
        "Host release: a parked listener accept did not fail promptly")
(thread-wait hc-accept)

(printf "racket zig-smoke OK: Host release stops native listener admission\n")

;; A bare server owns the Host it created, but listener close is not permission
;; to revoke a session already yielded to the application. Retirement waits for
;; that session to leave the Host's authoritative registry, then releases the
;; loop without a second binding-side session table.
(define owned-loop-server (listen "127.0.0.1" 0))
(define owned-loop-host (server-host owned-loop-server))
(define owned-loop-ready (make-semaphore 0))
(define owned-loop-accept
  (thread
   (lambda ()
     (define c (accept owned-loop-server))
     (session-publish c "svc"
                      (lambda (bcom) (methods [(ping) (sym "alive")])) )
     (semaphore-post owned-loop-ready)
     (with-handlers ([(lambda (_) #t) void]) (session-serve c)))))
(define owned-loop-client
  (open-test-session (tcp-locator "127.0.0.1" (server-port owned-loop-server))))
(semaphore-wait owned-loop-ready)
(server-close! owned-loop-server)
(expect (not (unbox (host-released? owned-loop-host)))
        "bare server close released a yielded session's Host")
(define owned-loop-cap (session-fetch owned-loop-client "svc"))
(expect (equal? (sym "alive")
                (session-send owned-loop-client owned-loop-cap 'ping))
        "bare server close destroyed a yielded session")
(session-close! owned-loop-client)
(thread-wait owned-loop-accept)
(let wait-retired ([attempt 0])
  (when (and (not (unbox (host-released? owned-loop-host))) (< attempt 200))
    (sleep 0.01)
    (wait-retired (add1 attempt))))
(expect (unbox (host-released? owned-loop-host))
        "bare server did not retire its Host after the last yielded session")
(printf "racket zig-smoke OK: bare server retirement waits for yielded sessions\n")

;; A supplied Host is transferred into the native TCP loop, and listener close
;; stops new admission without destroying a session already yielded to the
;; application. The exact wrapper identity is the authority proof.
(define supplied-tcp-host (make-fresh-host))
(define supplied-tcp-server
  (listen "127.0.0.1" 0 #:host supplied-tcp-host))
(expect (eq? supplied-tcp-host (server-host supplied-tcp-server))
        "supplied TCP Host wrapper was not adopted by the driver")
(define supplied-tcp-ready (make-semaphore 0))
(define supplied-tcp-accept
  (thread
   (lambda ()
     (define c (accept supplied-tcp-server))
     (session-publish c "svc"
                      (lambda (bcom) (methods [(ping) (sym "alive")])) )
     (semaphore-post supplied-tcp-ready)
     (with-handlers ([(lambda (_) #t) void]) (session-serve c)))))
(define supplied-tcp-client
  (open-test-session (tcp-locator "127.0.0.1" (server-port supplied-tcp-server))))
(semaphore-wait supplied-tcp-ready)
(server-close! supplied-tcp-server)
(define supplied-tcp-cap (session-fetch supplied-tcp-client "svc"))
(expect (equal? (sym "alive")
                (session-send supplied-tcp-client supplied-tcp-cap 'ping))
        "TCP listener close destroyed a yielded supplied-Host session")
(session-close! supplied-tcp-client)
(thread-wait supplied-tcp-accept)
(host-close! supplied-tcp-host)
(printf "racket zig-smoke OK: supplied TCP Host adoption preserves yielded sessions\n")

;; Listener ownership is per driver listener: closing the first transport must
;; leave a sibling listener on the same supplied Host able to admit a session.
(define sibling-host (make-fresh-host))
(define sibling-tcp (listen "127.0.0.1" 0 #:host sibling-host))
(define sibling-keyed (listen-keyed-tcp "127.0.0.1" 0 #:host sibling-host))
(server-close! sibling-tcp)
(define sibling-client
  (open-test-session (server-locator sibling-keyed)))
(define sibling-accepted (accept sibling-keyed))
(expect (eq? sibling-host (server-host sibling-keyed))
        "closing one listener changed the sibling Host owner")
(session-close! sibling-accepted)
(session-close! sibling-client)
(server-close! sibling-keyed)
(define sibling-noise (listen-noise-tcp "127.0.0.1" 0 #:host sibling-host))
(expect (equal? (locator-transport (server-locator sibling-noise))
                TRANSPORT-NOISE-TCP)
        "generic server locator lost the noise-tcp profile")
(expect (equal? (parse-locator (server-uri sibling-noise))
                (server-locator sibling-noise))
        "generic server URI drifted from its canonical locator")
(define sibling-noise-client (open-test-session (server-locator sibling-noise)))
(define sibling-noise-accepted (accept sibling-noise))
(expect (eq? sibling-host (server-host sibling-noise))
        "noise listener should adopt the supplied Host")
(session-close! sibling-noise-accepted)
(session-close! sibling-noise-client)
(server-close! sibling-noise)
(host-close! sibling-host)
(printf "racket zig-smoke OK: TCP profiles share one server and Host surface\n")

;; The iroh provider follows the same seam: the supplied Host is adopted before
;; the resident is installed, and the generic driver owns listener close.
(define supplied-iroh-host (make-host (make-bytes 32 19)))
(define supplied-iroh-server
  (listen-iroh (make-iroh-config IROH-REACH-LOCAL-DISCOVERY)
               #:host supplied-iroh-host))
(expect (eq? supplied-iroh-host (iroh-server-host supplied-iroh-server))
        "supplied iroh Host wrapper was not adopted by the driver")
(define supplied-iroh-ready (make-semaphore 0))
(define supplied-iroh-accept
  (thread
   (lambda ()
     (define c (iroh-server-accept supplied-iroh-server))
     (session-publish c "svc"
                      (lambda (bcom) (methods [(ping) (sym "alive")])) )
     (semaphore-post supplied-iroh-ready)
     (with-handlers ([(lambda (_) #t) void]) (session-serve c)))))
(define supplied-iroh-client
  (open-test-session (iroh-server-locator supplied-iroh-server)
           #:provider (iroh-provider
                       (make-iroh-config IROH-REACH-LOCAL-DISCOVERY))))
(semaphore-wait supplied-iroh-ready)
(iroh-server-close! supplied-iroh-server)
(define supplied-iroh-cap (session-fetch supplied-iroh-client "svc"))
(expect (equal? (sym "alive")
                (session-send supplied-iroh-client supplied-iroh-cap 'ping))
        "iroh listener close destroyed a yielded supplied-Host session")
(session-close! supplied-iroh-client)
(thread-wait supplied-iroh-accept)
(host-close! supplied-iroh-host)
(printf "racket zig-smoke OK: supplied iroh Host adoption preserves yielded sessions\n")

;; A wildcard bind is deployment policy, not a dialable locator. Once an
;; explicit advertised host is supplied, a silent first peer consumes one
;; bounded handshake lane and a real peer must still be admitted promptly.
(define wildcard-error
  (with-handlers ([exn:fail:pancake? values])
    (listen "0.0.0.0" 0)
    #f))
(expect (and wildcard-error
             (= ERR-INVALID-ARGUMENT (exn:fail:pancake-code wildcard-error)))
        "native listener admission: a wildcard bind requires an advertised host")
(define ca-server
  (listen "0.0.0.0" 0
          #:advertised-host "127.0.0.1"))
(define ca-ready (make-semaphore 0))
(define ca-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) void])
       (define hsession (accept ca-server))
       (session-publish hsession "svc" (lambda (bcom) (methods [(ping) (sym "alive")])))
       (semaphore-post ca-ready)
       (session-serve hsession)))))
(define-values (ca-silent-in ca-silent-out)
  (tcp-connect "127.0.0.1" (server-port ca-server)))
(define ca-client-ch (make-channel))
(void
 (thread
  (lambda ()
    (channel-put
     ca-client-ch
     (with-handlers ([(lambda (_) #t) values])
       (open-test-session (tcp-locator "127.0.0.1" (server-port ca-server))))))))
(define ca-session (sync/timeout 2 ca-client-ch))
(expect (and ca-session (not (exn? ca-session)))
        "native listener admission: a silent peer parked the next handshake")
(expect (sync/timeout 2 (semaphore-peek-evt ca-ready))
        "native listener admission: the real peer was not published")
(expect (equal? (partner-identity-designator (session-partner-identity ca-session))
                (tcp-address-designator "127.0.0.1" (server-port ca-server)))
        "native listener admission: the signed locator uses explicit reachability")
(define ca-cap (session-fetch ca-session "svc"))
(expect (equal? (sym "alive") (session-send ca-session ca-cap 'ping))
        "native listener admission: the real peer remained usable")
(session-close! ca-session)
(close-output-port ca-silent-out)
(close-input-port ca-silent-in)
(void (sync/timeout 2 (thread-dead-evt ca-host)))
(server-close! ca-server)

(printf "racket zig-smoke OK: native listener admission bypasses a silent peer and wildcard reachability is explicit\n")

;; ── Object-capability forwarding proxies over the wire (ADR-0064) ─────────────
;; The client spawns a local tool and passes it as an argument to the host, which
;; sees a far reference and wraps it in a caretaker and an attenuator, handing the
;; proxies back. A call through the caretaker proxy forwards across the host back
;; to the client's tool (the far deferred-answer path) and settles the caller's
;; answer; the attenuator passes only its allow-listed verb; and a revoke breaks
;; every later call.
(define (^tool bcom)
  (methods
   [(add n) (+ n 1)]
   [(get) 7]))

(define mb-server (listen "127.0.0.1" 0))
(define mb-ready (make-semaphore 0))
(define mb-ch (make-channel))
(define mb-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (e) (channel-put mb-ch e))])
       (define hsession (accept mb-server))
       ;; The caretaker the host hands out, stashed so `revoke` can sever it.
       (define proxy-box (box #f))
       (session-publish hsession "root"
                     (lambda (bcom)
                       (methods
                        [(make-proxy tool)
                         (define proxy (session-caretaker hsession tool))
                         (set-box! proxy-box proxy)
                         proxy]
                        [(make-readonly tool) (session-attenuate hsession tool '("get"))]
                        [(revoke) (session-revoke! hsession (unbox proxy-box)) "revoked"])))
       (semaphore-post mb-ready)
       (session-serve hsession)
       (channel-put mb-ch 'served)))))

(define mb-session (open-test-session (tcp-locator "127.0.0.1" (server-port mb-server))))
(semaphore-wait mb-ready)
(define mb-tool (session-spawn mb-session ^tool))
(define mb-root (session-fetch mb-session "root"))

;; Live caretaker: a call forwards across the host to the client's far tool.
(define mb-proxy (session-send mb-session mb-root 'make-proxy mb-tool))
(expect mb-proxy "proxy: the host returned a caretaker proxy")
(expect (= 42 (session-send mb-session mb-proxy 'add 41)) "proxy: caretaker forwards to the far tool")

;; Attenuator: the allow-listed verb forwards; any other breaks.
(define mb-ro (session-send mb-session mb-root 'make-readonly mb-tool))
(expect (= 7 (session-send mb-session mb-ro 'get)) "proxy: attenuator forwards an allowed verb")
(define mb-denied
  (with-handlers ([exn:fail:pancake? (lambda (e) e)])
    (session-send mb-session mb-ro 'add 1) #f))
(expect (and (exn:fail:pancake? mb-denied)
             (regexp-match? #rx"Attenuated" (exn-message mb-denied)))
        "proxy: an out-of-list verb breaks Attenuated")

;; Revoke: every later call through the proxy breaks.
(void (session-send mb-session mb-root 'revoke))
(define mb-severed
  (with-handlers ([exn:fail:pancake? (lambda (e) e)])
    (session-send mb-session mb-proxy 'add 1) #f))
(expect (and (exn:fail:pancake? mb-severed)
             (regexp-match? #rx"Revoked" (exn-message mb-severed)))
        "proxy: a revoked proxy breaks Revoked")

(session-close! mb-session)
(define mb-host-result (channel-get mb-ch))
(when (exn? mb-host-result) (raise mb-host-result))
(expect (eq? 'served mb-host-result) "proxy: host served to a clean close")
(server-close! mb-server)

(printf "racket zig-smoke OK: forwarding proxies forward, attenuate, and revoke over the wire\n")

;; ── A forwarding proxy answers its host's own local call (ADR-0064) ────────────
;; The wart ADR-0064 closes: a caretaker proxy is an ordinary spawned actor, so
;; its own host calls it locally exactly as a partner calls it over the wire. A
;; caretaker over a *local* tool answers a local send; a caretaker over a *far*
;; tool forwards across the wire and the local send still settles; and a revoke
;; breaks the local call too, no second-class behavior on the hosting side.
(define (^ping bcom) (methods [(ping) 99]))
(define (^doubler bcom) (methods [(double n) (* n 2)]))

(define lc-server (listen "127.0.0.1" 0))
(define lc-ready (make-semaphore 0))
(define lc-ch (make-channel))
(define lc-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (e) (channel-put lc-ch e))])
       (define hsession (accept lc-server))
       (session-publish hsession "tool" ^ping)
       (semaphore-post lc-ready)
       (session-serve hsession)
       (channel-put lc-ch 'served)))))

(define lc-session (open-test-session (tcp-locator "127.0.0.1" (server-port lc-server))))
(semaphore-wait lc-ready)

;; A caretaker over a local tool, called locally by its own host.
(define lc-local (session-spawn lc-session ^doubler))
(define lc-care (session-caretaker lc-session lc-local))
(expect (= 42 (session-send lc-session lc-care 'double 21))
        "local-call: a local proxy answers a local call")

;; A caretaker over a far tool, called locally: the proxy forwards across the wire
;; and the local send still settles on the partner's reply.
(define lc-far (session-fetch lc-session "tool"))
(define lc-care-far (session-caretaker lc-session lc-far))
(expect (= 99 (session-send lc-session lc-care-far 'ping))
        "local-call: a local call over a far tool settles")

;; Revoke severs the local call exactly as it severs a partner's.
(session-revoke! lc-session lc-care)
(define lc-severed
  (with-handlers ([exn:fail:pancake? (lambda (e) e)])
    (session-send lc-session lc-care 'double 1) #f))
(expect (and (exn:fail:pancake? lc-severed)
             (regexp-match? #rx"Revoked" (exn-message lc-severed)))
        "local-call: revoke breaks a local call too")

(session-close! lc-session)
(define lc-host-result (channel-get lc-ch))
(when (exn? lc-host-result) (raise lc-host-result))
(server-close! lc-server)

(printf "racket zig-smoke OK: a forwarding proxy answers its host's own local call (local and far target)\n")

;; ── The callback latch crosses the binding ────────────────────────────────────
;; A behavior that reaches for a host-driving verb mid-turn (session-fetch, here)
;; is refused by the C tier before it can block, the refusal surfaces as the
;; method's own raise, and the answer breaks with it — the turn neither
;; deadlocks nor corrupts the host. This is the loud edge of the binding rule
;; that a handler must not drive (or block on) the host inside its own turn.
;; The connection stays fully usable afterwards.
(define rt-server (listen "127.0.0.1" 0))
(define rt-ready (make-semaphore 0))
(define rt-ch (make-channel))
(define rt-host
  (thread
   (lambda ()
     (define hsession (accept rt-server))
     (session-publish hsession "svc"
                   (lambda (bcom)
                     (methods
                      [(reenter) (session-fetch hsession "nested")]
                      [(ping) (sym "pong")])))
     (semaphore-post rt-ready)
     (with-handlers ([(lambda (_) #t) (lambda (e) (channel-put rt-ch e))])
       (session-serve hsession)
       (channel-put rt-ch 'served)))))

(define rt-session (open-test-session (tcp-locator "127.0.0.1" (server-port rt-server))))
(semaphore-wait rt-ready)
(define rt-cap (session-fetch rt-session "svc"))
(define rt-broken
  (with-handlers ([exn:fail:pancake? values])
    (session-send rt-session rt-cap 'reenter) #f))
(expect (exn:fail:pancake? rt-broken)
        "reentry: a mid-turn driving verb breaks the answer")
;; The turn unwound cleanly: the same session still answers.
(expect (equal? (sym "pong") (session-send rt-session rt-cap 'ping))
        "reentry: the connection survives the refused turn")
(session-close! rt-session)
(define rt-host-result (channel-get rt-ch))
(when (exn? rt-host-result) (raise rt-host-result))
(server-close! rt-server)

(printf "racket zig-smoke OK: a behavior's mid-turn driving verb is refused and breaks its own answer\n")

;; ── Mid-turn close defers handle release ─────────────────────────────────────
;; A behavior that calls `session-close!` inside its own *wire* turn must not
;; free the native session while the trampoline frame is still on the stack. Local
;; vat turns do not set `inside-turn?` (they never enter the C latch); the park
;; is for the hosted trampoline path. Closing the transport drops the partner
;; before the reply can settle on the wire — the proof here is the park count
;; observed *during* the turn (1), not a far reply.
(define mc-server (listen "127.0.0.1" 0))
(define mc-ready (make-semaphore 0))
(define mc-during (make-channel))
(define mc-ch (make-channel))
(define mc-acceptor
  (thread
   (lambda ()
     (define hsession (accept mc-server))
     (session-publish hsession "svc"
                   (lambda (_bcom)
                     (methods
                      [(die)
                       (session-close! hsession)
                       ;; Native intent is already recorded; only handle release
                       ;; remains parked until this trampoline frame returns.
                       (channel-put mc-during
                                    (host-pending-release-count (session-host hsession)))
                       (sym "closing")])))
     (semaphore-post mc-ready)
     (with-handlers ([(lambda (_) #t) (lambda (e) (channel-put mc-ch e))])
       (session-serve hsession)
       (channel-put mc-ch 'served)))))

(define mc-session (open-test-session (tcp-locator "127.0.0.1" (server-port mc-server))))
(semaphore-wait mc-ready)
(define mc-svc (session-fetch mc-session "svc"))
;; Drive the deliver without awaiting a reply: closing the exporter mid-turn
;; drops the wire before a settle can land. A bounded thread races the send.
(define mc-client
  (thread
   (lambda ()
     (with-handlers ([exn:fail:pancake? void])
       (session-send mc-session mc-svc 'die)))))
(define mc-parked (sync/timeout 10 mc-during))
(expect (equal? 1 mc-parked)
        (format "mid-turn-close: release parked during the trampoline turn (got ~a)" mc-parked))
(thread-wait mc-client)
(session-close! mc-session)
(define mc-host-result (sync/timeout 10 mc-ch))
(when (exn? mc-host-result) (raise mc-host-result))
(server-close! mc-server)

(printf "racket zig-smoke OK: callback close records native intent and defers handle release\n")

;; Host close records its native admission barrier under the callback latch.
;; Racket defers only waiting and handle release until the feed unwinds, then
;; clears the Host's strong callback/session tables.
(define hr-server (listen "127.0.0.1" 0))
(define hr-ready (make-semaphore 0))
(define hr-during (make-channel))
(define hr-state (make-channel))
(define hr-acceptor
  (thread
   (lambda ()
     (define hsession (accept hr-server))
     (define sibling (accept hr-server))
     (define m (session-host hsession))
     (session-publish hsession "svc"
                      (lambda (_bcom)
                        (methods
                         [(release-host)
                          (host-close! m)
                          (channel-put hr-during
                                       (list (unbox (host-released? m))
                                             (host-pending-release-count m)))
                          (sym "closing")])))
     (semaphore-post hr-ready)
     (with-handlers ([(lambda (_) #t) void]) (session-serve hsession))
     (channel-put hr-state
                  (list (unbox (host-released? m))
                        (hash-count (host-keep m))
                        (hash-count (host-sessions m)))))))
(define hr-session (open-test-session (tcp-locator "127.0.0.1" (server-port hr-server))))
(define hr-sibling (open-test-session (tcp-locator "127.0.0.1" (server-port hr-server))))
(semaphore-wait hr-ready)
(define hr-svc (session-fetch hr-session "svc"))
(define hr-client
  (thread
   (lambda ()
     (with-handlers ([exn:fail:pancake? void])
       (session-send hr-session hr-svc 'release-host)))))
(expect (equal? '(#f 1) (sync/timeout 10 hr-during))
        "mid-turn Host close records intent and parks one handle-release barrier")
(thread-wait hr-client)
(define hr-final (sync/timeout 10 hr-state))
(expect (equal? '(#t 0 0) hr-final)
        (format "terminal host release clears retained state (got ~a)" hr-final))
(session-close! hr-session)
(session-close! hr-sibling)
(server-close! hr-server)

(printf "racket zig-smoke OK: callback Host close records intent then clears retained state\n")

;; Two explicit releases can both observe a live wrapper before either acquires
;; the host lock. Terminal state must therefore be checked after the wait, not
;; only before it: the second caller is an idempotent no-op, never a second
;; native release of the same pointer.
(define rr-host (make-fresh-host))
(define rr-started (make-semaphore 0))
(define rr-results (make-channel))
(semaphore-wait (host-lock rr-host))
(for ([i (in-range 2)])
  (thread
   (lambda ()
     (semaphore-post rr-started)
     (with-handlers ([(lambda (_e) #t) (lambda (e) (channel-put rr-results e))])
       (host-close! rr-host)
       (channel-put rr-results 'released)))))
(semaphore-wait rr-started)
(semaphore-wait rr-started)
;; Let both green threads reach the held lock before admitting either one.
(sleep 0)
(semaphore-post (host-lock rr-host))
(define rr-first (sync/timeout 10 rr-results))
(define rr-second (sync/timeout 10 rr-results))
(when (exn? rr-first) (raise rr-first))
(when (exn? rr-second) (raise rr-second))
(expect (and (eq? rr-first 'released)
             (eq? rr-second 'released)
             (unbox (host-released? rr-host)))
        "concurrent Host release crosses native teardown exactly once")

(printf "racket zig-smoke OK: concurrent Host release is serialized and idempotent\n")

;; A repeated close is not merely an idempotent wrapper call: every request
;; reaches the one native barrier. Hold FINISH open with a negotiating session,
;; kill the first public waiter, then prove a concurrent CANCEL still escalates
;; the retained worker and every surviving caller joins the terminal result.
(define re-host (make-fresh-host))
(open-pending-dialed! re-host)
(define re-results (make-channel))
(define re-finish-thread
  (thread
 (lambda ()
   (with-handlers ([(lambda (_e) #t) (lambda (e) (channel-put re-results e))])
     (host-close! re-host #:pending 'finish #:grace-ms #f)
     (channel-put re-results 'finished)))))
(let await-finishing ([remaining 1000])
  (when (zero? remaining) (fail "unbounded Host finish did not enter FINISHING"))
  (define state
    (call-with-host
     re-host
     (lambda ()
       (define-values (rc lifecycle)
         (pancake_host_close_progress (host-ptr re-host) (monotonic-ms)))
       (check/host rc)
       lifecycle)))
  (unless (= state LIFECYCLE-FINISHING)
    (sleep 0.001)
    (await-finishing (sub1 remaining))))
(define re-join-entered (make-semaphore 0))
(define re-join-thread
  (thread
   (lambda ()
     (semaphore-post re-join-entered)
     (with-handlers ([(lambda (_e) #t) (lambda (e) (channel-put re-results e))])
       (host-close! re-host #:pending 'finish #:grace-ms #f)
       (channel-put re-results 'joined)))))
(semaphore-wait re-join-entered)
;; Give the second caller a turn to enter the already-installed barrier, then
;; terminate only the caller that originally requested FINISH.
(sleep 0)
(kill-thread re-finish-thread)
(thread-wait re-finish-thread)
(define re-cancel-thread
  (thread
 (lambda ()
   (with-handlers ([(lambda (_e) #t) (lambda (e) (channel-put re-results e))])
     (host-close! re-host #:pending 'cancel)
     (channel-put re-results 'cancelled)))))
(define re-first (sync/timeout 10 re-results))
(define re-second (sync/timeout 10 re-results))
(when (exn? re-first) (raise re-first))
(when (exn? re-second) (raise re-second))
(expect (and (memq re-first '(joined cancelled))
             (memq re-second '(joined cancelled))
             (not (eq? re-first re-second))
             (unbox (host-released? re-host)))
        "killing the first Host close waiter does not stop the shared close worker")

(printf "racket zig-smoke OK: Host close worker outlives the first waiter\n")

;; A finish close whose finite grace expires reports ERR-TIMEOUT and still
;; crosses terminal release. The outcome is retained: a repeated close on the
;; released Host re-observes the same timeout instead of silently succeeding,
;; the contract the TypeScript, Rust, and Python Hosts hold.
(define gt-host (make-fresh-host))
(open-pending-dialed! gt-host)
(define gt-first
  (with-handlers ([exn:fail:pancake? values])
    (host-close! gt-host #:pending 'finish #:grace-ms 50)
    'completed))
(expect (and (exn:fail:pancake? gt-first)
             (= ERR-TIMEOUT (exn:fail:pancake-code gt-first))
             (unbox (host-released? gt-host)))
        "finish grace expiry surfaces ERR-TIMEOUT after terminal release")
(define gt-second
  (with-handlers ([exn:fail:pancake? values])
    (host-close! gt-host)
    'completed))
(expect (and (exn:fail:pancake? gt-second)
             (= ERR-TIMEOUT (exn:fail:pancake-code gt-second)))
        "a repeated close re-observes the retained timeout outcome")

(printf "racket zig-smoke OK: repeated Host close re-observes the finish timeout\n")

;; runtime-close! is the shutdown barrier for the Host the Runtime created:
;; after it returns, that Host is released, the session it yielded is retired,
;; and a repeated close joins the same terminal outcome.
(define rb-server (listen "127.0.0.1" 0))
(define rb-acceptor
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) void])
       (session-serve (accept rb-server))))))
(define rb-runtime (open-runtime #:providers (list (tcp-provider))))
(define rb-session
  (runtime-connect rb-runtime
                   (tcp-locator "127.0.0.1" (server-port rb-server))))
(define rb-host (runtime-host rb-runtime))
(runtime-close! rb-runtime)
(expect (unbox (host-released? rb-host))
        "runtime-close! returned before its Host crossed terminal release")
(expect (session-released? rb-session)
        "runtime-close! returned before its dialed session was retired")
(runtime-close! rb-runtime)
(thread-wait rb-acceptor)
(server-close! rb-server)

(printf "racket zig-smoke OK: runtime-close! is the Host shutdown barrier\n")

;; The loop-tier counterpart of the byte-fed grace-timeout scenario above: a
;; dial still negotiating against a silent TCP partner is admitted pending
;; work, so a finish close whose finite grace expires reports ERR-TIMEOUT
;; through the loop close barrier and still crosses terminal release. The
;; expiry takes effect only inside a `pancake_driver_step`, so this also
;; exercises the loop close driver's deadline-timer park.
(define lg-listener (tcp-listen 0 4 #t "127.0.0.1"))
(define lg-port
  (let-values ([(_host port _peer-host _peer-port)
                (tcp-addresses lg-listener #t)])
    port))
(define lg-runtime (open-runtime #:providers (list (tcp-provider))))
(define lg-dial-result (make-channel))
(define lg-dial-thread
  (thread
   (lambda ()
     (channel-put lg-dial-result
                  (with-handlers ([exn? values])
                    (runtime-connect lg-runtime
                                     (tcp-locator "127.0.0.1" lg-port))
                    'connected)))))
;; Accepting proves the dial reached TCP connect, so it is admitted pending
;; work before the close begins; the accepted ports then stay silent, so the
;; CapTP handshake can never finish inside the grace.
(define-values (lg-in lg-out) (tcp-accept lg-listener))
(define lg-first
  (with-handlers ([exn:fail:pancake? values])
    (host-close! (runtime-host lg-runtime) #:pending 'finish #:grace-ms 50)
    'completed))
(expect (and (exn:fail:pancake? lg-first)
             (= ERR-TIMEOUT (exn:fail:pancake-code lg-first))
             (unbox (host-released? (runtime-host lg-runtime))))
        "loop finish grace expiry surfaces ERR-TIMEOUT after terminal release")
(expect (exn? (sync/timeout 10 lg-dial-result))
        "the expiring loop close failed the admitted dial")
(thread-wait lg-dial-thread)
(close-input-port lg-in)
(close-output-port lg-out)
(tcp-close lg-listener)

(printf "racket zig-smoke OK: loop finish close reports its grace timeout\n")

;; An ordinary dial has no close driver to supply a timer. Accept TCP and then
;; stay silent: the binding's one progress clock must wake at HostRuntime's
;; handshake deadline and project the native ERR-TIMEOUT event.
(define hd-listener (tcp-listen 0 4 #t "127.0.0.1"))
(define hd-port
  (let-values ([(_host port _peer-host _peer-port)
                (tcp-addresses hd-listener #t)])
    port))
(define hd-runtime
  (open-runtime #:providers (list (tcp-provider))
                #:handshake-timeout-ms 50))
(define hd-result (make-channel))
(define hd-thread
  (thread
   (lambda ()
     (channel-put hd-result
                  (with-handlers ([exn? values])
                    (runtime-connect hd-runtime
                                     (tcp-locator "127.0.0.1" hd-port)))))))
(define-values (hd-in hd-out) (tcp-accept hd-listener))
(define hd-outcome (sync/timeout 2 hd-result))
(expect (and (exn:fail:pancake? hd-outcome)
             (= ERR-TIMEOUT (exn:fail:pancake-code hd-outcome)))
        "a silent loop dial did not reach its native handshake deadline")
(thread-wait hd-thread)
(runtime-close! hd-runtime)
(close-input-port hd-in)
(close-output-port hd-out)
(tcp-close hd-listener)

(printf "racket zig-smoke OK: a silent loop dial reaches pancake's native handshake deadline\n")

;; Session close has the same ownership contract. A negotiating byte-fed
;; session keeps unbounded FINISH pending; killing the first waiter must not
;; strand the worker that a later CANCEL needs to reach physical release.
(define sc-host (make-fresh-host))
(define sc-session
  (open-dialed-over
   sc-host
   "tcp"
   "pending-session-close"
   (async-transport (lambda (_frame) (void)) void (lambda (_wake) eof) void)))
(define sc-results (make-channel))
(define sc-first
  (thread
   (lambda ()
     (with-handlers ([(lambda (_e) #t) (lambda (e) (channel-put sc-results e))])
       (session-close! sc-session #:pending 'finish #:grace-ms #f)
       (channel-put sc-results 'first)))))
(let await-session-worker ([remaining 1000])
  (when (zero? remaining) (fail "unbounded Session finish did not install its worker"))
  (unless (hash-ref session-close-active sc-session #f)
    (sleep 0.001)
    (await-session-worker (sub1 remaining))))
(define sc-join-entered (make-semaphore 0))
(define sc-join
  (thread
   (lambda ()
     (semaphore-post sc-join-entered)
     (with-handlers ([(lambda (_e) #t) (lambda (e) (channel-put sc-results e))])
       (session-close! sc-session #:pending 'finish #:grace-ms #f)
       (channel-put sc-results 'joined)))))
(semaphore-wait sc-join-entered)
(sleep 0)
(kill-thread sc-first)
(thread-wait sc-first)
(define sc-cancel
  (thread
   (lambda ()
     (with-handlers ([(lambda (_e) #t) (lambda (e) (channel-put sc-results e))])
       (session-close! sc-session #:pending 'cancel)
       (channel-put sc-results 'cancelled)))))
(define sc-one (sync/timeout 10 sc-results))
(define sc-two (sync/timeout 10 sc-results))
(when (exn? sc-one) (raise sc-one))
(when (exn? sc-two) (raise sc-two))
(expect (and (memq sc-one '(joined cancelled))
             (memq sc-two '(joined cancelled))
             (not (eq? sc-one sc-two))
             (session-released? sc-session))
        "killing the first Session close waiter does not stop the shared close worker")
(host-close! sc-host)

(printf "racket zig-smoke OK: Session close worker outlives the first waiter\n")

;; A FLUSH runs after the Host lock has released and may have no immediate
;; caller of its own. Inject one exact transport exception through a real CapTP
;; pair: the tell that provokes it, the concurrent serve loop, and repeated
;; close must all receive that same object, after the byte channel has retired
;; exactly once. One broken Session must not escape through the Host drain.
(define wf-server (listen "127.0.0.1" 0))
(define wf-ready (make-semaphore 0))
(define wf-server-result (make-channel))
(define wf-server-thread
  (thread
   (lambda ()
     (define c (accept wf-server))
     (session-publish c "svc" (lambda (bcom) (methods [(ping) 'alive])))
     (semaphore-post wf-ready)
     (channel-put wf-server-result
                  (with-handlers ([(lambda (_) #t) values])
                    (session-serve c)
                    'closed)))))
(define-values (wf-in wf-out)
  (tcp-connect "127.0.0.1" (server-port wf-server)))
(define wf-base (port-transport wf-in wf-out))
(define wf-fail-writes? (box #f))
(define wf-close-count (box 0))
(define wf-first-failure
  (exn:fail "injected exact FLUSH failure" (current-continuation-marks)))
(define wf-transport
  (async-transport
   (lambda (frame)
     (if (unbox wf-fail-writes?)
         (raise wf-first-failure)
         ((async-transport-write-frame! wf-base) frame)))
   (async-transport-flush! wf-base)
   (async-transport-read-some! wf-base)
   (lambda ()
     (set-box! wf-close-count (add1 (unbox wf-close-count)))
     ((async-transport-close! wf-base)))))
(define wf-host (make-fresh-host))
(define wf-session
  (establish-dialed-locator-session wf-host (server-locator wf-server) wf-transport))
(semaphore-wait wf-ready)
(define wf-client-result (make-channel))
(define wf-client-thread
  (thread
   (lambda ()
     (channel-put wf-client-result
                  (with-handlers ([(lambda (_) #t) values])
                    (session-serve wf-session)
                    'closed)))))
(define wf-svc (session-fetch wf-session "svc"))
(set-box! wf-fail-writes? #t)
(define wf-tell-failure
  (with-handlers ([(lambda (_) #t) values])
    (session-tell wf-session wf-svc 'ping)
    'no-error))
(define wf-serve-failure (sync/timeout 10 wf-client-result))
(define wf-close-failure
  (with-handlers ([(lambda (_) #t) values])
    (session-close! wf-session)
    'no-error))
(expect (eq? wf-first-failure wf-tell-failure)
        "wire failure: tell lost the exact FLUSH exception")
(expect (eq? wf-first-failure wf-serve-failure)
        "wire failure: serve lost the exact FLUSH exception")
(expect (eq? wf-first-failure wf-close-failure)
        "wire failure: close lost the exact FLUSH exception")
(expect (= 1 (unbox wf-close-count))
        "wire failure: terminal observers ran before one physical retirement")
(thread-wait wf-client-thread)
(define wf-server-outcome (sync/timeout 10 wf-server-result))
(expect (eq? 'closed wf-server-outcome)
        "wire failure: the peer did not retire cleanly after the broken Session closed")
(thread-wait wf-server-thread)
(host-close! wf-host)
(server-close! wf-server)

(printf "racket zig-smoke OK: Session tell, serve, and close retain the exact first FLUSH failure\n")

;; ── Time-travel: restore retargets wire delivers ──────────────────────────────
;; The README's headline time-travel claim, pinned over the wire: snapshot a
;; served vat, mutate the actor through wire delivers, restore, and observe
;; the NEXT wire deliver hit the restored behavior — proving `vat-restore!`
;; retargets what the trampoline dispatches, not just local `$` calls.
(define tt-server (listen "127.0.0.1" 0 #:time-travel? #t))
(define tt-ready (make-semaphore 0))
(define tt-vat-box (box #f))
(define tt-host
  (thread
   (lambda ()
     (define hsession (accept tt-server))
     (set-box! tt-vat-box (session-vat hsession))
     (session-publish hsession "counter" ^counter 10)
     (semaphore-post tt-ready)
     (with-handlers ([(lambda (_) #t) void]) (session-serve hsession)))))
(define tt-session (open-test-session (tcp-locator "127.0.0.1" (server-port tt-server))))
(semaphore-wait tt-ready)
(define tt-cap (session-fetch tt-session "counter"))
(expect (= 15 (session-send tt-session tt-cap 'add 5)) "time-travel: first wire add lands")
(define tt-snap (vat-snapshot (unbox tt-vat-box)))
(expect (= 115 (session-send tt-session tt-cap 'add 100)) "time-travel: second wire add lands")
(vat-restore! (unbox tt-vat-box) tt-snap)
;; The next WIRE deliver must see the restored state (15), not the later one.
(expect (= 15 (session-send tt-session tt-cap 'get))
        "time-travel: restore retargeted the wire deliver to the snapshot state")
(expect (= 22 (session-send tt-session tt-cap 'add 7))
        "time-travel: the restored behavior keeps serving from the snapshot")
(session-close! tt-session)
(server-close! tt-server)

(printf "racket zig-smoke OK: vat-restore! retargets wire delivers to the snapshot state\n")

;; ── Listener fires run outside the host lock ──────────────────────────────────
;; An `on` listener is arbitrary application code; the drain that settles its
;; vow runs under the host lock, so the fire itself is deferred to after the
;; lock releases — a listener that ran under the lock could wedge every other
;; thread sharing the host. The listener proves it directly: at fire time this
;; thread must not own the host lock, and an enqueueing verb (a tell) must go
;; through. (Fires also run after the reader gate clears, so a listener may
;; pump this connection — but must not block the reader turn that produced
;; the settle; enqueue and return.)
(define lf-server (listen "127.0.0.1" 0))
(define lf-ready (make-semaphore 0))
(define lf-told (make-channel))
(define lf-acceptor
  (thread
   (lambda ()
     (define hsession (accept lf-server))
     (session-publish hsession "svc"
                   (lambda (bcom)
                     (methods
                      [(first) 1]
                      [(notify) (channel-put lf-told 'told) 2])))
     (semaphore-post lf-ready)
     (with-handlers ([(lambda (_) #t) void]) (session-serve hsession)))))
(define lf-session (open-test-session (tcp-locator "127.0.0.1" (server-port lf-server))))
(semaphore-wait lf-ready)
(define lf-svc (session-fetch lf-session "svc"))
(define lf-host (session-host lf-session))
(define lf-under-lock (box 'unfired))
(define lf-vow (with-vat (session-vat lf-session) (<- lf-svc 'first)))
(with-vat (session-vat lf-session)
  (on lf-vow
      (lambda (v)
        (set-box! lf-under-lock (eq? (unbox (host-lock-owner lf-host)) (current-thread)))
        ;; An enqueueing verb from inside the fire: legal, takes the host lock
        ;; the fire no longer holds.
        (session-tell lf-session lf-svc 'notify))))
(expect (= 1 (session-await lf-session lf-vow)) "listener-fire: the send settled")
(expect (eq? #f (unbox lf-under-lock))
        "listener-fire: the fire ran with the host lock released")
(expect (eq? 'told (sync/timeout 10 lf-told))
        "listener-fire: the listener's tell reached the partner")
(session-close! lf-session)
(server-close! lf-server)

(printf "racket zig-smoke OK: an on listener fires outside the host lock and can enqueue\n")

;; ── Alias-only unpublish ──────────────────────────────────────────────────────
;; Discovery moves, the issued capability does not: after
;; `host-unpublish-giftable` a fetch of the name breaks even on the session
;; that fetched it before, a second removal is a loud #f, and the ref fetched
;; before removal still answers.
(define up-server (listen "127.0.0.1" 0))
(host-publish-giftable (server-host up-server) "ephemeral" (methods [(probe) 11]))
(define up-thread
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) void])
       (define hsession (accept up-server))
       (session-serve hsession)))))
(define up-session (open-test-session (tcp-locator "127.0.0.1" (server-port up-server))))
(define up-cap (session-fetch up-session "ephemeral"))
(expect (equal? 11 (session-send up-session up-cap 'probe)) "unpublish: the alias fetches and answers before removal")
(expect (eq? #t (host-unpublish-giftable (server-host up-server) "ephemeral"))
        "unpublish: removing a live alias reports #t")
(expect (eq? #f (host-unpublish-giftable (server-host up-server) "ephemeral"))
        "unpublish: removing an absent alias reports #f")
(expect (with-handlers ([exn:fail? (lambda (_) #t)])
          (session-fetch up-session "ephemeral")
          #f)
        "unpublish: a fetch of the removed alias breaks on the session that fetched it")
(expect (equal? 11 (session-send up-session up-cap 'probe))
        "unpublish: the capability issued before removal still answers")

;; Durable publication (ADR-0098): the minted swiss name fetches on the live
;; session, removal makes a later fetch miss, and the capability issued before
;; removal still answers.
(define up-swiss (host-publish-durable (server-host up-server) (methods [(probe) 21])))
(expect (and (= 50 (string-length up-swiss))
             (equal? "pancake-durable-1-" (substring up-swiss 0 18)))
        "durable: the minted swiss carries the durable prefix and length")
(define up-durable (session-fetch up-session up-swiss))
(expect (equal? 21 (session-send up-session up-durable 'probe))
        "durable: the minted swiss fetches and answers")
(expect (eq? #t (host-remove-durable (server-host up-server) up-swiss))
        "durable: removing a live durable name reports #t")
(expect (eq? #f (host-remove-durable (server-host up-server) up-swiss))
        "durable: removing an absent durable name reports #f")
(expect (with-handlers ([exn:fail? (lambda (_) #t)])
          (session-fetch up-session up-swiss)
          #f)
        "durable: a fetch of the removed name breaks")
(expect (equal? 21 (session-send up-session up-durable 'probe))
        "durable: the capability issued before removal still answers")
(session-close! up-session)
(kill-thread up-thread)
(server-close! up-server)

;; ── A redeem dial must not park the host ──────────────────────────────────────
;; The recipient half of a three-party handoff opens its own socket to the
;; exporter (a DIAL action). A dial is a connect syscall plus a whole keyed
;; handshake, so the drain defers it post-lock like every write and fire: a
;; slow exporter stalls that one redeem, never every thread sharing the host.
;; Proven with a deterministic stall in a raw byte relay — the redeem dial has
;; connected, but the relay has not yet opened its exporter leg, so its
;; handshake parks — while a sibling connection on the recipient's host
;; completes a full send. Releasing the relay then lets the parked redeem
;; finish end-to-end, which also proves the whole hermetic three-party flow:
;; gift originated by the gifter's host, deposited on the exporter, withdrawn
;; over a real DIAL, and the redeemed capability called directly.
(define rd-e-server (listen "127.0.0.1" 0))
;; Host-wide, not session-published: deposit retains the actor before the
;; recipient's redeem dial opens, and withdrawal projects that exact actor onto
;; the new exporter session without resolving the alias again.
(host-publish-giftable (server-host rd-e-server) "gifted"
                       (let ([n (box 7)])
                         (methods [(use) (unbox n)]
                                  [(bump) (set-box! n 8) 8])))
(define rd-release-relay (make-semaphore 0))
(define rd-dial-reached (make-semaphore 0))
(define-values (rd-relay rd-relay-port)
  (start-sniffing-relay
   (server-port rd-e-server)
   (lambda (_chunk) #f)
   #:before-connect
   (lambda ()
     (semaphore-post rd-dial-reached)
     (semaphore-wait rd-release-relay))))
(define rd-e-thread
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) void])
       ;; Accept exactly one connection now — the gifter's — and serve it so
       ;; the gifter's deposit is read. The second accept waits for the relay
       ;; to open its exporter leg after the stalled-dial assertion.
       (define hsession (accept rd-e-server))
       (thread (lambda () (with-handlers ([(lambda (_) #t) void]) (session-serve hsession))))
       (define rconn (accept rd-e-server))
       (with-handlers ([(lambda (_) #t) void]) (session-serve rconn))))))
(define rd-g-server (listen "127.0.0.1" 0))
;; Sibling probe peer: a second listen so the recipient host can hold two
;; live sessions without a second dial to the same address designator
;; (SessionPairExists). Same host, different partner — that is the lock pin.
(define rd-ping-server (listen "127.0.0.1" 0))
;; The gifter dials the exporter on its server's host, so the tool it fetches
;; and the introductions it serves share one identity and handoff router.
(define rd-gc (open-test-session (tcp-locator "127.0.0.1" (server-port rd-e-server))
                       #:adopt-host (server-host rd-g-server)))
(session-set-exporter-locator!
 rd-gc
 (locator TRANSPORT-TCP
          (tcp-address-designator "127.0.0.1" rd-relay-port)
          (hash)
          'map))
(define rd-tool (session-fetch rd-gc "gifted"))
;; Mutate the tool through the gifter, then replace the alias with a decoy:
;; the later withdrawal must project the exact mutated actor the gifter holds,
;; never whatever the name resolves to at withdraw time (ADR-0096, on the
;; binding path).
(expect (= 8 (session-send rd-gc rd-tool 'bump))
        "redeem-dial: the gifter mutated the tool before introducing it")
(host-publish-giftable (server-host rd-e-server) "gifted" (methods [(use) 0]))
(define rd-g-ready (make-semaphore 0))
(define rd-g-thread
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) void])
       (let accept-loop ([first? #t])
         (define hsession (accept rd-g-server))
         (session-publish hsession "intro"
                       (lambda (bcom)
                         (methods
                          ;; Replying with a capability that lives on another
                          ;; connection makes the host originate a give.
                          [(get-tool) rd-tool])))
         (when first? (semaphore-post rd-g-ready))
         (thread (lambda () (with-handlers ([(lambda (_) #t) void]) (session-serve hsession))))
         (accept-loop #f))))))
(define rd-ping-ready (make-semaphore 0))
(define rd-ping-thread
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) void])
       (define hsession (accept rd-ping-server))
       (session-publish hsession "ping"
                     (lambda (bcom) (methods [(ping) "pong"])))
       (semaphore-post rd-ping-ready)
       (with-handlers ([(lambda (_) #t) void]) (session-serve hsession))))))
(define rd-r-main (open-test-session (tcp-locator "127.0.0.1" (server-port rd-g-server))))
(semaphore-wait rd-g-ready)
(define rd-r-side (open-test-session (tcp-locator "127.0.0.1" (server-port rd-ping-server))
                           #:adopt-host (session-host rd-r-main)))
(semaphore-wait rd-ping-ready)
(define rd-intro-main (session-fetch rd-r-main "intro"))
(define rd-ping-side (session-fetch rd-r-side "ping"))
;; Trigger the handoff: the reply is a give, the recipient's host auto-redeems
;; it, and the send settles only after the withdraw — so this thread is parked
;; in the stalled dial until the exporter is released.
(define rd-tool-ch (make-channel))
(void (thread
       (lambda ()
         (with-handlers ([(lambda (_) #t) (lambda (e) (channel-put rd-tool-ch e))])
           (channel-put rd-tool-ch (session-send rd-r-main rd-intro-main 'get-tool))))))
;; The dial is provably in flight once the relay accepts it. Its exporter leg
;; remains unopened until `rd-release-relay` is posted below.
(expect (sync/timeout 30 rd-dial-reached)
        "redeem-dial: the redeem dial never reached the exporter relay")
;; THE PIN: with the dial stalled mid-handshake, a sibling connection sharing
;; the recipient's host must still complete a full send. If the dial executor
;; held the host lock, this send would wedge and the timeout would fail loud.
(define rd-probe-ch (make-channel))
(void (thread
       (lambda ()
         (with-handlers ([(lambda (_) #t) (lambda (e) (channel-put rd-probe-ch e))])
           (channel-put rd-probe-ch (session-send rd-r-side rd-ping-side 'ping))))))
(define rd-probe (sync/timeout 15 rd-probe-ch))
(expect (equal? rd-probe "pong")
        "redeem-dial: a sibling send settled while the dial was stalled")
;; Release the relay: the parked handshake completes, the withdraw settles,
;; and the redeemed capability answers a direct call.
(semaphore-post rd-release-relay)
(define rd-tool-cap (sync/timeout 30 rd-tool-ch))
(expect (and rd-tool-cap (not (exn? rd-tool-cap)))
        "redeem-dial: the gifted capability settled after the exporter released")
(expect (= 8 (session-send rd-r-main rd-tool-cap 'use))
        "redeem-dial: the redeemed capability is the exact mutated actor, not the alias's decoy")
(session-close! rd-r-main)
(session-close! rd-r-side)
(session-close! rd-gc)
(tcp-close rd-relay)
(server-close! rd-g-server)
(server-close! rd-ping-server)
(server-close! rd-e-server)

(printf "racket zig-smoke OK: a redeem dial runs post-lock and a stalled exporter parks one redeem, not the host\n")

;; ── Answering across an introduction: session-send-redeeming's `via` ──────────
;; An introduction answers with a capability whose home is a different
;; session: the host redeems the give by dialing the exporter, and the reply
;; lives in that fresh direct session rather than the session the introduction
;; arrived over. `session-send-redeeming` returns that session as `via`. It
;; matters because an OCapN near export names a position in one specific
;; session, so an inbox the caller hands back to the exporter is only meaningful
;; when it was spawned in the session through which the exporter is reached.
;; This scene proves the whole loop: `via` is a live session, an ordinary send
;; to the redeemed capability rides it, and an inbox
;; spawned on it is reachable — the exporter calls it and the note arrives. The
;; last two expectations pin the #f arm, where no redeemed route is in play.
(define sr-e-server (listen "127.0.0.1" 0))
;; The session the recipient's redeem dial opens. The exporter answers the
;; caller's inbox over it, which is the far half of the same claim.
(define sr-direct (box #f))
(host-publish-giftable
 (server-host sr-e-server)
 "gifted"
 (methods
  [(use) 7]
  [(dm text inbox)
   ;; A hosted turn must not drive the host, so a separate thread tells the
   ;; caller's inbox and flushes it, exactly as the cross-thread scene above.
   (thread (lambda ()
             (with-handlers ([(lambda (_) #t) void])
               (define d (unbox sr-direct))
               (session-tell d inbox 'note text)
               (session-flush! d))))
   "sent"]))
(define sr-e-thread
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) void])
       (let accept-loop ([n 0])
         (define hsession (accept sr-e-server))
         ;; The first partner is the gifter depositing the gift; the second is
         ;; the recipient's redeem dial, the session an inbox belongs in.
         (unless (zero? n) (set-box! sr-direct hsession))
         (thread
          (lambda ()
            (with-handlers ([(lambda (_) #t) void])
              (session-serve hsession))))
         (accept-loop (add1 n)))))))
(define sr-g-server (listen "127.0.0.1" 0))
(define sr-gc (open-test-session (tcp-locator "127.0.0.1" (server-port sr-e-server))
                       #:adopt-host (server-host sr-g-server)))
(define sr-tool (session-fetch sr-gc "gifted"))
(define sr-g-ready (make-semaphore 0))
(define sr-g-thread
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) void])
       (define hsession (accept sr-g-server))
       ;; Spawned before the turn, not inside it: a hosted method may not drive
       ;; the host, and this is the ordinary-reply control for the scene.
       (define own (session-spawn hsession (lambda (bcom) (methods [(hi) "hi"]))))
       (session-publish hsession "intro"
                        (lambda (bcom)
                          (methods
                           ;; A capability hosted on another connection, so
                           ;; replying with it makes the host originate a give.
                           [(get-tool) sr-tool]
                           ;; A capability of this session's own.
                           [(get-own) own])))
       (semaphore-post sr-g-ready)
       (session-serve hsession)))))
;; Keep the recipient Host byte-fed so the handoff redeem must realize its
;; exporter TCP channel on the same active Host, never transfer that Host into
;; the native driver after its broker session exists.
(define sr-r-loc (tcp-locator "127.0.0.1" (server-port sr-g-server)))
(define sr-r-host (make-fresh-host))
(define sr-r
  (open-test-session sr-r-loc #:adopt-host sr-r-host #:connector (tcp-connector)))
(semaphore-wait sr-g-ready)
(define sr-intro (session-fetch sr-r "intro"))
(define-values (sr-tool-cap sr-via) (session-send-redeeming sr-r sr-intro 'get-tool))
(expect (session? sr-via)
        "send-redeeming: the redeemed reply surfaced its exporter session")
(expect (not (eq? sr-via sr-r))
        "send-redeeming: the exporter session is not the introducing session")
(expect (= 7 (session-send sr-via sr-tool-cap 'use))
        "send-redeeming: the redeemed capability answered over its own session")
;; The point of the whole verb: an inbox spawned on `via` is a position the
;; exporter can reach, so the exporter's reply lands in it.
(define sr-note (box #f))
(define sr-noted (make-semaphore 0))
(define sr-inbox
  (session-spawn sr-via
                 (lambda (bcom)
                   (methods [(note text) (set-box! sr-note text) (semaphore-post sr-noted)]))))
(expect (equal? "sent" (session-send sr-via sr-tool-cap 'dm "hello" sr-inbox))
        "send-redeeming: the direct session carried the reply inbox to the exporter")
(expect (sync/timeout 30 sr-noted)
        "send-redeeming: the exporter reached the inbox hosted on the direct session")
(expect (equal? "hello" (unbox sr-note))
        "send-redeeming: the exporter's answer arrived on the direct session")
;; An ordinary far reply names no redeemed route, so there is nothing to
;; surface and `via` is #f. A caller then works on the session it already has.
(define-values (sr-own-cap sr-own-via) (session-send-redeeming sr-r sr-intro 'get-own))
(expect (eq? #f sr-own-via)
        "send-redeeming: an ordinary far reply has no exporter session")
(expect (equal? "hi" (session-send (or sr-own-via sr-r) sr-own-cap 'hi))
        "send-redeeming: (or via c) is the session an ordinary reply works on")
(session-close! sr-r)
(session-close! sr-gc)
(server-close! sr-g-server)
(server-close! sr-e-server)

(printf "racket zig-smoke OK: session-send-redeeming surfaces the direct session a redeemed reply lives on\n")

;; ── À-la-carte transports: one round-trip over each composable transport module ─
;; Each transport archive ships as its own composable module (`pancake-tcp.rkt`,
;; `pancake-inproc.rkt`) whose connections shuttle whole frames. These two
;; sections drive the *same* full deliver/serve/resolve round-trip between two
;; byte-fed Host sessions over each explicit netlayer's connections, proving a
;; Racket consumer composes the host tier with a transport à la carte exactly
;; as a C consumer links the archives. Each side is a real `session` (its
;; own node, vat, and keyed handshake); only the transport's (read, write) pair
;; differs, so the driving logic is shared.
;;
;; The exchange is single-threaded on purpose. Unlike Racket's own
;; scheduler-aware ports, these explicit C-ABI netlayers park the whole Racket
;; place for the duration of a foreign read or write, so two connections cannot
;; rendezvous across green threads in one place. The script therefore orders
;; every blocking read after the frame it waits for is already in flight: both
;; hellos leave before either side pumps its handshake, and each fetch/call leg
;; feeds exactly the frame the previous leg wrote.
(define (outer-frame-bytes frame)
  (bytes-append
   (string->bytes/utf-8 (format "~a:" (bytes-length frame)))
   frame))

(define (connection-transport read-frame write-frame!)
  ;; The host pump writes byte-stream frames as two chunks: the canonical
  ;; outer length prefix, then the bare codec frame. Explicit C connections take
  ;; and return that bare frame as one unit. Keep the representation change at
  ;; this composition boundary, and verify the pump's pair before discarding
  ;; its prefix.
  (define pending-prefix #f)
  (define (write-chunk! chunk)
    (cond
      [pending-prefix
       (define expected
         (string->bytes/utf-8 (format "~a:" (bytes-length chunk))))
       (unless (bytes=? pending-prefix expected)
         (error 'connection-transport "non-canonical outer frame prefix"))
       (set! pending-prefix #f)
       (write-frame! chunk)]
      [else (set! pending-prefix chunk)]))
  (define (flush!)
    (when pending-prefix
      (error 'connection-transport "outer frame ended before its body")))
  (async-transport
   write-chunk!
   flush!
   (lambda (_wake)
     (define frame (read-frame))
     (if (eof-object? frame)
         eof
         (outer-frame-bytes frame)))
   void))

;; The minting half of `session-fetch`, without its blocking pump: queue the
;; bootstrap fetch, register the vow so the drain can route its completion,
;; and flush; the caller shuttles the frames and reads the vow's state.
(define (scripted-fetch! c name)
  (define m (session-host c))
  (with-host-drain m
    (lambda ()
      (define nb (string->bytes/utf-8 name))
      (define-values (rc id)
        (pancake_host_session_fetch (session-ptr c) (pin-immobile nb) (bytes-length nb)))
      (check/host rc)
      (define fresh (session-vow c id 'pending '()))
      (register-vow! m fresh)
      ;; The drain parks the fetch deliver on the connection's pending-writes
      ;; FIFO; `with-host-drain` runs the write once the lock releases, like
      ;; every drain.
      (values (drain-host-actions! m) fresh))))

;; Read one whole frame off the connection and feed its bytes (the feed drains,
;; so a reply this frame provokes is written back through the same transport).
(define (feed-next! c read-frame)
  (feed-bytes! c (outer-frame-bytes (read-frame))))

(define (transport-counter-roundtrip client-read client-write! server-read server-write!)
  (define chost (make-fresh-host))
  (define shost (make-fresh-host))
  ;; Both hellos leave before either side pumps, so neither establish blocks.
  (define client-session (open-dialed-over chost "tcp" (tcp-address-designator "127.0.0.1" 1)
                                        (connection-transport client-read client-write!)))
  (drain-host! chost)  ; the dialer's signed op:start-session is in flight
  (define server-session (open-accepted-over shost "tcp" (tcp-address-designator "127.0.0.1" 1)
                                          (connection-transport server-read server-write!)
                                          #:designator-scheme DESIGNATOR-SCHEME-ADDRESS))
  (drain-host! shost)  ; the acceptor's hello crosses it
  ;; #f: no handshake bound. Both hellos are already in the paired in-memory
  ;; transports, so each pump reads a frame that is waiting for it.
  (run-handshake! server-session #f)
  (run-handshake! client-session #f)
  ;; Publish, fetch, call: deliver, serve, resolve, one leg at a time.
  (session-publish server-session "counter" ^counter 10)
  (define fetched (scripted-fetch! client-session "counter"))
  (feed-next! server-session server-read)   ; the bootstrap fetch deliver
  (feed-next! client-session client-read)   ; its resolution settles the fetch
  (expect (and (pair? (session-vow-state fetched)) (eq? 'ok (car (session-vow-state fetched))))
          "transport: the scripted fetch fulfilled")
  (define counter-ref (cdr (session-vow-state fetched)))
  (expect (ref? counter-ref) "transport: fetched a capability")
  (define vow (session-far-send client-session counter-ref 'add '(5) #t))
  (drain-host! chost)                    ; the deliver leaves
  (feed-next! server-session server-read)   ; the served turn runs, the resolve leaves
  (feed-next! client-session client-read)   ; the resolve settles the vow
  (define settled (session-vow-state vow))
  (session-close! client-session)
  (session-close! server-session)
  (and (pair? settled) (eq? 'ok (car settled)) (cdr settled)))

;; libpancake_net_transport_inproc: the socket-free netlayer. A listener binds a
;; string designator; a dialer names it. The listener adds only a wake descriptor
;; so a Racket green thread can park without freezing the place.
(define inproc-nl (make-inproc-netlayer))
(define inproc-lst (inproc-netlayer-listen inproc-nl "smoke-rendezvous"))
(define inproc-accept-started (make-semaphore 0))
(define inproc-accepted (make-channel))
(define inproc-accept-thread
  (thread (lambda ()
            (semaphore-post inproc-accept-started)
            (channel-put inproc-accepted (inproc-listener-accept inproc-lst)))))
(semaphore-wait inproc-accept-started)
;; If accept entered the blocking C call directly, this connect could never run:
;; both are green threads in this place. The readiness gate parks only accepter.
(define inproc-client (inproc-netlayer-connect inproc-nl "smoke-rendezvous"))
(define inproc-server (channel-get inproc-accepted))
(define inproc-total
  (transport-counter-roundtrip
   (lambda () (inproc-connection-read-frame inproc-client))
   (lambda (f) (inproc-connection-write-frame! inproc-client f))
   (lambda () (inproc-connection-read-frame inproc-server))
   (lambda (f) (inproc-connection-write-frame! inproc-server f))))
(expect (equal? 15 inproc-total) "inproc: counter.add(5) round-tripped to 15 over the socket-free netlayer")
(inproc-netlayer-release! inproc-nl)
;; Netlayer release owns its borrowed children; their explicit releases remain
;; idempotent and must never touch the backend that is now gone.
(inproc-connection-release! inproc-client)
(inproc-connection-release! inproc-server)
(inproc-listener-release! inproc-lst)

(printf "racket zig-smoke OK: drove OCapN over the socket-free in-process netlayer\n")

;; libpancake_net_transport_tcp: the explicit C-ABI TCP netlayer (cleartext,
;; loopback-grade). Same round-trip over real sockets, proving the tcp module
;; composes with the host tier just as inproc does, a different archive, one core.
(define tcp-nl (make-netlayer))
(define tcp-lst (netlayer-listen tcp-nl "127.0.0.1" 0))
(define tcp-port (listener-port tcp-lst))
(define tcp-accept-started (make-semaphore 0))
(define tcp-accepted (make-channel))
(define tcp-accept-thread
  (thread (lambda ()
            (semaphore-post tcp-accept-started)
            (channel-put tcp-accepted (listener-accept tcp-lst)))))
(semaphore-wait tcp-accept-started)
(define tcp-client (netlayer-connect tcp-nl "127.0.0.1" tcp-port))
(define tcp-server (channel-get tcp-accepted))
(define tcp-total
  (transport-counter-roundtrip
   (lambda () (connection-read-frame tcp-client))
   (lambda (f) (connection-write-frame! tcp-client f))
   (lambda () (connection-read-frame tcp-server))
   (lambda (f) (connection-write-frame! tcp-server f))))
(expect (equal? 15 tcp-total) "tcp netlayer: counter.add(5) round-tripped to 15 over the C-ABI TCP transport")
(netlayer-release! tcp-nl)
(connection-release! tcp-client)
(connection-release! tcp-server)
(listener-release! tcp-lst)

(printf "racket zig-smoke OK: drove OCapN over the C-ABI TCP netlayer\n")
;; libpancake_net_transport_onion: the one netlayer the OCapN draft standardizes,
;; reached through a Tor daemon the deployment runs. There is no Tor here, so a
;; fake control endpoint on loopback answers the exact requests pancake sends. The
;; bytes those requests must contain are pinned on the Zig side against the pinned
;; Spritely Goblins netlayer and the upstream OCapN suite; this proves the Racket
;; surface reaches them and reads the answers back.
(define onion-service-id "wy46gxdweyqn5m7ntzwlxinhdia2jjanlsh37gxklwhfec7yxqr4k3qd")
(define onion-service-key #"ED25519-V3:c3RvcmVk")

;; The fake daemon runs as a child process, and that is not incidental. A foreign
;; call marked `#:blocking?` tells the Racket runtime the call may block, so the
;; collector stays cooperative; it does not hand the scheduler to another Racket
;; thread. Every green thread in this place stops for the whole call. Since
;; `onion-netlayer-listen` and `onion-listener-accept` each wait on an answer from
;; the daemon, a daemon written as a thread beside them would be waiting for a
;; scheduler that cannot run until it replies. `zig-smoke-fake-tor.rkt` carries the
;; same note where the daemon lives.
(define-runtime-path fake-tor-path "zig-smoke-fake-tor.rkt")

;; The SOCKS endpoint for the sections that never dial: an absolute Unix socket
;; path, which is the other form `make-onion-netlayer` accepts and the one a
;; distribution's Tor actually offers. Nothing is bound there, so a section that
;; reached it would fail rather than quietly connect somewhere.
(define absent-socks "/run/pancake-smoke/absent.socks")

;; The first record in `seen` matching `rx`, or #f. Records accumulate newest-first.
(define (seen-line seen rx)
  (for/first ([line (in-list (reverse (unbox seen)))] #:when (regexp-match rx line))
    line))

;; Wait for a record matching `rx`, so a test never races the daemon. Raises rather
;; than returning #f: an absent record means the daemon never saw the request, which
;; is a failure to report and not a value to compare against.
(define (await-record seen rx)
  (let loop ([tries 500])
    (cond [(seen-line seen rx) => (lambda (line) (cadr (regexp-match rx line)))]
          [(zero? tries) (error 'await-record "no record matching ~a arrived" rx)]
          [else (sleep 0.01) (loop (sub1 tries))])))

;; The running Racket, resolved to an absolute path. `exec-file` is how it was
;; invoked, which on a PATH launch is the bare name `subprocess` cannot exec.
(define racket-exe
  (let ([named (find-system-path 'exec-file)])
    (or (find-executable-path named)
        (error 'start-fake-tor "cannot locate the racket executable ~a" named))))

;; Start the fake daemon and return its two endpoints, the box its records
;; accumulate in, and a thunk that stops it.
(define (start-fake-tor)
  (define-values (proc pout pin perr)
    (subprocess #f #f (current-error-port)
                racket-exe "-y" (path->string fake-tor-path)))
  (close-output-port pin)
  (define seen (box '()))
  ;; Drains the daemon's stdout so a full pipe can never stall it. This thread is
  ;; stopped for the duration of every blocking onion call, which is why the records
  ;; it collects are only ever read between them.
  (thread (lambda ()
            (let loop ()
              (define line (read-line pout 'any))
              (unless (eof-object? line)
                (set-box! seen (cons line (unbox seen)))
                (loop)))))
  (values (await-record seen #rx"^control (.*)$")
          (await-record seen #rx"^socks (.*)$")
          seen
          (lambda () (subprocess-kill proc #t))))

;; The generic driver retains the package callback context after the onion
;; constructor reference is dropped by the transport-owned installer.
(let ()
  (define-values (control _socks seen stop!) (start-fake-tor))
  (define lp (open-driver-loop #:wire-buffer-bytes 1024 #:max-pending-opens 8))
  (dynamic-wind
   void
   (lambda ()
     (onion-install-provider! lp #:socks absent-socks #:control control)
     (expect (driver-loop-has-transport? lp "onion")
             "onion: the generic driver registered the provider package")
     (define listener (loop-listen! lp "onion" ""))
     (driver-loop-start! lp)
     (set! listener (loop-listener-ready! listener))
     (define loc (loop-listener-locator lp listener))
     (expect (string=? (locator-transport loc) "onion")
             "onion: the retained provider reports its transport")
     (expect (string=? (locator-designator loc) onion-service-id)
             "onion: the retained provider reports the service Tor named")
     (loop-listener-close! lp listener)
     (expect (equal? "AUTHENTICATE" (await-record seen #rx"^line (AUTHENTICATE.*)$"))
             "onion: provider-backed listen reached the configured daemon"))
   (lambda ()
     (driver-loop-abort! lp)
     (stop!))))

;; The high-level onion listener is only a provider package plus the generic
;; driver server. Its URI comes from the driver's canonical locator, while the
;; opaque restoration bytes become a Tor service key only in the onion module.
(let ()
  (define-values (control _socks _seen stop!) (start-fake-tor))
  (define server
    (listen-onion #:socks absent-socks #:control control))
  (expect (onion-server? server)
          "onion server: high-level listener has the transport-owned type")
  (expect (string=? (onion-server-service-id server) onion-service-id)
          "onion server: service id comes from the driver locator")
  (expect (string=? (onion-server-uri server)
                    (format-peer-uri "onion" onion-service-id))
          "onion server: URI is the driver's canonical locator")
  (expect (bytes=? (onion-server-service-key server) onion-service-key)
          "onion server: restoration state is interpreted as the Tor service key")
  (define parked-result (make-channel))
  (define parked-accept
    (thread
     (lambda ()
       (channel-put parked-result
                    (with-handlers ([exn? values])
                      (onion-server-accept server)
                      'accepted)))))
  (sleep 0.02)
  (onion-server-close! server)
  (expect (exn? (sync/timeout 2 parked-result))
          "onion server: close wakes a parked high-level accept")
  (thread-wait parked-accept)
  (stop!))

(printf "racket zig-smoke OK: high-level onion listening uses the generic driver server\n")

;; Closing a listener before its resident setup starts cancels the pending
;; native operation and settles the Racket event; it must not leave a waiter
;; parked forever or call the driver's close path a second time.
(let ()
  (define-values (control _socks _seen stop!) (start-fake-tor))
  (define lp (open-driver-loop))
  (dynamic-wind
   void
   (lambda ()
     (onion-install-provider! lp #:socks absent-socks #:control control)
     (define listener (loop-listen! lp "onion" ""))
     (loop-listener-close! lp listener)
     (expect (exn? (sync/timeout 1 listener))
             "onion: closing pending listener settles its setup event"))
   (lambda ()
     (driver-loop-abort! lp)
     (stop!))))

(printf "racket zig-smoke OK: pending listener close cancels and settles exactly once\n")

;; Supplying a Host keeps it caller-owned even though the listener adopts it
;; into a newly created native loop.
(let ()
  (define-values (control _socks _seen stop!) (start-fake-tor))
  (define host (make-fresh-host))
  (define server (listen-onion #:socks absent-socks #:control control #:host host))
  (expect (eq? host (onion-server-host server))
          "onion server: supplied Host wrapper is preserved")
  (onion-server-close! server)
  (expect (not (unbox (host-released? host)))
          "onion server: closing a supplied-Host listener does not release Host")
  (host-close! host)
  (stop!))

;; Drive one `listen` against the fake daemon and report the AUTHENTICATE line it
;; saw. Recording the credential is the point: every other assertion here uses an
;; unauthenticated endpoint, where a mapping that sent no credential at all would
;; look exactly like success.
(define (authenticate-line-for auth-kind secret)
  (define-values (control _socks seen stop!) (start-fake-tor))
  (define nl (make-onion-netlayer #:socks absent-socks
                                  #:control control
                                  #:auth-kind auth-kind
                                  #:auth-secret secret))
  (onion-listener-release! (onion-netlayer-listen nl))
  (onion-netlayer-release! nl)
  (begin0 (await-record seen #rx"^line (AUTHENTICATE.*)$")
          (stop!)))

;; Hosting reports the id the daemon named and the key that restores it, and the
;; readiness descriptor is the live accept socket rather than merely a number.
(let ()
  (define-values (control _socks seen stop!) (start-fake-tor))
  (define nl (make-onion-netlayer #:socks absent-socks #:control control))
  (define lst (onion-netlayer-listen nl))
  (expect (equal? onion-service-id (onion-listener-service-id lst))
          "onion: the listener published the service id the daemon named")
  (expect (equal? onion-service-key (onion-listener-service-key lst))
          "onion: the listener reported the key that restores the same address")
  (define fd (onion-listener-readiness-fd lst))
  (expect (>= fd 0) "onion: the listener handed back a readiness descriptor")
  ;; Nothing has dialed, so the wait expires rather than parking.
  (expect (not (onion-listener-wait lst 1))
          "onion: readiness reports not-ready before any circuit arrives")

  ;; Release owns cancellation as well as storage. A green thread parked before
  ;; native accept must wake and retire before the listener payload is freed.
  (define parked-result (make-channel))
  (define parked-listener (onion-netlayer-listen nl))
  (define parked-accept
    (thread
     (lambda ()
       (channel-put
        parked-result
        (with-handlers ([exn:fail? values])
          (onion-listener-accept parked-listener)
          'accepted)))))
  (sleep 0.02)
  (onion-listener-release! parked-listener)
  (expect (exn:fail? (sync/timeout 2 parked-result))
          "onion: listener release wakes a parked accept")
  (thread-wait parked-accept)

  ;; Ask the daemon what forward target the ADD_ONION named, then stand in for Tor
  ;; forwarding a circuit to it.
  (define forward-target (await-record seen #rx"^line ADD_ONION.*PORT=[0-9]+,(.*)$"))
  (define parts (regexp-match #rx"^(.*):([0-9]+)$" forward-target))
  (define-values (cin cout)
    (tcp-connect (cadr parts) (string->number (caddr parts))))
  ;; Now readiness reports arrival, so accept returns instead of parking.
  (expect (onion-listener-wait lst 2000)
          "onion: readiness reports the arriving circuit on the same descriptor")
  (define accepted (onion-listener-accept lst))
  (expect (>= (onion-connection-readiness-fd accepted) 0)
          "onion: the accepted connection has its own readiness descriptor")
  (onion-connection-release! accepted)
  (close-input-port cin)
  (close-output-port cout)
  ;; Releasing the owner retires children before its std.Io backend.
  (onion-netlayer-release! nl)
  (expect (with-handlers ([exn:fail? (lambda (_) #t)])
            (onion-listener-readiness-fd lst) #f)
          "onion: netlayer release closed its live listener first")
  (onion-listener-release! lst) ; idempotent after owner-driven release
  (stop!))

;; The dial half: a circuit carries a framed message. What reaches the wire is the
;; frame inside its netstring envelope, a Syrup byte string whose length prefix the
;; reader strips again.
(let ()
  (define-values (_control socks seen stop!) (start-fake-tor))
  (define nl (make-onion-netlayer #:socks socks))
  (define cn (onion-netlayer-connect nl onion-service-id))
  (onion-connection-write-frame! cn #"<8'op:abort3\"bye>")
  (expect (equal? "17:<8'op:abort3\"bye>" (await-record seen #rx"^wrote (.*)$"))
          "onion: a dial carried a framed message over the circuit")
  (onion-connection-release! cn)
  (onion-netlayer-release! nl)
  (stop!))

;; Each credential form reaches the daemon as itself.
(expect (equal? "AUTHENTICATE" (authenticate-line-for AUTH-NONE #f))
        "onion: an unauthenticated control endpoint gets the bare keyword")
(expect (equal? "AUTHENTICATE 00010fff"
                (authenticate-line-for AUTH-COOKIE (bytes 0 1 15 255)))
        "onion: a cookie travels as hexadecimal")
(expect (equal? "AUTHENTICATE \"hunter2\""
                (authenticate-line-for AUTH-PASSWORD "hunter2"))
        "onion: a password travels as a quoted string")

;; A dial-only netlayer can reach out and cannot host.
(let ()
  (define nl (make-onion-netlayer #:socks absent-socks))
  (expect (with-handlers ([exn:fail? (lambda (_) #t)])
            (onion-netlayer-listen nl) #f)
          "onion: a dial-only netlayer refuses to host")
  ;; A designator that is not a well-formed version 3 address is refused before any
  ;; socket opens, so this is an argument fault rather than a dial failure.
  (expect (with-handlers ([exn:fail? (lambda (_) #t)])
            (onion-netlayer-connect nl "not-an-onion-address") #f)
          "onion: a malformed designator is refused before dialing")
  (onion-netlayer-release! nl))

(for ([runtime (in-list (unbox extra-runtimes))])
  (runtime-close! runtime))

(printf "racket zig-smoke OK: the onion transport reached a fake Tor and reported its service\n")
