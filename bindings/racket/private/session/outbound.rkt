#lang racket/base
;; Internal: a session's one writer thread. FLUSH and CLOSE actions wake it,
;; and nothing that reads waits on a write, so a partner slow to read cannot
;; stop this side reading. Passes are counted: a caller that must know its
;; frames left waits for the first pass that began after its request, which
;; takes every frame the core had queued by then. The session supplies the
;; pass and the close; this leaf owns only the thread and its phases.

(provide make-outbound
         outbound-request!
         outbound-written-state
         outbound-close-after-flush!
         outbound-close-delivered?
         outbound-stop!)

;; `phase` is 'idle, 'running, 'closing, or 'exited. `lock` guards every
;; field the requesting threads and the writer share; `wake` counts requests
;; and the writer coalesces them. `parameterization` is the session's
;; construction context, so a writer started from inside a reader's drain
;; never inherits that reader's deferred-effects box.
(struct outbound (pass! finish! progress! parameterization
                  lock wake
                  [phase #:mutable] [stopped? #:mutable]
                  [started #:mutable] [finished #:mutable]
                  [close-result #:mutable]))

;; `pass!` takes and writes every queued frame, returning #f when it failed:
;; it has already retained the cause and retired the session. `finish!`
;; commits a delivered CLOSE with its result. `progress!` wakes every waiter
;; after each pass and on exit.
(define (make-outbound pass! finish! progress!)
  (outbound pass! finish! progress! (current-parameterization)
            (make-semaphore 1) (make-semaphore 0)
            'idle #f 0 0 #f))

;; Wake the writer, starting it on first use. Returns before any byte is
;; written, with the number of the pass that takes every frame queued so far,
;; for `outbound-written-state`. Safe under the host lock: it never blocks.
(define (outbound-request! w)
  (define covering
    (call-with-semaphore (outbound-lock w)
      (lambda () (start-locked! w) (+ (outbound-started w) 1))))
  (semaphore-post (outbound-wake w))
  covering)

(define (start-locked! w)
  (when (eq? (outbound-phase w) 'idle)
    (set-outbound-phase! w 'running)
    (call-with-parameterization (outbound-parameterization w)
      (lambda () (thread (lambda () (run w)))))))

;; Where pass `covering` stands: 'written once it has finished, 'exited when
;; the writer exited first, or 'pending. An exited writer closed the
;; transport, so frames it had not taken never leave. A waiter snapshots the
;; progress wake before asking, then waits on it while 'pending.
(define (outbound-written-state w covering)
  (call-with-semaphore (outbound-lock w)
    (lambda ()
      (cond
        [(>= (outbound-finished w) covering) 'written]
        [(eq? (outbound-phase w) 'exited) 'exited]
        [else 'pending]))))

;; Mark the CLOSE so the writer closes the transport once it has drained every
;; frame the core queued ahead of it, then commits it with `result`. Returns
;; #t when the writer already exited, and the caller commits it instead.
(define (outbound-close-after-flush! w result)
  (define exited?
    (call-with-semaphore (outbound-lock w)
      (lambda ()
        (set-outbound-close-result! w result)
        (start-locked! w)
        (cond
          [(eq? (outbound-phase w) 'exited) #t]
          [else (set-outbound-phase! w 'closing) #f]))))
  (semaphore-post (outbound-wake w))
  exited?)

;; The core already ended this session. Reading is over, and the writer
;; closes the transport after its final drain.
(define (outbound-close-delivered? w)
  (and (outbound-close-result w) #t))

;; The transport closed under the writer: exit after any pass in flight.
(define (outbound-stop! w)
  (call-with-semaphore (outbound-lock w)
    (lambda () (set-outbound-stopped?! w #t)))
  (semaphore-post (outbound-wake w)))

;; Each wake drains everything queued, so requests coalesce. The phase is read
;; before the pass: a CLOSE that lands during it also wakes the writer, so the
;; next pass drains its frames and then closes.
(define (run w)
  (dynamic-wind
   void
   (lambda ()
     (let loop ()
       (semaphore-wait (outbound-wake w))
       (let coalesce () (when (semaphore-try-wait? (outbound-wake w)) (coalesce)))
       ;; The pass to run, 'running or 'closing, or #f once stopped.
       (define mode
         (call-with-semaphore (outbound-lock w)
           (lambda ()
             (and (not (outbound-stopped? w))
                  (begin
                    (set-outbound-started! w (+ (outbound-started w) 1))
                    (if (eq? (outbound-phase w) 'closing) 'closing 'running))))))
       (when mode
         (define ok? ((outbound-pass! w)))
         (call-with-semaphore (outbound-lock w)
           (lambda () (set-outbound-finished! w (outbound-started w))))
         ((outbound-progress! w))
         (when (and ok? (eq? mode 'running)) (loop)))))
   (lambda ()
     (define result
       (call-with-semaphore (outbound-lock w)
         (lambda ()
           (set-outbound-phase! w 'exited)
           (outbound-close-result w))))
     (when result ((outbound-finish! w) result))
     ((outbound-progress! w)))))

(module+ test
  (require rackunit)

  ;; A writer over recording seams. `gate`, when set, holds every pass until
  ;; it is posted, and `ok?` is what each pass reports.
  (define (recording-writer #:gate [gate #f] #:ok? [ok? #t])
    (define events (box '()))
    (define (note! event) (set-box! events (cons event (unbox events))))
    (define progress (make-semaphore 0))
    (define w
      (make-outbound (lambda ()
                       (note! 'pass)
                       (when gate (semaphore-wait gate))
                       ok?)
                     (lambda (result) (note! (list 'finish result)))
                     (lambda () (semaphore-post progress))))
    (values w (lambda () (reverse (unbox events))) progress))

  ;; Return once the first pass is in flight, so what follows lands mid-pass.
  (define (await-pass-started events)
    (let loop () (when (null? (events)) (sync/timeout 0.01 never-evt) (loop))))

  (define (await-state w covering progress)
    (let loop ()
      (define state (outbound-written-state w covering))
      (if (eq? state 'pending)
          (begin (sync/timeout 5 progress) (loop))
          state)))

  (test-case "a pass covers every request made before it began"
    (define-values (w events progress) (recording-writer))
    (define covering (outbound-request! w))
    (check-eq? (await-state w covering progress) 'written)
    (check-equal? (events) '(pass)))

  (test-case "a CLOSE that lands mid-pass drains once more, then commits"
    (define gate (make-semaphore 0))
    (define-values (w events progress) (recording-writer #:gate gate))
    (define first-pass (outbound-request! w))
    (await-pass-started events)
    (check-false (outbound-close-after-flush! w 0))
    (check-true (outbound-close-delivered? w))
    (semaphore-post gate)
    (semaphore-post gate)
    (check-eq? (await-state w first-pass progress) 'written)
    (check-eq? (await-state w (+ first-pass 1) progress) 'written)
    (let wait () (unless (eq? (outbound-written-state w 99) 'exited)
                   (sync/timeout 5 progress) (wait)))
    (check-equal? (events) '(pass pass (finish 0))))

  (test-case "a failed pass stops the writer and later frames never leave"
    (define-values (w events progress) (recording-writer #:ok? #f))
    (check-eq? (await-state w (outbound-request! w) progress) 'written)
    (check-eq? (await-state w (outbound-request! w) progress) 'exited)
    ;; The writer already exited, so the CLOSE's commit is the caller's.
    (check-true (outbound-close-after-flush! w 5))
    (check-equal? (events) '(pass)))

  (test-case "a stopped writer exits and still commits its delivered CLOSE"
    (define gate (make-semaphore 0))
    (define-values (w events progress) (recording-writer #:gate gate))
    (outbound-request! w)
    (await-pass-started events)
    (outbound-close-after-flush! w 7)
    (outbound-stop! w)
    (semaphore-post gate)
    (check-eq? (await-state w 2 progress) 'exited)
    (check-equal? (events) '(pass (finish 7)))))
