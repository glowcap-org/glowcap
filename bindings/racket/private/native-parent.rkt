#lang racket/base
;; One linear lifetime for a native parent handle whose children borrow it.
;; Parent operations take leases without holding the gate across foreign code.
;; Close seals admission, requests native cancellation, retires children, joins
;; every lease, and only then releases the parent.

(provide make-native-parent
         native-parent-open-child
         native-parent-adopt-or-release!
         native-parent-forget!
         native-parent-release!)

(struct native-parent
  (handle children gate active closing? drained closed shutdown release)
  #:mutable)

(define (make-native-parent handle release [shutdown (lambda (_) (void))])
  (native-parent handle (make-hasheq) (make-semaphore 1) 0 #f
                 (make-semaphore 0) (make-semaphore 0) shutdown release))

;; Finish one operation lease. The caller has already released every native
;; child the parent did not adopt, so reaching zero means parent release may
;; safely destroy the backend.
(define (finish-operation! parent)
  (call-with-semaphore
   (native-parent-gate parent)
   (lambda ()
     (set-native-parent-active! parent (sub1 (native-parent-active parent)))
     (when (and (native-parent-closing? parent)
                (zero? (native-parent-active parent)))
       (semaphore-post (native-parent-drained parent))))))

;; Adopt a completed child and retire its operation lease as one transition.
;; When close won, leave the lease active: the caller must release the late
;; child first because it still borrows the parent backend.
(define (adopt-child-and-finish! parent child)
  (call-with-semaphore
   (native-parent-gate parent)
   (lambda ()
     (cond
       [(and (not (native-parent-closing? parent))
             (native-parent-handle parent))
        (hash-set! (native-parent-children parent) child #t)
        (set-native-parent-active! parent (sub1 (native-parent-active parent)))
        #t]
       [else #f]))))

;; Run one parent-handle operation without holding the parent gate across native
;; code. `make-child` owns cleanup if it raises before returning a child wrapper;
;; `release-child` owns the completed-child race where close sealed admission
;; while the operation was in flight.
(define (native-parent-open-child parent who make-child release-child)
  (define handle
    (call-with-semaphore
     (native-parent-gate parent)
     (lambda ()
       (when (or (native-parent-closing? parent)
                 (not (native-parent-handle parent)))
         (error who "netlayer is closed"))
       (set-native-parent-active! parent (add1 (native-parent-active parent)))
       (native-parent-handle parent))))
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

;; Accept cannot be a parent operation lease: its listener child owns the native
;; cancellation edge. Adopt its completed connection afterward, or free it when
;; parent close won the race.
(define (native-parent-adopt-or-release! parent child release-child who)
  (define adopted?
    (call-with-semaphore
     (native-parent-gate parent)
     (lambda ()
       (cond
         [(or (native-parent-closing? parent)
              (not (native-parent-handle parent))) #f]
         [else
          (hash-set! (native-parent-children parent) child #t)
          #t]))))
  (unless adopted?
    (release-child child)
    (error who "netlayer closed while accepting"))
  child)

(define (native-parent-forget! parent child)
  (call-with-semaphore
   (native-parent-gate parent)
   (lambda () (hash-remove! (native-parent-children parent) child))))

;; `release-child` and the native shutdown/release callbacks are idempotent.
;; Teardown remembers the first failure while still completing every phase, so a
;; bad finalizer cannot strand the parent or another close caller.
(define (native-parent-release! parent release-child)
  (define children #f)
  (define handle #f)
  (define first?
    (call-with-semaphore
     (native-parent-gate parent)
     (lambda ()
       (cond
         [(native-parent-closing? parent) #f]
         [else
          (set-native-parent-closing?! parent #t)
          (set! handle (native-parent-handle parent))
          (set! children (hash-keys (native-parent-children parent)))
          (hash-clear! (native-parent-children parent))
          #t]))))
  (cond
    [first?
     (define failure #f)
     (define (attempt thunk)
       (with-handlers ([(lambda (_) #t)
                        (lambda (raised) (unless failure (set! failure raised)))])
         (thunk)))
     ;; Cancellation precedes every join. This is the only ordering that lets a
     ;; stalled native open operation make progress toward releasing its lease.
     (when handle
       (attempt (lambda () ((native-parent-shutdown parent) handle))))
     (for ([child (in-list children)])
       (attempt (lambda () (release-child child))))
     (define wait-for-operations?
       (call-with-semaphore
        (native-parent-gate parent)
        (lambda () (not (zero? (native-parent-active parent))))))
     (when wait-for-operations?
       (sync (semaphore-peek-evt (native-parent-drained parent))))
     ;; Claim the terminal handle under the gate, then run foreign release
     ;; outside it. Release may join native cancellation work; holding the gate
     ;; there would park every operation trying to retire its lease.
     (define current
       (call-with-semaphore
        (native-parent-gate parent)
        (lambda ()
          (begin0 (native-parent-handle parent)
            (set-native-parent-handle! parent #f)))))
     (when current
       (attempt (lambda () ((native-parent-release parent) current))))
     (semaphore-post (native-parent-closed parent))
     (when failure (raise failure))]
    [else
     (sync (semaphore-peek-evt (native-parent-closed parent)))]))
