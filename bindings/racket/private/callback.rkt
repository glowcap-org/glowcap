#lang racket/base
;; The boundary every C callback crosses. Racket leaves an escape from a
;; foreign callback undefined, so neither a raise nor a break may unwind
;; through the C frame. An FFI call that can run callbacks goes through
;; `call-latching-callbacks`, which keeps breaks disabled while C runs (a
;; pending break arrives after C returns) and hands back the first value a
;; callback raised. Each callback body runs under `run-c-callback`, which
;; latches that value and returns a refusal code to C.

(require "finalizer-diagnostics.rkt")

(provide call-latching-callbacks run-c-callback)

;; The latch box of the innermost FFI call that can run callbacks, or #f.
(define current-callback-latch (make-parameter #f))

;; Run `ffi-call` and return the first raised callback value (or #f) followed
;; by the call's own results. The caller reports the latched value: it is the
;; exact failure, and C has already seen only the refusal code.
(define (call-latching-callbacks ffi-call)
  (define latch (box #f))
  (call-with-values
   (lambda ()
     (parameterize-break #f
       (parameterize ([current-callback-latch latch])
         (ffi-call))))
   (lambda results (apply values (unbox latch) results))))

;; Run one callback body and return its code. Every raised value is caught,
;; because nothing may cross the C frame: the first one is latched for the
;; enclosing FFI call. A later one, and any raised with no enclosing call,
;; becomes a callerless runtime failure under `operation`.
;; Breaks are disabled so a break cannot be caught here as a failure.
(define (run-c-callback operation refused-code body)
  (parameterize-break #f
    (with-handlers ([(lambda (_) #t)
                     (lambda (raised)
                       (define latch (current-callback-latch))
                       (cond
                         [(not latch) (record-runtime-failure! 'binding operation raised)]
                         [(not (unbox latch)) (set-box! latch raised)]
                         [else (record-runtime-failure! 'binding operation raised)])
                       refused-code)])
      (body))))

(module+ test
  (require rackunit)
  ;; One FFI call can run two callbacks. The call reports the first raise,
  ;; and the second is kept in the runtime failure journal.
  (void (take-runtime-failures!))
  (define first-raise (exn:fail "first" (current-continuation-marks)))
  (define-values (latched codes)
    (call-latching-callbacks
     (lambda ()
       (list (run-c-callback "callback.first" -1 (lambda () (raise first-raise)))
             (run-c-callback "callback.second" -2 (lambda () (error "second")))))))
  (check-eq? latched first-raise)
  (check-equal? codes '(-1 -2))
  (define kept (take-runtime-failures!))
  (check-equal? (map failure-event-operation kept) '("callback.second"))
  (check-equal? (map failure-event-primary-message kept) '("second")))
