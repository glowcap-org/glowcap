#lang racket/base
;; A listener accepts a session whose dialer refused the handshake. The driver
;; closes that session in C, and the close event can arrive before the accept
;; wraps the handle. The wrap must then retire the session itself, because no
;; event is left to do it: a close returns and a serve never hands the freed
;; handle to the driver. This module holds the accept until the driver has
;; closed the session, which listeners.rkt cannot arrange.

(require "../../glowcap.rkt"
         "../../glowcap-tcp.rkt"
         (combine-in "../../private/session.rkt"
                     "../../private/session/state.rkt"
                     "../../private/session/close.rkt")
         (combine-in "../../private/host.rkt" "../../private/host/state.rkt")
         "../../private/locator.rkt"
         "../../private/errors.rkt"
         "../../private/constants.rkt"
         "../../private/pump.rkt"
         (only-in "../../private/loop/stepper.rkt" driver-loop-closed-ptrs)
         "support.rkt"
         racket/tcp)

;; Run `thunk` on its own thread and answer its outcome: 'returned, or the
;; exception it raised so a failure reports itself. The answer is #f when
;; nothing came back within `seconds`, so a close that waits for an event
;; already consumed fails an expectation instead of hanging the suite.
(define (bounded seconds thunk)
  (define done (make-channel))
  (thread (lambda ()
            (channel-put done (with-handlers ([exn? values])
                                (thunk)
                                'returned))))
  (sync/timeout seconds done))

(define (outcome-text outcome)
  (if (exn? outcome) (exn-message outcome) outcome))

(let ()
  (define honest (listen-keyed-tcp "127.0.0.1" 0 #:seed (make-bytes 32 #x72)))
  (define designator (locator-designator (server-locator honest)))
  (server-close! honest)
  (define squatter (listen-keyed-tcp "127.0.0.1" 0 #:seed (make-bytes 32 #x73)))
  (define m (server-host squatter))
  (define closed-ptrs (driver-loop-closed-ptrs (host-loop-of m)))
  ;; The acceptor does not take the session until the driver has closed it.
  (define accept-gate (make-semaphore 0))
  (define accepted (make-channel))
  (define acceptor
    (thread (lambda () (sync accept-gate) (channel-put accepted (accept squatter)))))
  (define refusal
    (with-handlers ([exn:fail:glowcap? values])
      (open-test-session (keyed-tcp-locator designator "127.0.0.1" (server-port squatter)))
      'connected))
  (expect (exn:fail:glowcap? refusal) "close before wrap: a dial to the wrong key was accepted")
  ;; Wait on host progress, which the driver's close event bumps, until the
  ;; remembered terminal event exists. That is the ordering under test.
  (let wait ([tries 0])
    (define progress (host-progress-evt m))
    (when (and (zero? (hash-count closed-ptrs)) (< tries 100))
      (sync/timeout 0.1 progress)
      (wait (add1 tries))))
  (expect (positive? (hash-count closed-ptrs))
          "close before wrap: the driver never closed the refused session before it was wrapped")
  ;; The driver remembers how the session ended. The end is clean when the
  ;; dialer's hello was read alone, and a truncated frame when its first
  ;; requests were read with it, because a session nobody attends dispatches
  ;; nothing and they still wait at the close. Which read happens is the
  ;; kernel's timing, and the wrap retires the session either way.
  (expect (andmap (lambda (terminal) (or (eq? terminal #t) (exn:fail:glowcap? terminal)))
                  (hash-values closed-ptrs))
          (format "close before wrap: the remembered terminal was ~s, neither #t nor a session failure"
                  (hash-values closed-ptrs)))
  (define failed? (ormap exn? (hash-values closed-ptrs)))
  ;; A close or serve of the retired session returns after a clean end and
  ;; raises the session's own failure after a failed one. Neither waits.
  (define (settled? outcome)
    (if failed? (exn:fail:glowcap? outcome) (eq? outcome 'returned)))
  (semaphore-post accept-gate)
  (define c (sync/timeout 10 accepted))
  (expect c "close before wrap: the squatter never accepted the refused dial")
  (expect (zero? (hash-count closed-ptrs))
          "close before wrap: wrapping left the remembered close event behind")
  (expect (session-released? c)
          "close before wrap: wrapping a session the driver had closed kept its handle")
  (define closed (bounded 10 (lambda () (session-close! c))))
  (expect (settled? closed)
          (format "close before wrap: session-close! did not report the session's end: ~a"
                  (outcome-text closed)))
  (define served (bounded 10 (lambda () (session-serve c))))
  (expect (settled? served)
          (format "close before wrap: session-serve did not report the session's end: ~a"
                  (outcome-text served)))
  (expect (not (session-partner-abort c))
          "close before wrap: the dialer refused before sending an abort")
  (thread-wait acceptor)
  (server-close! squatter))
(printf "racket test OK: a session the driver closed before it was wrapped is released at the wrap\n")
