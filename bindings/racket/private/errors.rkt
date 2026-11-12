#lang racket/base
;; Internal: the typed glowcap failure and the per-thread last-error readers.
;;
;; Every archive family reads its own thread-local last-error slot through
;; `read-last-error`; `check`/`check-with` raise the one typed `exn:fail:glowcap`
;; from that diagnostic. The transport seam re-provides `check-with`,
;; `read-last-error`, and `raise-glowcap` so the companion modules raise the same
;; typed exn from their own last-error readers. Not a public API.

(require "constants.rkt"
         "ffi-ocapn.rkt"
         "ffi-host.rkt"
         "value.rkt")

(provide (all-defined-out))

;; ── Library identity and per-thread last error ───────────────────────────────
;; (abi-version) -> (values major minor patch) of the linked library.
(define (abi-version) (glowcap_abi_version))

;; Read a thread-local last-error slot into a Racket string, or #f when empty.
;; `raw` is an archive's two-arg C reader `(buffer cap) -> bytes-written`: query
;; the length first with a NULL buffer, then copy into a right-sized buffer and
;; clamp to what the second call wrote (the slot is zero-filled, so an
;; unclamped slice could trail NULs). Every archive family reads its own slot
;; through this (ocapn here, the three transports and the actor runtime through
;; the seam), so the two-pass discipline lives in one place.
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
(define (last-error) (read-last-error glowcap_last_error))

;; A glowcap failure carries the flat GLOWCAP_ERR_* `code` that names the
;; failure family. A refused inbound frame adds an
;; `abort-info` naming the member (built by `abort-info<-c` below); `abort` is
;; #f everywhere else. `cause` retains origin, reason and operation context; partner text
;; cannot establish a local cause.
(struct exn:fail:glowcap exn:fail
  (code abort carrier-failure secondary-code secondary-name secondary-count
        cause))

;; A broken vow. `reason` is the break reason the vow carried, exactly as the
;; partner or the Host gave it.
(struct exn:fail:glowcap:broken exn:fail:glowcap (reason))

