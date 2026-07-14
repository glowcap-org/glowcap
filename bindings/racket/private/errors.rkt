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
         "ffi-driver.rkt"
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
(struct exn:fail:pancake exn:fail (code abort))

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
            (current-continuation-marks) code #f))))

(define (check code) (check-with code last-error))

;; (host-last-error) -> the calling thread's last error message from the
;; byte-fed host archive (libpancake_driver), or #f. The host family keeps its
;; own thread-local slot (`pancake_host_last_error`), symbol-disjoint from the
;; ocapn family's `last-error`.
(define (host-last-error) (read-last-error pancake_host_last_error))

;; `check` for the pancake_host_* family: same typed exn, read from the host
;; archive's own last-error slot.
(define (check/host code) (check-with code host-last-error))

;; Project a filled `_PancakeLastAbort` cstruct into an `abort-info`, copying
;; each process-static C view into a Racket string so the result outlives any
;; later library call. The host connection's abort readers
;; (`private/session.rkt`) build every typed refused-frame diagnostic
;; through this.
(define (abort-info<-c out)
  (define (str ptr len)
    (and ptr (positive? len) (bytes->string/utf-8 (bytes<-c ptr len) #\uFFFD)))
  (abort-info
   (let ([domain (PancakeLastAbort-domain out)])
     (cond [(= domain ABORT-DOMAIN-CODEC) 'codec]
           [(= domain ABORT-DOMAIN-SESSION) 'session]
           [else 'foreign]))
   (and (not (zero? (PancakeLastAbort-has-kind out)))
        (str (PancakeLastAbort-kind-name out) (PancakeLastAbort-kind-name-len out)))
   (or (str (PancakeLastAbort-message out) (PancakeLastAbort-message-len out)) "")
   (or (str (PancakeLastAbort-error-name out) (PancakeLastAbort-error-name-len out)) "")))

;; A typed application-level failure (a partner break, a fetch that did not
;; yield a capability): same exn family, no abort detail.
(define (raise-pancake who code fmt . args)
  (raise (exn:fail:pancake (format "~a: ~a" who (apply format fmt args))
                           (current-continuation-marks) code #f)))
