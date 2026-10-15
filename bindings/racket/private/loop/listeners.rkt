#lang racket/base
;; Listener admission, accepted-session ownership, and loop-server lifetime.

(require ffi/unsafe
         racket/async-channel
         "../constants.rkt"
         "../ffi-driver.rkt"
         "../driver-failure.rkt"
         "../errors.rkt"
         "../locator.rkt"
         (only-in "../vat.rkt" converts-to-broken?)
         (combine-in "../host.rkt" "../host/state.rkt")
         "../pump.rkt"
         (combine-in "../session.rkt" "../session/state.rkt")
         "core.rkt"
         "dial.rkt")

(provide loop-listen!
         loop-listener-ready!
         loop-listener-locator
         loop-listener-restoration-state
         loop-listener-advertise!
         loop-listener-select!
         loop-listener-close!
         make-loop-server
         loop-server?
         loop-server-time-travel?
         loop-server-locator
         loop-server-advertise!
         loop-server-accept
         loop-server-close!
         loop-server-host)

(define (loop-listener-ready! listener)
  (define outcome (sync listener))
  (cond
    [(eq? outcome listener) listener]
    [(exn? outcome) (raise outcome)]
    [else
     (raise-glowcap 'glowcap-loop ERR-INTERNAL
                    "listener setup event produced an invalid outcome")]))

