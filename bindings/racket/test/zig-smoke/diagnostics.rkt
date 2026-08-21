#lang racket/base
;; One independently loadable family from the Racket binding dogfood.

(require net/base64
         (only-in ffi/unsafe ctype-sizeof)
         racket/random
         racket/runtime-path
         "../../pancake.rkt"
         "../../pancake-tcp.rkt"
         "../../pancake-inproc.rkt"
         "../../pancake-onion.rkt"
         "../../pancake-iroh.rkt"
         (combine-in "../../private/session.rkt"
                     "../../private/session/state.rkt"
                     "../../private/session/establish.rkt"
                     "../../private/session/close.rkt")
         (combine-in "../../private/host.rkt" "../../private/host/state.rkt")
         (only-in "../../private/iroh.rkt" iroh-endpoint-record-failure!)
         "../../private/locator.rkt"
         "../../private/async.rkt"
         "../../private/byte-channel.rkt"
         (only-in "../../private/finalizer-diagnostics.rkt"
                  record-runtime-failure! run-native-finalizer!)
         (only-in "../../private/ws-transport.rkt" ws-transport)
         (only-in "../../relay.rkt" relay-pump exn:fail:relay?
                  exn:fail:relay-primary exn:fail:relay-secondary)
         "../../private/pump.rkt"
         "../../private/action.rkt"
         (only-in "../../private/dial.rkt" retain-host-cleanup-failure!)
         "../../private/promise.rkt"
         "../../private/gc.rkt"
         "../../private/vat.rkt"
         "../../private/ffi-host.rkt"
         "../../private/ffi-ocapn.rkt"
         "../../private/ffi-shared.rkt"
         "../../private/errors.rkt"
         "../../private/constants.rkt"
         "../../private/abi-value.rkt"
         (only-in "../../private/loop.rkt"
                  open-driver-loop driver-loop-start! driver-loop-abort!
                  loop-background-failed!
                  driver-loop-has-transport?
                  loop-listen! loop-listener-ready! loop-listener-locator
                  loop-listener-close!)
         "../../private/native-parent.rkt"
         (only-in "../../private/value.rkt" make-ref/internal)
         "support.rkt"
         racket/tcp)

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

