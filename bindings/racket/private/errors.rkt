#lang racket/base
;; Internal: the typed pancake failure and the per-thread last-error readers.
;;
;; Every archive family reads its own thread-local last-error slot through
;; `read-last-error`; `check`/`check-with` raise the one typed `exn:fail:pancake`
;; from that diagnostic. The transport seam re-provides `check-with`,
;; `read-last-error`, and `raise-pancake` so the companion modules raise the same
;; typed exn from their own last-error readers. Not a public API.

(require "constants.rkt"
         "ffi-ocapn.rkt"
         "ffi-host.rkt"
         "value.rkt")

(provide (all-defined-out))

;; ── Library identity and per-thread last error ───────────────────────────────
;; (abi-version) -> (values major minor patch) of the linked library.
(define (abi-version) (pancake_abi_version))

;; Read a thread-local last-error slot into a Racket string, or #f when empty.
;; `raw` is an archive's two-arg C reader `(buffer cap) -> bytes-written`: query
;; the length first with a NULL buffer, then copy into a right-sized buffer and
;; clamp to what the second call actually wrote (the slot is zero-filled, so an
;; unclamped slice could trail NULs). Every archive family reads its own slot
;; through this — ocapn here, the three transports and the actor runtime through
;; the seam — so the two-pass discipline lives in one place.
(define (read-last-error raw)
  (define len (raw #f 0))
  (cond
    [(zero? len) #f]
    [else
     ;; The C side reserves one byte for a NUL and copies at most cap-1 message
     ;; bytes, so allocate len + 1 to receive all `len` of them.
     (define buf (make-bytes (+ len 1)))
     (define written (raw buf (+ len 1)))
     (bytes->string/utf-8 (subbytes buf 0 (min written len)) #\uFFFD)]))

;; (last-error) -> the calling thread's last error message as a string, or #f
;; when there is none.
(define (last-error) (read-last-error pancake_last_error))

;; A pancake failure carries the flat PANCAKE_ERR_* `code` that names the
;; failure family, plus — when the failure was a refused inbound frame — an
;; `abort-info` naming the member (built by `abort-info<-c` below); `abort` is
;; #f everywhere else.
(struct exn:fail:pancake exn:fail
  (code abort carrier-failure secondary-code secondary-name secondary-count))

;; Raise a typed pancake failure for a non-OK `code`, reading the human-readable
;; cause through `read-error` (a thunk that returns the message string or #f).
;; Each transport archive keeps its own thread-local last-error slot, so a
;; transport module passes its own reader here; `check` is the ocapn-family
;; spelling that reads `pancake_last_error`. The transport seam
;; (`private/seam.rkt`) provides `check-with` so `pancake-tcp.rkt` /
;; `pancake-inproc.rkt` raise the same typed exn from their own diagnostics.
(define (check-with code read-error)
  (unless (= code OK)
    (define msg (read-error))   ; capture immediately, before any later call clobbers it
    (raise (exn:fail:pancake
            (if msg
                (format "pancake error ~a: ~a" code msg)
                (format "pancake error ~a" code))
            (current-continuation-marks) code #f #f #f #f 0))))

(define (check code) (check-with code last-error))

;; (host-last-error) -> the calling thread's last error message from the
;; byte-fed host archive (libpancake_host), or #f. The host family keeps its
;; own thread-local slot (`pancake_host_last_error`), symbol-disjoint from the
;; ocapn family's `last-error`.
(define (host-last-error) (read-last-error pancake_host_last_error))

;; `check` for the pancake_host_* family: same typed exn, read from the host
;; archive's own last-error slot.
(define (check/host code) (check-with code host-last-error))

;; Whether a final native release crossed its ownership boundary. The Host and
;; driver release contracts share one pre-commit refusal: INVALID-ARGUMENT.
;; Every other result is a teardown outcome and names an already-consumed
;; handle, even when `check/host` or `check/driver` must still raise it.
(define (release-consumed? code)
  (not (= code ERR-INVALID-ARGUMENT)))

;; Preserve the first pancake failure while attaching the first later cleanup
;; failure and its total count. Racket exceptions are immutable values, so the
;; projection returns the equivalent enriched value rather than mutating it.
(define (retain-cleanup-failure primary cleanup)
  (cond
    [(and (exn:fail:pancake? primary) (exn:fail:pancake? cleanup))
     (struct-copy exn:fail:pancake primary
                  [secondary-code
                   (if (zero? (exn:fail:pancake-secondary-count primary))
                       (exn:fail:pancake-code cleanup)
                       (exn:fail:pancake-secondary-code primary))]
                  [secondary-name
                   (if (zero? (exn:fail:pancake-secondary-count primary))
                       "PancakeError"
                       (exn:fail:pancake-secondary-name primary))]
                  [secondary-count
                   (min #xffffffff
                        (add1 (exn:fail:pancake-secondary-count primary)))])]
    [else primary]))

;; Raise the first lifecycle failure after cleanup has completed, attaching a
;; later failure when both are pancake errors. This is the common close-barrier
;; tail for native releases that consume their handle even when they report an
;; error.
(define (raise-retained-failures primary cleanup)
  (cond
    [(and primary cleanup) (raise (retain-cleanup-failure primary cleanup))]
    [primary (raise primary)]
    [cleanup (raise cleanup)]
    [else (void)]))

;; Run every rollback barrier in order, retain each observable consequence on
;; the unchanged construction failure, then raise it. A failed early cleanup
;; must not strand an owner that follows it in the transaction.
(define (raise-after-cleanups primary cleanups)
  (define retained primary)
  (for ([cleanup (in-list cleanups)])
    (with-handlers ([(lambda (_) #t)
                     (lambda (later)
                       (set! retained (retain-cleanup-failure retained later)))])
      (cleanup)))
  (raise retained))

;; Project the core-issued FAIL result into the promise outcome vocabulary.
;; No wrapper state participates: an unknown result is an ABI contract break,
;; not evidence that the vow was merely broken.
(define (vow-failure-outcome code reason)
  (cond
    [(= code ERR-BROKEN) (cons 'broken reason)]
    [(= code ERR-CLOSED) (cons 'closed reason)]
    [else
     (raise-pancake 'host-action ERR-INTERNAL
                    "core emitted invalid FAIL result ~a" code)]))

;; Project a filled `_PancakeLastAbort` cstruct into an `abort-info`, copying
;; each process-static C view into a Racket string so the result outlives any
;; later library call. The Host session's abort readers
;; (`private/pump.rkt`) build every typed refused-frame diagnostic
;; through this.
(define (abort-info<-c out)
  (define (str ptr len)
    (and ptr (positive? len) (bytes->string/utf-8 (bytes<-c ptr len) #\uFFFD)))
  (abort-info
   (let ([domain (PancakeLastAbort-domain out)])
     (cond [(= domain ABORT-DOMAIN-CODEC) 'codec]
           [(= domain ABORT-DOMAIN-SESSION) 'session]
           [(= domain ABORT-DOMAIN-FOREIGN) 'foreign]
           [else (raise-pancake 'pancake ERR-INTERNAL
                                "ABI returned unknown abort domain: ~a" domain)]))
   (and (not (zero? (PancakeLastAbort-has-kind out)))
        (str (PancakeLastAbort-kind-name out) (PancakeLastAbort-kind-name-len out)))
   (or (str (PancakeLastAbort-message out) (PancakeLastAbort-message-len out)) "")
   (or (str (PancakeLastAbort-error-name out) (PancakeLastAbort-error-name-len out)) "")
   (str (PancakeLastAbort-abort-delivery-error-name out)
        (PancakeLastAbort-abort-delivery-error-name-len out))
   (str (PancakeLastAbort-secondary-error-name out)
        (PancakeLastAbort-secondary-error-name-len out))
   (PancakeLastAbort-secondary-error-count out)))

;; A typed application-level failure (a partner break, a fetch that did not
;; yield a capability): same exn family, no abort detail.
(define (raise-pancake who code fmt . args)
  (raise (exn:fail:pancake (format "~a: ~a" who (apply format fmt args))
                           (current-continuation-marks) code #f #f #f #f 0)))

(module+ test
  (require rackunit)
  (check-false (release-consumed? ERR-INVALID-ARGUMENT))
  (check-true (release-consumed? OK))
  (check-true (release-consumed? ERR-IO))
  (define primary
    (exn:fail:pancake "primary" (current-continuation-marks)
                      ERR-INVALID-ARGUMENT #f #f #f #f 0))
  (define cleanup
    (exn:fail:pancake "cleanup" (current-continuation-marks)
                      ERR-IO #f #f #f #f 0))
  (define retained (retain-cleanup-failure primary cleanup))
  (check-equal? (exn-message retained) "primary")
  (check-equal? (exn:fail:pancake-code retained) ERR-INVALID-ARGUMENT)
  (check-equal? (exn:fail:pancake-secondary-code retained) ERR-IO)
  (check-equal? (exn:fail:pancake-secondary-count retained) 1)
  (define twice (retain-cleanup-failure retained primary))
  (check-equal? (exn:fail:pancake-secondary-code twice) ERR-IO)
  (check-equal? (exn:fail:pancake-secondary-count twice) 2)

  (define cleanup-order '())
  (define rolled-back
    (with-handlers ([exn:fail:pancake? values])
      (raise-after-cleanups
       primary
       (list
        (lambda ()
          (set! cleanup-order (append cleanup-order '(listener)))
          (raise cleanup))
        (lambda ()
          (set! cleanup-order (append cleanup-order '(loop)))
          (raise cleanup))))))
  (check-equal? cleanup-order '(listener loop))
  (check-equal? (exn-message rolled-back) "primary")
  (check-equal? (exn:fail:pancake-secondary-count rolled-back) 2))
