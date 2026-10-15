#lang racket/base
;; One linear lifetime for an FFI parent handle whose children borrow it.
;; Parent operations take leases without holding the gate across foreign code.
;; Close seals admission, requests FFI cancellation, retires children, joins
;; every lease, and only then releases the parent.

(provide make-ffi-parent
         ffi-parent-open-child
         ffi-parent-adopt-or-release!
         ffi-parent-forget!
         ffi-parent-release!)

(struct ffi-parent
  (handle children gate active closing? drained closed shutdown release)
  #:mutable)

(define (make-ffi-parent handle release [shutdown (lambda (_) (void))])
  (ffi-parent handle (make-hasheq) (make-semaphore 1) 0 #f
                 (make-semaphore 0) (make-semaphore 0) shutdown release))

;; Finish one operation lease. The caller has already released every FFI
;; child the parent did not adopt, so reaching zero means parent release may
;; safely destroy the backend.
(define (finish-operation! parent)
  (call-with-semaphore
   (ffi-parent-gate parent)
   (lambda ()
     (set-ffi-parent-active! parent (sub1 (ffi-parent-active parent)))
     (when (and (ffi-parent-closing? parent)
                (zero? (ffi-parent-active parent)))
       (semaphore-post (ffi-parent-drained parent))))))

;; Adopt a completed child and retire its operation lease as one transition.
;; When close won, leave the lease active: the caller must release the late
;; child first because it still borrows the parent backend.
(define (adopt-child-and-finish! parent child)
  (call-with-semaphore
   (ffi-parent-gate parent)
   (lambda ()
     (cond
       [(and (not (ffi-parent-closing? parent))
             (ffi-parent-handle parent))
        (hash-set! (ffi-parent-children parent) child #t)
        (set-ffi-parent-active! parent (sub1 (ffi-parent-active parent)))
        #t]
       [else #f]))))

;; Run one parent-handle operation without holding the parent gate across FFI
;; code. `make-child` owns cleanup if it raises before returning a child wrapper;
;; `release-child` owns the completed-child race where close sealed admission
;; while the operation was in flight.
(define (ffi-parent-open-child parent who make-child release-child)
  (define handle
    (call-with-semaphore
     (ffi-parent-gate parent)
     (lambda ()
       (when (or (ffi-parent-closing? parent)
                 (not (ffi-parent-handle parent)))
         (error who "netlayer is closed"))
       (set-ffi-parent-active! parent (add1 (ffi-parent-active parent)))
       (ffi-parent-handle parent))))
  (define child
    (with-handlers ([(lambda (_) #t)
                     (lambda (raised)
                       (finish-operation! parent)
                       (raise raised))])
      (make-child handle)))
  (cond
    [(adopt-child-and-finish! parent child) child]
    [else
     ;; Cleanup stays outside the gate, but the lease remains active through it.
     ;; `dynamic-wind` retires the lease even when a finalizer itself raises.
     (dynamic-wind
      void
      (lambda () (release-child child))
      (lambda () (finish-operation! parent)))
     (error who "netlayer closed while operation was in flight")]))

;; Accept cannot be a parent operation lease: its listener child owns the FFI
;; cancellation edge. Adopt its completed connection afterward, or free it when
;; parent close won the race.
(define (ffi-parent-adopt-or-release! parent child release-child who)
  (define adopted?
    (call-with-semaphore
     (ffi-parent-gate parent)
     (lambda ()
       (cond
         [(or (ffi-parent-closing? parent)
              (not (ffi-parent-handle parent))) #f]
         [else
          (hash-set! (ffi-parent-children parent) child #t)
          #t]))))
  (unless adopted?
    (release-child child)
    (error who "netlayer closed while accepting"))
  child)

(define (ffi-parent-forget! parent child)
  (call-with-semaphore
   (ffi-parent-gate parent)
   (lambda () (hash-remove! (ffi-parent-children parent) child))))

;; `release-child` and the FFI shutdown/release callbacks are idempotent.
;; Teardown remembers the first failure while still completing every phase, so a
;; bad finalizer cannot strand the parent or another close caller.
(define (ffi-parent-release! parent release-child)
  (define children #f)
  (define handle #f)
  (define first?
    (call-with-semaphore
     (ffi-parent-gate parent)
     (lambda ()
       (cond
         [(ffi-parent-closing? parent) #f]
         [else
          (set-ffi-parent-closing?! parent #t)
          (set! handle (ffi-parent-handle parent))
          (set! children (hash-keys (ffi-parent-children parent)))
          (hash-clear! (ffi-parent-children parent))
          #t]))))
  (cond
    [first?
     (define failure #f)
     (define (attempt thunk)
       (with-handlers ([(lambda (_) #t)
                        (lambda (raised) (unless failure (set! failure raised)))])
         (thunk)))
     ;; Cancellation precedes every join. This is the only ordering that lets a
     ;; stalled FFI open operation make progress toward releasing its lease.
     (when handle
       (attempt (lambda () ((ffi-parent-shutdown parent) handle))))
     (for ([child (in-list children)])
       (attempt (lambda () (release-child child))))
     (define wait-for-operations?
       (call-with-semaphore
        (ffi-parent-gate parent)
        (lambda () (not (zero? (ffi-parent-active parent))))))
     (when wait-for-operations?
       (sync (semaphore-peek-evt (ffi-parent-drained parent))))
     ;; Claim the terminal handle under the gate, then run foreign release
     ;; outside it. Release may join FFI cancellation work; holding the gate
     ;; there would park every operation trying to retire its lease.
     (define current
       (call-with-semaphore
        (ffi-parent-gate parent)
        (lambda ()
          (begin0 (ffi-parent-handle parent)
            (set-ffi-parent-handle! parent #f)))))
     (when current
       (attempt (lambda () ((ffi-parent-release parent) current))))
     (semaphore-post (ffi-parent-closed parent))
     (when failure (raise failure))]
    [else
     (sync (semaphore-peek-evt (ffi-parent-closed parent)))]))
