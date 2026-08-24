#lang racket/base
;; Internal: the Racket-owned state and terminal diagnostic journal for one
;; native CapTP Session. Pump, action, and public verbs consume this vocabulary;
;; this leaf owns no native protocol decisions.

(require "../constants.rkt"
         "../ffi-host.rkt"
         "../errors.rkt"
         "../async.rkt"
         "../pending-writes.rkt"
         "../host/state.rkt")

(provide (all-defined-out))

;; A session carries its pump state, vat, Host, native handle, bounded outbound
;; queue, and lifecycle barriers. Handoff redemption and routed sends remain
;; Host-owned; queue byte accounting lives in `pending-writes.rkt`.
(struct session
  (async vat host native pending-writes write-gate outbound-frame outbound-prefix
         release-pending? close-result
         closing-state wire-failure transport-lost? transport-close-started?))

(define (session-ptr c) (session-native c))
(define (session-closed? c) (unbox (async-connection-closed? (session-async c))))
(define (session-released? c) (unbox (async-connection-released? (session-async c))))
(define (session-closing? c) (unbox (session-closing-state c)))

;; The byte path can fail in a callerless action drain. Retain the exact first
;; exception on the Session so the operation that provoked it and both terminal
;; boundaries observe one cause instead of a generic closed wrapper.
(define (record-session-wire-failure! c error)
  (box-cas! (session-wire-failure c) #f error)
  (unbox (session-wire-failure c)))

(define (record-session-outbound-failure! c error)
  (unless (or (session-released? c)
              (unbox (session-transport-close-started? c))
              (unbox (session-transport-lost? c)))
    (record-session-wire-failure! c error)))

(define (raise-session-wire-failure! c)
  (define failure (unbox (session-wire-failure c)))
  (when failure (raise failure)))

;; Close the physical byte channel exactly once. A close refusal is terminal
;; evidence, but never skips native retirement or replaces an earlier cause.
(define (close-session-transport! c)
  (set-box! (session-closing-state c) #t)
  (when (box-cas! (session-transport-close-started? c) #f #t)
    (with-handlers ([(lambda (_) #t)
                     (lambda (error)
                       (record-session-wire-failure! c error)
                       (void))])
      ((async-transport-close! (async-connection-transport (session-async c)))))))

;; Retire a loop-backed shell after its loop can no longer project events.
;; Driver release owns the C allocation; this only completes Racket waiters.
(define (loop-owner-failed! c error)
  (define ac (session-async c))
  (set-box! (async-connection-closed? ac) #t)
  (set-box! (async-connection-released? ac) #t)
  (set-box! (session-release-pending? c) #f)
  (set-box! (session-closing-state c) #t)
  (set-box! (session-close-result c) error)
  (record-session-wire-failure! c error)
  (pending-writes-clear! (session-pending-writes c))
  (close-session-transport! c))

(define (guard-open who c)
  (when (or (session-closing? c) (session-released? c))
    (raise-session-wire-failure! c)
    (raise-pancake who ERR-CLOSED "connection closed")))

(define (guard-retained who c)
  (when (session-released? c)
    (raise-pancake who ERR-CLOSED "the session has been released")))

;; Nonzero once the keyed handshake has completed and the session is open.
(define (session-open? c)
  (call-with-host
   (session-host c)
   (lambda ()
     (and (not (session-released? c))
          (= 1 (pancake_host_session_is_open (session-ptr c)))))))
