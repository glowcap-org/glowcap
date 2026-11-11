#lang racket/base
;; Internal: the Racket-owned state and terminal diagnostic journal for one
;; FFI CapTP Session. Pump, action, and public verbs consume this vocabulary;
;; this leaf owns no FFI protocol decisions.

(require "../constants.rkt"
         "../ffi-host.rkt"
         (only-in "../ffi-shared.rkt" out-immobile bytes<-c)
         (only-in "../value.rkt" partner-abort)
         "../errors.rkt"
         "../async.rkt"
         "../pending-writes.rkt"
         "../host/state.rkt"
         "outbound.rkt")

(provide (all-defined-out))

;; A session carries its pump state, vat, Host, FFI handle, bounded outbound
;; queue, the writer that alone writes it, and lifecycle barriers. Handoff
;; redemption and routed sends remain Host-owned; queue byte accounting lives
;; in `pending-writes.rkt`.
(struct session
  (async vat host ffi pending-writes outbound outbound-frame outbound-prefix
         release-pending? close-result
         closing-state wire-failure transport-lost? transport-close-started?
         retained-partner-abort))

(define (session-ptr c) (session-ffi c))
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
;; evidence, but never skips FFI retirement or replaces an earlier cause. status-allow: event or source ordering
(define (close-session-transport! c)
  (set-box! (session-closing-state c) #t)
  (outbound-stop! (session-outbound c))
  (when (box-cas! (session-transport-close-started? c) #f #t)
    (with-handlers ([(lambda (_) #t)
                     (lambda (error)
                       (record-session-wire-failure! c error)
                       (void))])
      ((async-transport-close! (async-connection-transport (session-async c)))))))

;; Retire a loop-backed shell after its loop can no longer project events. status-allow: lifecycle transition
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
  (close-session-transport! c)
  (host-bump-progress! (session-host c)))

;; Read the partner's retained op:abort from a live session handle, or #f when
;; none arrived. The first call reads the message length, and the second copies
;; exactly that many bytes.
(define (read-partner-abort ptr)
  (define-values (rc kind-ptr kind-len message-len)
    (glowcap_host_session_partner_abort ptr #f 0))
  (cond
    [(= rc WOULD-BLOCK) #f]
    [else
     (check/host rc)
     (define out (out-immobile message-len))
     (define-values (copy-rc _kind _kind-len _len)
       (glowcap_host_session_partner_abort ptr out message-len))
     (check/host copy-rc)
     (partner-abort (bytes->string/utf-8 (bytes<-c kind-ptr kind-len) #\uFFFD)
                    (bytes->string/utf-8 (bytes<-c out message-len) #\uFFFD))]))

;; Keep the partner abort before an owner release frees the handle that holds
;; it. The caller holds the host lock. A failed read is recorded on the session
;; and never blocks the release.
(define (retain-partner-abort! c)
  (unless (session-released? c)
    (with-handlers ([exn? (lambda (error) (record-session-wire-failure! c error))])
      (set-box! (session-retained-partner-abort c) (read-partner-abort (session-ptr c))))))

;; The partner's op:abort kind and diagnostic as a `partner-abort`, or #f when
;; the partner sent none. It stays readable after the session or Host releases.
(define (session-partner-abort c)
  (define retained (session-retained-partner-abort c))
  (call-with-host*
   (session-host c)
   (lambda () (unbox retained))
   (lambda ()
     (if (session-released? c)
         (unbox retained)
         (read-partner-abort (session-ptr c))))))

(define (guard-open who c)
  (when (or (session-closing? c) (session-released? c))
    (raise-session-wire-failure! c)
    (raise-glowcap who ERR-CLOSED "connection closed")))

(define (guard-retained who c)
  (when (session-released? c)
    (raise-glowcap who ERR-CLOSED "the session has been released")))

;; Nonzero once the keyed handshake has completed and the session is open.
(define (session-open? c)
  (call-with-host
   (session-host c)
   (lambda ()
     (and (not (session-released? c))
          (= 1 (glowcap_host_session_is_open (session-ptr c)))))))