(define (make-glowcap-error code message
                            #:cause [cause (break-cause 'unspecified 'unspecified 0)] #:abort [abort #f]
                            #:carrier-failure [carrier #f]
                            #:secondary-code [secondary-code #f]
                            #:secondary-name [secondary-name #f]
                            #:secondary-count [secondary-count 0]
                            #:marks [marks (current-continuation-marks)])
  (exn:fail:glowcap message marks code abort carrier
                    secondary-code secondary-name secondary-count cause))

(define (make-glowcap-broken code message reason
                             #:cause [cause (break-cause 'unspecified 'unspecified 0)]
                             #:marks [marks (current-continuation-marks)])
  (exn:fail:glowcap:broken message marks code #f #f #f #f 0 cause reason))

;; A connector cannot realize this route in its configuration, before opening
;; a channel. Keep its diagnostic verbatim for the Host's route-failure report.
(define (make-glowcap-transport-unavailable detail)
  (make-glowcap-error ERR-INVALID-ARGUMENT detail
                      #:cause (route-failure-cause 'transport-unavailable)))

;; Raise a typed glowcap failure for a non-OK `code`, reading the human-readable
;; cause through `read-error` (a thunk that returns the message string or #f).
;; Each transport archive keeps its own thread-local last-error slot, so a
;; transport module passes its own reader here; `check` is the ocapn-family
;; spelling that reads `glowcap_last_error`. The transport seam
;; (`private/seam.rkt`) provides `check-with` so `glowcap-tcp.rkt` /
;; `glowcap-inproc.rkt` raise the same typed exn from their own diagnostics.
(define (check-with code read-error [read-cause (lambda () (break-cause 'unspecified 'unspecified 0))])
  (unless (= code OK)
    ;; Capture both slots immediately, before any later call clobbers them.
    (define msg (read-error))
    (define cause (read-cause))
    (raise (cause-failure code msg cause))))

(define (check code) (check-with code last-error))

;; (host-last-error) -> the calling thread's last error message from the
;; byte-fed host archive (libglowcap_host), or #f. The host family keeps its
;; own thread-local slot (`glowcap_host_last_error`), symbol-disjoint from the
;; ocapn family's `last-error`.
(define (host-last-error) (read-last-error glowcap_host_last_error))

(define (host-last-error-cause)
  (define raw (make-GlowcapBreakCause 0 0 0))
  (glowcap_host_last_error_cause raw)
  (define fields (break-cause-fields<-c raw))
  (or (apply break-cause-from-fields fields) fields))

(define (check/host code) (check-with code host-last-error host-last-error-cause))

;; Predicates establish provenance before interpreting diagnostic text.
(define (glowcap-application-message failure)
  (and (exn:fail:glowcap:broken? failure)
       (= (exn:fail:glowcap-code failure) ERR-BROKEN)
       (break-cause-application? (exn:fail:glowcap-cause failure))
       (exn:fail:glowcap:broken-reason failure)))

(define (glowcap-publication-not-found? failure)
  (and (exn:fail:glowcap:broken? failure)
       (= (exn:fail:glowcap-code failure) ERR-BROKEN)
       (break-cause-publication-not-found?
        (exn:fail:glowcap-cause failure)
        (exn:fail:glowcap:broken-reason failure))))

(define (glowcap-peer-identity-unverified? failure)
  (and (exn:fail:glowcap? failure)
       (break-cause-peer-identity-unverified? (exn:fail:glowcap-cause failure))))

(define (glowcap-exporter-unreachable? failure)
  (and (exn:fail:glowcap? failure)
       (break-cause-exporter-unreachable? (exn:fail:glowcap-cause failure))))

;; Preserve the first glowcap failure while attaching the first later cleanup
;; failure and its total count. Racket exceptions are immutable values, so the
;; projection returns the equivalent enriched value rather than mutating it.
(define (retain-cleanup-failure primary cleanup)
  (cond
    [(and (exn:fail:glowcap? primary) (exn:fail:glowcap? cleanup))
     (define first? (zero? (exn:fail:glowcap-secondary-count primary)))
     (define code
       (if first? (exn:fail:glowcap-code cleanup) (exn:fail:glowcap-secondary-code primary)))
     (define name (if first? "GlowcapError" (exn:fail:glowcap-secondary-name primary)))
     (define count (min #xffffffff (add1 (exn:fail:glowcap-secondary-count primary))))
     ;; A copy keeps the primary's own type, so a broken vow stays one.
     (if (exn:fail:glowcap:broken? primary)
         (struct-copy exn:fail:glowcap:broken primary
                      [secondary-code #:parent exn:fail:glowcap code]
                      [secondary-name #:parent exn:fail:glowcap name]
                      [secondary-count #:parent exn:fail:glowcap count])
         (struct-copy exn:fail:glowcap primary
                      [secondary-code code]
                      [secondary-name name]
                      [secondary-count count]))]
    [else primary]))

;; Raise the first lifecycle failure after cleanup has completed, attaching a
;; later failure when both are glowcap errors. This is the common close-barrier
;; tail for FFI releases that consume their handle even when they report an
;; error.
(define (raise-retained-failures primary cleanup)
  (cond
    [(and primary cleanup) (raise (retain-cleanup-failure primary cleanup))]
    [primary (raise primary)]
    [cleanup (raise cleanup)]
    [else (void)]))

;; The handler predicate for a site that records, converts, or retains a
;; raised failure. Racket may raise any value, so every one of them is a
;; failure except a break: a break belongs to the thread's operator and escapes
;; as itself rather than becoming a diagnostic or a secondary cause.
(define (raised-failure? raised) (not (exn:break? raised)))

;; Run every rollback barrier in order, retain each observable consequence on
;; the unchanged construction failure, then raise it. A failed early cleanup
;; must not strand an owner that follows it in the transaction.
(define (raise-after-cleanups primary cleanups)
  (define retained primary)
  (for ([cleanup (in-list cleanups)])
    (with-handlers ([raised-failure?
                     (lambda (later)
                       (set! retained (retain-cleanup-failure retained later)))])
      (cleanup)))
  (raise retained))

;; Project the core-issued FAIL result into the promise outcome vocabulary.
;; No wrapper state participates: an unknown result is an ABI contract break,
;; not evidence that the vow was merely broken.
(define (failure-display code reason cause)
  (define label (break-cause-label cause))
  (define detail
    (cond [(and label reason (not (equal? reason ""))) (format "~a: ~a" label reason)]
          [label label]
          [else reason]))
  (if detail (format "glowcap error ~a: ~a" code detail) (format "glowcap error ~a" code)))

;; An unknown ABI value cannot establish provenance. Keep the original failure
;; and record the mismatch in its secondary diagnostics instead of throwing
;; while the pump is trying to settle it.
(define (cause-failure code reason cause)
  (define known? (break-cause? cause))
  (define provenance (if known? cause (break-cause 'unspecified 'unspecified 0)))
  (define message (failure-display code reason provenance))
  (define failure
    (if (= code ERR-BROKEN)
        (make-glowcap-broken code message reason #:cause provenance)
        (make-glowcap-error code message #:cause provenance)))
  (cond
    [known? failure]
    [(exn:fail:glowcap:broken? failure)
     (struct-copy exn:fail:glowcap:broken failure
                  [secondary-code #:parent exn:fail:glowcap ERR-INTERNAL]
                  [secondary-name #:parent exn:fail:glowcap (format "UnknownBreakCause(~a)" cause)]
                  [secondary-count #:parent exn:fail:glowcap 1])]
    [else
     (struct-copy exn:fail:glowcap failure
                  [secondary-code ERR-INTERNAL]
                  [secondary-name (format "UnknownBreakCause(~a)" cause)]
                  [secondary-count 1])]))

(define (vow-failure-outcome code raw-cause reason)
  (unless (or (= code ERR-BROKEN) (= code ERR-CLOSED))
    (raise-glowcap 'host-action ERR-INTERNAL "core emitted invalid FAIL result ~a" code))
  (cons 'failed (cause-failure code reason (or (apply break-cause-from-fields raw-cause) raw-cause))))

;; Project a filled `_GlowcapLastAbort` cstruct into an `abort-info`, copying
;; each process-static C view into a Racket string so the result outlives any
;; later library call. The Host session's abort readers
;; (`private/pump.rkt`) build every typed refused-frame diagnostic
;; through this.
(define (abort-info<-c out)
  (define (str ptr len)
    (and ptr (positive? len) (bytes->string/utf-8 (bytes<-c ptr len) #\uFFFD)))
  (abort-info
   (let ([domain (GlowcapLastAbort-domain out)])
     (cond [(= domain ABORT-DOMAIN-CODEC) 'codec]
           [(= domain ABORT-DOMAIN-SESSION) 'session]
           [(= domain ABORT-DOMAIN-FOREIGN) 'foreign]
           [else (raise-glowcap 'glowcap ERR-INTERNAL
                                "ABI returned unknown abort domain: ~a" domain)]))
   (and (not (zero? (GlowcapLastAbort-has-kind out)))
        (str (GlowcapLastAbort-kind-name out) (GlowcapLastAbort-kind-name-len out)))
   (or (str (GlowcapLastAbort-message out) (GlowcapLastAbort-message-len out)) "")
   (or (str (GlowcapLastAbort-error-name out) (GlowcapLastAbort-error-name-len out)) "")
   (str (GlowcapLastAbort-abort-delivery-error-name out)
        (GlowcapLastAbort-abort-delivery-error-name-len out))
   (str (GlowcapLastAbort-secondary-error-name out)
        (GlowcapLastAbort-secondary-error-name-len out))
   (GlowcapLastAbort-secondary-error-count out)))

;; A typed application-level failure (a fetch that did not yield a
;; capability, a closed connection): same exn family, no abort detail.
(define (raise-glowcap who code fmt . args)
  (raise (make-glowcap-error code (format "~a: ~a" who (apply format fmt args)))))

;; The vow awaited for `subject` broke. The reason rides on the failure, so a
;; caller compares the cause without reading the message.
(define (raise-broken who subject reason)
  (when (exn:fail:glowcap? reason) (raise reason))
  (raise (make-glowcap-broken ERR-BROKEN (format "~a: ~a broke: ~a" who subject reason) reason)))

(module+ test
  (require rackunit)
  (for ([route '(peer-unreachable transport-unavailable)])
    (define cause (route-failure-cause route))
    (check-equal? (route-failure-from-cause cause) route)
    (for ([context (list break-context-fetch break-context-restoration break-context-withdrawal)])
      (check-false (route-failure-from-cause (struct-copy break-cause cause [context context])))))
  (check-false (route-failure-from-cause (break-cause 'partner 'application 0)))
  (check-false (route-failure-from-cause (break-cause 'unspecified 'unspecified 0)))
  (check-equal? (route-failure-from-cause
                 (exn:fail:glowcap-cause (make-glowcap-transport-unavailable "no connector")))
                'transport-unavailable)
  (check-true (release-result-consumed? OK))
  (for ([code (in-list (list ERR-INVALID-ARGUMENT ERR-IO ERR-INTERNAL WOULD-BLOCK))])
    (check-false (release-result-consumed? code))
    (check-true (release-result-consumed? (- code)))
    (check-equal? (release-result-code code) code)
    (check-equal? (release-result-code (- code)) code))
  (define primary
    (make-glowcap-error ERR-INVALID-ARGUMENT "primary"))
  (define cleanup
    (make-glowcap-error ERR-IO "cleanup"))
  (define retained (retain-cleanup-failure primary cleanup))
  (check-equal? (exn-message retained) "primary")
  (check-equal? (exn:fail:glowcap-code retained) ERR-INVALID-ARGUMENT)
  (check-equal? (exn:fail:glowcap-secondary-code retained) ERR-IO)
  (check-equal? (exn:fail:glowcap-secondary-count retained) 1)
  (define twice (retain-cleanup-failure retained primary))
  (check-equal? (exn:fail:glowcap-secondary-code twice) ERR-IO)
  (check-equal? (exn:fail:glowcap-secondary-count twice) 2)

  (define cleanup-order '())
  (define rolled-back
    (with-handlers ([exn:fail:glowcap? values])
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
  (check-equal? (exn:fail:glowcap-secondary-count rolled-back) 2))
