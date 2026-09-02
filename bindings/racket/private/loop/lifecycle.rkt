#lang racket/base
;; Native loop and loop-owned Session close barriers plus Host hook installation.

(require ffi/unsafe/port
         racket/async-channel
         "../constants.rkt"
         "../ffi-driver.rkt"
         "../driver-failure.rkt"
         "../errors.rkt"
         (combine-in "../host.rkt" "../host/state.rkt")
         "../pump.rkt"
         (combine-in "../session.rkt" "../session/state.rkt")
         "core.rkt"
         "dial.rkt")

;; ── Release (the host.rkt hooks) ─────────────────────────────────────────────

;; Drive the native owner barrier while ordinary loop stepping and event
;; projection remain live. The driver/core decide every transition and
;; outcome; this binding supplies execution and observes completion.
(define (begin-loop-close! lp options)
  (check/driver (glowcap_driver_close (driver-loop-handle lp) options)))

;; The wait is event-driven, the same shape as the byte-fed
;; `drive-host-close!`: snapshot the host progress event before stepping,
;; step and drain, then park on that snapshot or on the nearest pending-work
;; deadline from `loop-step-wait-ms`. A wait of -1 means no finite deadline
;; is pending: only loop progress (a readiness-driven step, a verb's kicked
;; drain, an escalation) can advance the barrier, so the driver parks on the
;; progress event alone.
(define (drive-loop-close! lp)
  (define m (driver-loop-host lp))
  (let loop ()
    (define gen (host-progress-evt m))
    (define state #f)
    (define close-code OK)
    (define wait-ms -1)
    (define fx
      (call-with-host
       m
       (lambda ()
         (define effects (loop-drain! m lp))
         (define-values (rc lifecycle)
           (glowcap_driver_lifecycle_state (driver-loop-handle lp)))
         (unless (or (= rc OK) (= rc ERR-TIMEOUT)) (check/driver rc))
         (set! close-code rc)
         (set! state lifecycle)
         (unless (lifecycle-closed? lifecycle)
           (set! wait-ms (loop-step-wait-ms lp)))
         effects)))
    (run-drain-effects! m fx)
    (when (drain-effects-productive? fx) (host-bump-progress! m))
    (cond
      [(lifecycle-closed? state) close-code]
      [(>= wait-ms 0) (sync/timeout (/ wait-ms 1000.0) gen) (loop)]
      [else (sync gen) (loop)])))

;; Drive one loop-owned session through the same core policy while the loop
;; remains live. SESSION_CLOSED projection retires the Racket shell; this
;; function only supplies steps and observes the native result beforehand.
(define (begin-loop-session-close! lp c options)
  (check/driver
   (glowcap_driver_session_close
    (driver-loop-handle lp) (session-ptr c) options)))

(define (await-loop-session-close! lp c)
  (define m (driver-loop-host lp))
  (let loop ()
    (unless (session-released? c)
      ;; The progress snapshot precedes the step and the released check (the
      ;; pump-until idiom), so a rival path retiring this shell between the
      ;; check and the park still wakes this driver.
      (define gen (host-progress-evt m))
      (define wait-ms -1)
      (define fx
        (call-with-host
         m
         (lambda ()
           (define effects (loop-drain! m lp))
           ;; Draining parked releases may consume this exact Session before
           ;; the native lifecycle query. Its Racket terminal result was
           ;; published by that release path, so the consumed handle must not
           ;; be consulted again.
           (unless (session-released? c)
             (define-values (rc lifecycle)
               (glowcap_driver_session_lifecycle_state
                (driver-loop-handle lp) (session-ptr c)))
             (unless (or (= rc OK) (= rc ERR-TIMEOUT)) (check/driver rc))
             (when (lifecycle-closed? lifecycle)
               (set-box! (session-close-result c) rc))
             (unless (lifecycle-closed? lifecycle)
               (set! wait-ms (loop-step-wait-ms lp))))
           effects)))
      (run-drain-effects! m fx)
      (when (drain-effects-productive? fx) (host-bump-progress! m))
      (unless (session-released? c)
        (if (>= wait-ms 0)
            (sync/timeout (/ wait-ms 1000.0) gen)
            (sync gen))
        (loop))))
  (define result (unbox (session-close-result c)))
  (cond
    [(exn? result) (raise result)]
    [(not (= result OK)) (check/driver result)]))

;; The pre-teardown stop the Host release worker runs OUTSIDE the host lock after the
;; native barrier: end Racket-side stepping, join the park thread, and retire
;; listener wrappers whose native owners are already closed. The park thread
;; needs the host lock for its own drain, so joining it under the lock would
;; deadlock.
(define (loop-prestop! lp _orderly?)
  (define state (driver-loop-state lp))
  (define claimed?
    (let claim ()
      (case (unbox state)
      [(open) (if (box-cas! state 'open 'stopping) #t (claim))]
      [(retiring) (if (box-cas! state 'retiring 'stopping) #t (claim))]
      [(failed) (if (box-cas! state 'failed 'stopping) #t (claim))]
      [(stopping released) #f])))
  (when claimed?
    (semaphore-post (driver-loop-stop-sema lp))
    (define t (driver-loop-park-thread lp))
    (cond
      [(and t (eq? t (current-thread)))
       (when (driver-loop-fd lp)
         (unsafe-file-descriptor->semaphore (driver-loop-fd lp) 'remove))]
      [t (thread-wait t)]
      [else (void)])))

;; The native teardown the Host release worker runs in place of
;; `glowcap_host_release`, under the host lock, after the sessions closed:
;; release the loop (which frees the wrapped host), then the sidecar
;; endpoint it retained, in that order so no resident call runs against a
;; freed endpoint. The close procedure was captured at adoption, so this
;; path — reachable from the FFI finalizer thread — resolves no module.
(define (loop-native-release! lp)
  (cond
    [(not (loop-native-live? lp)) (values OK #f)]
    [else
     (define-values (code failure)
       (call/driver-failure
        'driver-release
        (lambda (out) (glowcap_driver_release (driver-loop-handle lp) out))))
     (when (release-consumed? code)
       (set-box! (driver-loop-state lp) 'released)
       (for ([listener (in-hash-values (driver-loop-listeners lp))])
         (cond
           [(box-cas! (loop-listener-state listener) 'pending 'closed) (void)]
           [(box-cas! (loop-listener-state listener) 'ready 'closed) (void)]
           [else (void)])
         (async-channel-put (loop-listener-accepts listener) accepts-terminal))
       (hash-clear! (driver-loop-listeners lp)))
     (values code failure)]))

;; A loop-owned host redeems handoffs inside its own steps (ADR-0112), so
;; the exporter session it dialed exists with no wrapper yet; wrap it lazily
;; — `build-session` registers it, so a repeat lookup answers this same
;; object.
(define (loop-wrap-session lp ptr) (wrap-loop-session lp ptr #f))

(set-box! loop-drain-hook loop-drain!)
(set-box! loop-begin-close-hook begin-loop-close!)
(set-box! loop-close-barrier-hook drive-loop-close!)
(set-box! loop-prestop-hook loop-prestop!)
(set-box! loop-native-release-hook loop-native-release!)
(set-box! loop-begin-session-close-hook begin-loop-session-close!)
(set-box! loop-await-session-close-hook await-loop-session-close!)
(set-box! loop-session-release-hook loop-session-release!)
(set-box! loop-claim-reference-exporter-hook loop-claim-reference-exporter)
(set-box! loop-wrap-session-hook loop-wrap-session)