(define (require-listener-ready listener)
  (unless (eq? (unbox (loop-listener-state listener)) 'ready)
    (raise-glowcap 'glowcap-loop ERR-INVALID-ARGUMENT
                   "listener setup has not settled"))
  listener)

;; Bind one of the loop's per-transport listeners. The kernel's designator (the bound
;; host:port, an ephemeral port resolved) reads back through the canonical
;; locator. Listen policy (wildcard refusal, the
;; advertised address) stays with the public `listen` in `listen.rkt`.
(define (loop-listen! lp transport designator [options #f])
  (define tb (string->bytes/utf-8 transport))
  (define db (string->bytes/utf-8 designator))
  (define c-options (operation-options->c 'listen options))
  (define-values (rc listener-id)
    (glowcap_driver_listen (driver-loop-handle lp)
                           (pin-immobile tb) (bytes-length tb)
                           (pin-immobile db) (bytes-length db)
                           c-options))
  (check/driver rc)
  (define listener
    (loop-listener lp listener-id (make-semaphore 0) (box #f) (box 'pending)
                   (make-async-channel)))
  (hash-set! (driver-loop-listeners lp) listener-id listener)
  ;; A listener added after the resident park is armed may begin in a pending
  ;; transport state. Wake that park so LISTENER_READY/FAILED can be observed;
  ;; the initial listener is started by `driver-loop-start!` below its caller.
  (when (driver-loop-fd lp)
    (check/driver (glowcap_driver_wake (driver-loop-handle lp))))
  listener)

(define (loop-listener-locator lp listener)
  (require-listener-ready listener)
  (define view (make-GlowcapLocatorView 0 0 #f 0 #f 0 #f 0 0))
  (define rc
    (glowcap_driver_listener_locator (driver-loop-handle lp)
                                     (loop-listener-id listener) view))
  (check/driver rc)
  (clone-locator-view view))

;; Copy opaque provider state through the driver's size-query ABI. The loop
;; owns only the mechanics: callers decide what the returned bytes mean.
(define (loop-listener-restoration-state lp listener)
  (require-listener-ready listener)
  (define (query cap)
    (define out (and (> cap 0) (out-immobile cap)))
    (define-values (rc needed)
      (glowcap_driver_listener_restoration_state
       (driver-loop-handle lp)
       (loop-listener-id listener)
       out
       cap))
    (values rc needed out))
  (define-values (rc needed _out) (query 0))
  (cond
    [(= rc OK) #""]
    [(= rc ERR-BUFFER-TOO-SMALL)
     (let copy ([capacity (max 1 needed)])
       (define-values (copy-rc copied out) (query capacity))
       (cond
         [(= copy-rc OK)
          (when (> copied capacity)
            (raise-glowcap 'loop-listener-restoration-state ERR-INTERNAL
                           "driver returned restoration state larger than its buffer"))
          (bytes<-c out copied)]
         [(= copy-rc ERR-BUFFER-TOO-SMALL)
          (copy (max (add1 capacity) copied))]
         [else (check/driver copy-rc)]))]
    [else (check/driver rc)]))

(define (loop-listener-advertise! lp listener locator-uri)
  (require-listener-ready listener)
  (call-with-locator-view
   locator-uri
   (lambda (view)
      (check/driver
       (glowcap_driver_listener_advertise
        (driver-loop-handle lp) (loop-listener-id listener) view)))))

(define (loop-listener-select! lp listener)
  (require-listener-ready listener)
  (check/driver
   (glowcap_driver_listener_select (driver-loop-handle lp)
                                   (loop-listener-id listener))))

(define (loop-listener-close! lp listener)
  (unless (eq? (loop-listener-lp listener) lp)
    (raise-glowcap 'glowcap-loop ERR-INVALID-ARGUMENT
                   "listener belongs to another driver loop"))
  (define state-box (loop-listener-state listener))
  (define prior
    (let claim ()
      (define state (unbox state-box))
      (cond
        [(memq state '(closed failed closing)) #f]
        [(box-cas! state-box state 'closing) state]
        [else (claim)])))
  (when prior
    (define close-error #f)
    (define m (driver-loop-host lp))
    (with-handlers ([exn? (lambda (e) (set! close-error e))])
      (when (loop-ffi-live? lp)
        (let join-close ()
          ;; Arm the generation before the retry. A provider retirement that
          ;; lands between the call and the park bumps this exact snapshot, so
          ;; asynchronous close cannot lose its wakeup.
          (define progress (host-progress-evt m))
          (unless (close-driver-listener!
                   (driver-loop-handle lp) (loop-listener-id listener))
            (check/driver (glowcap_driver_wake (driver-loop-handle lp)))
            (sync progress)
            (define terminal (unbox state-box))
            (if (eq? terminal 'failed)
                (raise (unbox (loop-listener-outcome listener)))
                (join-close))))))
    (when close-error
      (unless (eq? (unbox state-box) 'failed)
        (set-box! state-box prior))
      (raise close-error))
    (when (eq? prior 'pending)
      (set-box! (loop-listener-outcome listener) (listener-closed-exn 'close))
      (semaphore-post (loop-listener-settled listener)))
    (set-box! state-box 'closed)
    ;; Preserve events committed before close, including accepted sessions,
    ;; before retiring this listener's routing entry.
    (with-host-drain m
      (lambda () (dispatch-events! m lp (pop-events! lp))))
    (hash-remove! (driver-loop-listeners lp) (loop-listener-id listener))
    (async-channel-put (loop-listener-accepts listener) accepts-terminal))
  ;; The running loop may have stepped to finish an asynchronous provider
  ;; stop. Admission was sealed before that wait, so only already committed
  ;; accepts can still name this listener.
  (loop-listener-accepts listener))

;; A listening server over the loop: this owner owns one driver listener and its
;; unclaimed accept handles. Closing it stops only that listener; the loop,
;; Host, yielded sessions, and sibling listeners remain live. `retire-loop?` is
;; set when a bare `listen` created the loop and Host itself: that server is
;; their only reachable owner, so closing it also retires the loop.
(struct loop-server (lp listener time-travel? retire-loop? closed?))

(define (make-loop-server lp listener time-travel? retire-loop?)
  (loop-server lp listener time-travel? retire-loop? (box #f)))

(define (loop-server-locator s)
  (loop-listener-locator (loop-server-lp s) (loop-server-listener s)))

(define (loop-server-advertise! s locator-uri)
  (loop-listener-advertise! (loop-server-lp s) (loop-server-listener s)
                            locator-uri)
  (loop-listener-select! (loop-server-lp s) (loop-server-listener s)))

;; The next accepted session, already handshaken inside the accepting step.
;; Raises the listener-closed failure every accept surface raises once the
;; loop closes, so a server loop ends the same way byte-fed admission ends.
(define (loop-server-accept s)
  (define lp (loop-server-lp s))
  (when (unbox (loop-server-closed? s))
    (raise-glowcap 'accept ERR-CLOSED "listener closed"))
  (define accepts (loop-listener-accepts (loop-server-listener s)))
  (define item (async-channel-get accepts))
  (cond
    [(eq? item accepts-terminal)
     ;; Re-arm the terminal so every sibling accept ends too.
     (async-channel-put accepts accepts-terminal)
     (raise-glowcap 'accept ERR-CLOSED "listener closed")]
    [(exn? item)
     (async-channel-put accepts item)
     (raise item)]
    [else (wrap-loop-session lp item (loop-server-time-travel? s))]))

(define (loop-server-host s) (driver-loop-host (loop-server-lp s)))

;; Drive a retirement already committed by the FFI driver. Racket supplies
;; stepping and projects effects; the driver decides when the last claimed
;; session permits ordinary cancel close. The wait is event-driven: snapshot
;; the host progress event before stepping (so a rival path's step landing
;; between this step and the park still wakes this driver), then park on that
;; snapshot or on the nearest pending-work deadline.
(define (drive-loop-retirement! lp)
  (define m (driver-loop-host lp))
  (let loop ()
    (define gen (host-progress-evt m))
    (define state #f)
    (define wait-ms -1)
    (define fx
      (call-with-host
       m
       (lambda ()
         (define effects (loop-drain! m lp))
         (define-values (rc lifecycle)
           (glowcap_driver_lifecycle_state (driver-loop-handle lp)))
         (check/driver rc)
         (set! state lifecycle)
         (unless (lifecycle-closed? lifecycle)
           (set! wait-ms (loop-step-wait-ms lp)))
         effects)))
    (run-drain-effects! m fx)
    ;; A productive pass advanced state a sibling driver may be parked on;
    ;; an idle pass stays silent so parked drivers cannot wake each other in
    ;; an endless idle exchange.
    (when (drain-effects-productive? fx) (host-bump-progress! m))
    (unless (lifecycle-closed? state)
      (if (>= wait-ms 0)
          (sync/timeout (/ wait-ms 1000.0) gen)
          (sync gen))
      (loop)))
  (host-release-after-ffi-close! m))

(define (run-loop-retirement! lp)
  (with-handlers ([converts-to-broken?
                   (lambda (error) (loop-background-failed! lp error))])
    (drive-loop-retirement! lp)))

;; A bare server owns the Host it created. Commit FFI retirement once and
;; let the driver preserve every session handle already returned.
(define (driver-loop-retire! lp)
  (define state (driver-loop-state lp))
  (define claimed?
    (let claim ()
      (case (unbox state)
        [(open) (if (box-cas! state 'open 'retiring) #t (claim))]
        [(retiring failed stopping released) #f])))
  (when claimed?
    (call-with-host
     (driver-loop-host lp)
     (lambda ()
       (check/driver (glowcap_driver_retire (driver-loop-handle lp)))))
    (void (thread (lambda () (run-loop-retirement! lp))))))

(define (loop-server-close! s)
  (when (box-cas! (loop-server-closed? s) #f #t)
    (define lp (loop-server-lp s))
    (when (loop-running? lp)
      (define accepts (loop-listener-close! lp (loop-server-listener s)))
      ;; The C ABI preserves committed accepts. This server has no
      ;; acceptor, so release every unclaimed handle before publishing terminal
      ;; state; sessions already wrapped live in the Host registry and remain.
      (when accepts
        (let drain ()
          (define item (async-channel-try-get accepts))
          (when item
            (unless (eq? item accepts-terminal)
              (hash-remove! (driver-loop-closed-ptrs lp) (session-key item))
              (loop-session-release! lp item))
            (drain))))
      (when (loop-server-retire-loop? s)
        (driver-loop-retire! lp)))))
