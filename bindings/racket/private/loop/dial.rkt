#lang racket/base
;; Dial admission and loop-backed Session construction.

(require ffi/unsafe/port
         "../constants.rkt"
         "../ffi-driver.rkt"
         "../driver-failure.rkt"
         "../errors.rkt"
         "../locator.rkt"
         "../async.rkt"
         "../pump.rkt"
         "../action.rkt"
         (combine-in "../host.rkt" "../host/state.rkt")
         (combine-in "../session.rkt" "../session/state.rkt")
         "../transport.rkt"
         "core.rkt")

(provide loop-connect-session
         wrap-loop-session)

;; ── Dial ─────────────────────────────────────────────────────────────────────

;; Begin a nonblocking dial, kick a step so the handshake starts advancing, and park for
;; the outcome. The loop's handshake budget bounds the whole dial natively,
;; and both the park thread and the co-stepping waiter below arm exactly the
;; deadline returned by `glowcap_driver_step_wait_ms`. The driver's event
;; result is the authoritative failure category; its message remains
;; diagnostic detail.
(define (loop-dial! lp locator-uri [options #f])
  (define m (driver-loop-host lp))
  (define w (loop-dial-waiter (make-semaphore 0) (box #f)))
  (define c-options (operation-options->c 'runtime-connect options))
  (with-host-drain m
    (lambda ()
      (define-values (rc operation-id)
        (call-with-locator-view
         locator-uri
         (lambda (view)
           (glowcap_driver_dial (driver-loop-handle lp) view c-options))))
      (check/driver rc)
      (hash-set! (driver-loop-dials lp) operation-id w)
      (drain-host-actions! m)))
  ;; The park thread may be in an unbounded fd park from before this dial
  ;; existed; the loop's one cross-thread verb makes the fd readable so it
  ;; rebuilds its wait from the newly installed native deadline.
  (check/driver (glowcap_driver_wake (driver-loop-handle lp)))
  ;; Co-stepping park: a listener fire may run this dial on the park thread
  ;; itself, and then nobody else would step the handshake forward. Wait on
  ;; the loop descriptor and glowcap's nearest deadline beside the result;
  ;; either wake runs the ordinary drain without a fixed polling cadence.
  (define fd-sema
    (unsafe-file-descriptor->semaphore (driver-loop-fd lp) 'read))
  (unless fd-sema
    (error 'connect "the loop readiness fd cannot be registered for polling"))
  (let wait ()
    (define result-sema (loop-dial-waiter-sema w))
    (define wait-ms (loop-step-wait-ms lp))
    (define woke
      (if (negative? wait-ms)
          (sync result-sema fd-sema)
          (sync/timeout (/ wait-ms 1000.0) result-sema fd-sema)))
    (unless (eq? woke result-sema)
      (drain-host! m)
      (wait)))
  (define r (unbox (loop-dial-waiter-result w)))
  (case (car r)
    [(ok) (cdr r)]
    [(fail)
     (raise (driver-failure-exn 'connect (cadr r) #f))]
    [(error) (raise (cdr r))]
    [else (raise-glowcap 'connect ERR-CLOSED "the loop closed before the dial settled")]))

;; The loop-backed session transport: the native loop owns the wire, so
;; there is nothing to write, flush, read, or close here. A read parks on
;; the wake event and reports progress; teardown runs through
;; `abandon-session!`, whose release routes through the loop.
(define (loop-transport)
  (async-transport
   (lambda (_frame) (void))
   void
   (lambda (wake-evt) (sync wake-evt) 'woke)
   void))

;; Wrap a loop-minted session handle as the public `session` over the
;; adopted wrapper host: every session verb, vow, and trampoline works on it,
;; with the native loop as the transport and the drain. The handshake
;; already ran inside the loop's steps, so the session arrives open and the
;; byte pump's tail-resume never applies.
(define (wrap-loop-session lp ptr time-travel?)
  (define m (driver-loop-host lp))
  (call-with-host m
    (lambda ()
      (define c (build-session m ptr (loop-transport) time-travel?))
      (set-box! (async-connection-tail-resumed? (session-async c)) #t)
      ;; Post-open setup happens between accept (or dial) and serve; the hook
      ;; is how serve tells the loop to start delivering this session's
      ;; inbound (early bytes replay in order). Idempotent on the native side.
      (set-box! (async-connection-serve-hook (session-async c))
                (lambda ()
                  ;; Serving releases frames parked behind the handshake and
                  ;; may invoke a hosted behavior before returning.
                  (parameterize ([current-deliver-owner m])
                    (check/driver (glowcap_driver_session_serve
                                   (driver-loop-handle lp) ptr)))))
      (define terminal (hash-ref (driver-loop-closed-ptrs lp) (session-key ptr) #f))
      (when terminal
        (hash-remove! (driver-loop-closed-ptrs lp) (session-key ptr))
        (when (exn? terminal) (set-box! (session-close-result c) terminal))
        (set-box! (async-connection-closed? (session-async c)) #t))
      c)))

;; Dial through the loop and wrap the opened session.
(define (loop-connect-session lp locator-uri [options #f])
  (wrap-loop-session lp (loop-dial! lp locator-uri options) #f))
