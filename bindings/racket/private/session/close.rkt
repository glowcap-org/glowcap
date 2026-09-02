#lang racket/base
;; Internal: terminal Session close request/wait/barrier lifecycle. The native
;; Host selects protocol effects; this leaf owns only Racket scheduling,
;; callback-unwind deferral, retained worker state, and terminal projection.

(require "../constants.rkt"
         "../ffi-host.rkt"
         "../errors.rkt"
         "../host.rkt"
         "../host/state.rkt"
         "../trampoline.rkt"
         "../pump.rkt"
         "../action.rkt"
         "../session.rkt"
         "state.rkt")

(provide (all-defined-out))

(define (begin-session-close/locked! c options)
  (define m (session-host c))
  (define lp (host-loop-of m))
  (if lp
      ((unbox loop-begin-session-close-hook) lp c options)
      (check/host
       (glowcap_host_session_close (session-ptr c) options (monotonic-ms))))
  (set-box! (session-closing-state c) #t))

;; Drive one byte-fed session's close to its release, event-driven like
;; `drive-host-close!`: snapshot the host progress event before the progress
;; check, drain what progress queued, then park on that snapshot or on the
;; nearest FINISH grace deadline. The host-level wait covers every session's
;; deadline, this one included; -1 parks on host activity alone.
(define (await-byte-fed-session-close! c)
  (define m (session-host c))
  (let loop ()
    (unless (session-released? c)
      (define gen (host-progress-evt m))
      (define wait-ms -1)
      (define fx
        (call-with-host
         m
         (lambda ()
           (cond
             ;; A sibling may have released this session while this thread was
             ;; parked on the lock; its handle must see no further host verb.
             [(session-released? c) no-drain-effects]
             [else
              (define-values (rc state)
                (glowcap_host_session_close_progress
                 (session-ptr c) (monotonic-ms)))
              (unless (or (= rc OK) (= rc ERR-TIMEOUT)) (check/host rc))
              ;; The loop's exit is the session's release (it rides an action
              ;; drained here), so the returned lifecycle state is not read.
              (void state)
              ;; Drain what progress queued (this session's release rides an
              ;; action) before parking; a productive drain bumps below.
              (define effects (drain-host-actions! m))
              (define-values (wrc w)
                (glowcap_host_close_wait_ms (host-ptr m) (monotonic-ms)))
              (check/host wrc)
              (set! wait-ms w)
              effects]))))
      (run-drain-effects! m fx)
      (when (drain-effects-productive? fx) (host-bump-progress! m))
      (unless (session-released? c)
        (if (>= wait-ms 0)
            (sync/timeout (/ wait-ms 1000.0) gen)
            (sync gen))
        (loop))))
  (raise-session-terminal-failure! c))

(define (await-session-close! c)
  (define lp (host-loop-of (session-host c)))
  (if lp
      ((unbox loop-await-session-close-hook) lp c)
      (await-byte-fed-session-close! c)))

(struct session-close-barrier (done result [worker #:mutable]) #:transparent)
(struct session-close-result-value (error) #:transparent)
(define session-close-active (make-hasheq))
(define session-close-pending (make-hasheq))

(define (publish-session-close! c barrier outcome)
  (define m (session-host c))
  (parameterize-break
   #f
   (set-box! (session-close-barrier-result barrier) outcome)
   (call-with-host/terminal
    m
    (lambda ()
      (when (eq? (hash-ref session-close-active c #f) barrier)
        (hash-remove! session-close-active c))))
   (semaphore-post (session-close-barrier-done barrier))))

(define (run-session-close-worker! c barrier)
  (define outcome
    (with-handlers ([(lambda (_) #t)
                     (lambda (error) (session-close-result-value error))])
      (await-session-close! c)
      (session-close-result-value #f)))
  (publish-session-close! c barrier outcome))

;; Install the retained close worker while the caller holds the Host lock.
;; Callback-unwind drains use this without joining: the worker itself needs the
;; lock to drive close progress after the enclosing feed releases it.
(define (start-session-close-worker!/locked c)
  (define barrier (session-close-barrier (make-semaphore 0) (box #f) #f))
  (hash-set! session-close-active c barrier)
  (with-handlers ([(lambda (_) #t)
                   (lambda (error)
                     (hash-remove! session-close-active c)
                     (raise error))])
    (set-session-close-barrier-worker!
     barrier
     (thread (lambda () (run-session-close-worker! c barrier)))))
  barrier)

;; Callback-time requests are already recorded in native state. This table is
;; only a one-shot scheduling marker for the executor that waits after unwind.
(define (drain-pending-session-close! c)
  (define m (session-host c))
  (call-with-host/terminal
   m
   (lambda ()
     (define pending? (hash-ref session-close-pending c #f))
     (hash-remove! session-close-pending c)
     (when (and pending?
                (not (session-released? c))
                (not (hash-ref session-close-active c #f)))
       (start-session-close-worker!/locked c)))))

(define (session-close/options! c options)
  (define m (session-host c))
  (define disposition
    (call-with-host/terminal
     m
     (lambda ()
       (parameterize-break
        #f
        (cond
          [(session-released? c) '(released)]
          [(hash-ref session-close-active c #f)
           => (lambda (barrier)
                (when (and options (not (session-released? c)))
                  (begin-session-close/locked! c options))
                (if (inside-turn?) '(deferred) (list 'wait barrier)))]
          [(inside-turn?)
           (begin-session-close/locked! c options)
           (define already-pending? (hash-ref session-close-pending c #f))
           (hash-set! session-close-pending c #t)
           (unless already-pending?
             (host-park-release! m (lambda () (drain-pending-session-close! c))))
           '(deferred)]
          [else
           (begin-session-close/locked! c options)
           (list 'wait (start-session-close-worker!/locked c))])))))
  ;; A close request issued outside a turn is close-relevant activity: a
  ;; driver already parked on host progress with no finite deadline must
  ;; re-check. A mid-turn request needs no bump here, because the enclosing
  ;; drain bumps when the turn unwinds; bumping earlier lets the turn's own
  ;; pump observe closure before the parked release executes.
  (when (eq? (car disposition) 'wait) (host-bump-progress! m))
  (case (car disposition)
    [(released deferred)
     (unless (eq? (car disposition) 'deferred)
       (raise-session-terminal-failure! c))]
    [(wait)
     (define barrier (cadr disposition))
     (sync (semaphore-peek-evt (session-close-barrier-done barrier)))
     (define result (unbox (session-close-barrier-result barrier)))
     (when (session-close-result-value-error result)
       (raise (session-close-result-value-error result)))
     (raise-session-terminal-failure! c)]))

;; Close this session and nothing else. Explicit close drives the shared
;; pending-work policy to its completion barrier. Inside a behavior turn native
;; intent is recorded immediately; only waiting and handle release are deferred
;; until the callback frame unwinds.
(define (session-close! c
                        #:pending [pending 'cancel]
                        #:grace-ms [grace-ms grace-unspecified])
  (define options (close-options 'session-close! pending grace-ms))
  (session-close/options! c options))