;; The literal structured failure vector exercised by Zig, C, Rust,
;; TypeScript, and Python. This crosses the native Context seam; Racket owns
;; only the pins and the projection into its immutable failure-event value.
(define matrix-host (make-host (make-bytes 32 9)))
(define matrix-operation #"listener.close")
(define matrix-primary-name #"CloseFailed")
(define matrix-primary-message #"socket refused shutdown")
(define matrix-secondary-name #"ReleaseFailed")
(define matrix-secondary-message #"descriptor remained live")
(define matrix-report
  (make-PancakeFailureReport
   1 (ctype-sizeof _PancakeFailureReport)
   FAILURE-LAYER-TRANSPORT FAILURE-SCOPE-LISTENER
   31 47 ERR-IO ERR-INTERNAL 2
   (pin-immobile matrix-operation) (bytes-length matrix-operation)
   (pin-immobile matrix-primary-name) (bytes-length matrix-primary-name)
   (pin-immobile matrix-primary-message) (bytes-length matrix-primary-message)
   (pin-immobile matrix-secondary-name) (bytes-length matrix-secondary-name)
   (pin-immobile matrix-secondary-message) (bytes-length matrix-secondary-message)))
(call-with-host
 matrix-host
 (lambda ()
   (check (pancake_context_report_failure (host-context matrix-host) matrix-report))))
(define matrix-failures (host-take-failures! matrix-host))
(define matrix-failure (and (= (length matrix-failures) 1) (car matrix-failures)))
(expect (and matrix-failure
             (= (failure-event-sequence matrix-failure) 1)
             (= (failure-event-dropped-before matrix-failure) 0)
             (eq? (failure-event-layer matrix-failure) 'transport)
             (eq? (failure-event-scope matrix-failure) 'listener)
             (= (failure-event-scope-id matrix-failure) 31)
             (= (failure-event-operation-id matrix-failure) 47)
             (= (failure-event-primary-result matrix-failure) ERR-IO)
             (= (failure-event-secondary-result matrix-failure) ERR-INTERNAL)
             (= (failure-event-secondary-count matrix-failure) 2)
             (equal? (failure-event-operation matrix-failure) "listener.close")
             (equal? (failure-event-primary-name matrix-failure) "CloseFailed")
             (equal? (failure-event-primary-message matrix-failure)
                     "socket refused shutdown")
             (equal? (failure-event-secondary-name matrix-failure) "ReleaseFailed")
             (equal? (failure-event-secondary-message matrix-failure)
                     "descriptor remained live")
             (null? (host-take-failures! matrix-host)))
        "Context preserves the cross-language native failure vector exactly once")
(host-close! matrix-host)
(printf "racket zig-smoke OK: Context preserves the cross-language native failure vector exactly once\n")

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

;; Establishment keeps its operation failure primary and attaches a failed
;; transport rollback to it; Host teardown must not observe a duplicate.
(define establish-cleanup-host (make-fresh-host))
(define establish-primary-failure
  (exn:fail:pancake "session establishment failed" (current-continuation-marks) ERR-IO #f #f #f #f 0))
(define establish-close-failure
  (exn:fail:pancake "failed establishment transport close failed" (current-continuation-marks) ERR-INTERNAL #f #f #f #f 0))
(define failed-establish-transport
  (async-transport void void (lambda (_wake) eof) (lambda () (raise establish-close-failure))))
(define observed-establish-primary
  (with-handlers ([exn:fail? values])
    (establish-closing-transport establish-cleanup-host failed-establish-transport
                                 (lambda () (raise establish-primary-failure)))
    #f))
(expect (and (exn:fail:pancake? observed-establish-primary)
             (equal? (exn-message observed-establish-primary) (exn-message establish-primary-failure))
             (= (exn:fail:pancake-secondary-code observed-establish-primary) ERR-INTERNAL)
             (= (exn:fail:pancake-secondary-count observed-establish-primary) 1))
        "establishment preserves its primary and attaches rollback failure")
(define observed-establish-close-failure
  (with-handlers ([exn:fail? values]) (host-close! establish-cleanup-host) #f))
(expect (not observed-establish-close-failure)
        "Host close does not duplicate failed-establishment cleanup failure")

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
                 DEFAULT-FAILURE-PAYLOAD-CAP))
        "runtime failure payloads share the native bounded schema")
(run-native-finalizer!
 (make-string 600 #\☃)
 (lambda () (raise (exn:fail "unretained" (current-continuation-marks)))))
(define unicode-runtime-failure (car (take-runtime-failures!)))
(expect (and (<= (bytes-length
                  (string->bytes/utf-8
                   (failure-event-operation unicode-runtime-failure)))
                 DEFAULT-FAILURE-PAYLOAD-CAP)
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
                    ERR-IO #f #f ERR-INTERNAL "PancakeError" 2))
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

(define relay-text-failure
  (with-handlers ([exn:fail:relay? values])
    (relay-pump
     'fake-relay-websocket
     (byte-channel
      (lambda () (semaphore-wait (make-semaphore 0)) eof)
      (lambda (_bytes) (void))
      void
      #f)
     #:ws-recv (lambda (_connection #:payload-type _payload-type)
                 "not protocol bytes")
     #:ws-send (lambda (_connection _bytes #:payload-type _payload-type) (void))
     #:ws-close (lambda (_connection) (void)))
    #f))
(expect (regexp-match? #rx"WebSocket sent text to the byte relay"
                       (exn-message (exn:fail:relay-primary relay-text-failure)))
        "relay refuses text WebSocket messages instead of reinterpreting them")

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
