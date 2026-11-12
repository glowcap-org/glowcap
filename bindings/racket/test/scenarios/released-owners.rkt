#lang racket/base
;; A handle whose owner was freed refuses with ERR-CLOSED instead of reaching
;; freed driver or Host memory, and a listener close refuses the one call shape
;; that would wait on itself.

(require "../../glowcap.rkt"
         "../../glowcap-tcp.rkt"
         (only-in "../../private/host/state.rkt" call-with-host)
         (only-in "../../private/tcp-provider.rkt" driver-loop-add-tcp!)
         (only-in "../../private/loop.rkt"
                  open-driver-loop driver-loop-start! driver-loop-host
                  loop-background-failed! driver-loop-has-transport?
                  loop-listen! loop-listener-ready! loop-listener-locator
                  loop-listener-restoration-state loop-listener-advertise!
                  loop-listener-select! loop-listener-close!)
         (only-in "../../private/loop/stepper.rkt" loop-listener)
         racket/async-channel
         "../../private/constants.rkt"
         "../../private/errors.rkt"
         "support.rkt")

(define (refusal-code thunk)
  (with-handlers ([exn:fail:glowcap? exn:fail:glowcap-code])
    (thunk)
    'returned))

(define (open-tcp-loop-listener)
  (define lp (open-driver-loop))
  (driver-loop-add-tcp! lp (make-tcp-config #:profiles (list TCP-PROFILE-TCP)))
  (define listener (loop-listen! lp TRANSPORT-TCP "127.0.0.1:0"))
  (driver-loop-start! lp)
  (values lp (loop-listener-ready! listener)))

;; A background failure settles only pending listeners, so a ready one keeps
;; its id after the release worker frees the loop. Every listener verb then
;; refuses before reaching the driver.
(let-values ([(lp listener) (open-tcp-loop-listener)])
  (define injected (exn:fail "injected loop failure" (current-continuation-marks)))
  (loop-background-failed! lp injected)
  (define observed
    (with-handlers ([exn:fail? values])
      (host-close! (driver-loop-host lp))
      #f))
  (expect (eq? observed injected) "released loop: Host close reports the injected failure")
  (for ([verb (in-list
               (list (cons "locator" (lambda () (loop-listener-locator lp listener)))
                     (cons "restoration state"
                           (lambda () (loop-listener-restoration-state lp listener)))
                     (cons "advertise"
                           (lambda ()
                             (loop-listener-advertise!
                              lp listener (format-peer-uri TRANSPORT-TCP "127.0.0.1:1"))))
                     (cons "select" (lambda () (loop-listener-select! lp listener)))
                     (cons "listen" (lambda () (loop-listen! lp TRANSPORT-TCP "127.0.0.1:0")))
                     (cons "has-transport"
                           (lambda () (driver-loop-has-transport? lp TRANSPORT-TCP)))))])
    (define code (refusal-code (cdr verb)))
    (expect (equal? code ERR-CLOSED)
            (format "released loop: ~a answered ~s instead of ERR-CLOSED" (car verb) code)))
  (expect (eq? 'returned (refusal-code (lambda () (loop-listener-close! lp listener))))
          "released loop: closing the listener of a released loop is a quiet no-op"))
(printf "racket test OK: listener verbs on a released driver loop refuse with ERR-CLOSED\n")

;; A released session's handle is gone even while its Host lives. A verb with
;; no guard of its own still refuses, because the handle accessor checks.
(let ()
  (define server (listen "127.0.0.1" 0))
  (define c (open-test-session (tcp-locator "127.0.0.1" (server-port server))))
  (session-close! c)
  (define code (refusal-code (lambda () (session-published-ref c "anything"))))
  (expect (equal? code ERR-CLOSED)
          (format "released session: published-ref answered ~s instead of ERR-CLOSED" code))
  (server-close! server))
(printf "racket test OK: a released session's verbs refuse with ERR-CLOSED\n")

;; A listener close may step the loop, so a thread holding the Host lock is
;; refused before anything is claimed, and the same listener closes normally
;; once the lock is free.
(let-values ([(lp listener) (open-tcp-loop-listener)])
  (define bound (loop-listener-locator lp listener))
  (define code
    (refusal-code
     (lambda ()
       (call-with-host (driver-loop-host lp)
                       (lambda () (loop-listener-close! lp listener))))))
  (expect (equal? code ERR-INVALID-ARGUMENT)
          (format "listener close under the Host lock answered ~s" code))
  (define kept (loop-listener-locator lp listener))
  (expect (equal? kept bound)
          (format "a refused listener close changed the listener's locator from ~s to ~s" bound kept))
  (loop-listener-close! lp listener)
  (define closed
    (with-handlers ([exn:fail:glowcap? (lambda (e) (cons (exn:fail:glowcap-code e) (exn-message e)))])
      (loop-listener-locator lp listener)
      (cons 'returned "")))
  (expect (and (equal? (car closed) ERR-CLOSED)
               (regexp-match? #rx"listener is closed" (cdr closed)))
          (format "a listener closed once the lock was free answered ~s for its locator" closed))
  (host-close! (driver-loop-host lp)))
(printf "racket test OK: a listener close refuses the thread holding its Host lock\n")

;; A listener verb answers for the state its listener is in. Only a ready
;; listener reaches the driver, so each refusal here needs no loop.
(for ([row (list (list 'pending #f ERR-INVALID-ARGUMENT)
                 (list 'closing #f ERR-INVALID-ARGUMENT)
                 (list 'closed #f ERR-CLOSED)
                 (list 'failed (make-glowcap-error ERR-TIMEOUT "listen: bind timed out") ERR-TIMEOUT))])
  (define-values (state outcome expected) (apply values row))
  (define listener
    (loop-listener #f 1 (make-semaphore 0) (box outcome) (box state) (make-async-channel)))
  (define code (refusal-code (lambda () (loop-listener-locator #f listener))))
  (expect (equal? code expected)
          (format "a ~a listener answered ~s for its locator instead of ~s" state code expected)))
(printf "racket test OK: a listener verb refuses by its listener's state\n")
