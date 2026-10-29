#lang racket/base
;; Internal: one writer pass for a byte-fed session. The session's writer
;; thread (`outbound.rkt`) is the only caller: it takes every frame the core
;; queued, in bounded batches through the pending-writes FIFO, and writes them,
;; so no reader ever waits on a write.

(require racket/lazy-require
         "../constants.rkt"
         "../ffi-ocapn.rkt"
         "../ffi-host.rkt"
         "../ffi-shared.rkt"
         "../errors.rkt"
         "../async.rkt"
         "../pending-writes.rkt"
         "../host/state.rkt"
         "state.rkt")

;; Lazy-require breaks the session ↔ write cycle: session builds each writer
;; with this pass.
(lazy-require
 ["../session.rkt"
  (retire-session-wire-failure!)])

(provide write-session-outbound!)

;; One writer pass for `c`, run only on its writer thread. A popped frame
;; cannot be replayed, and the stream may contain only its prefix, so a failed
;; write ends this session, settling its far vows closed, and keeps the exact
;; write error observable on it. Returns #f after such a failure.
(define (write-session-outbound! c)
  (with-handlers ([(lambda (_e) #t)
                   (lambda (error)
                     (record-session-outbound-failure! c error)
                     (retire-session-wire-failure! c)
                     #f)])
    (write-pending! c)
    #t))

;; Pop transport-ready prefix/payload vectors on `c` into its pending-writes
;; FIFO. The host returns canonical outer framing for clear sessions and an
;; empty prefix for wire-ready sealed payloads. Admission is checked before
;; `take_outbound` transfers ownership, so a full FIFO never drops an already
;; popped frame. One admitted frame may carry the FIFO over its high-water; the
;; drain then stops until `write-pending!` debits it. Only the session's writer
;; calls this, holding the host lock (`take_outbound` is a host verb), and it
;; writes the batch after the lock releases. Returns `empty` only when the core
;; queue was observed empty. Every other result means the writer must refill
;; after it drains this bounded batch.
(define (drain-outbound! c)
  ;; A loop-owned host's wire belongs to the loop (ADR-0024): its steps
  ;; flush queued outbound themselves, and `take_outbound` must not compete
  ;; with them, so a loop-hosted session drains nothing here.
  ;; Breaks stay off across the whole drain: a frame `take_outbound` handed
  ;; over is on the wire only once its bytes reach the pending writes, and a
  ;; break between the two would release it unsent and corrupt the stream.
  ;; Nothing here blocks, and the pending-writes room bounds the loop.
  (if (or (session-released? c) (host-loop-of (session-host c)))
      'empty
      (parameterize-break #f
        (let loop ([queued? #f])
          (if (pending-writes-has-room? (session-pending-writes c))
              (let ([mf (session-outbound-frame c)]
                    [prefix (session-outbound-prefix c)])
                (define-values (rc prefix-len)
                  (glowcap_host_session_take_outbound
                   (session-ptr c) mf prefix (bytes-length prefix)))
                (cond
                  [(= rc WOULD-BLOCK) (if queued? 'queued-drained 'empty)]
                  [else
                   (check/host rc)
                   (define out
                     (dynamic-wind
                      void
                      (lambda ()
                        (bytes<-c (GlowcapManagedFrame-bytes mf)
                                  (GlowcapManagedFrame-len mf)))
                      (lambda () (glowcap_managed_frame_release mf))))
                   (if (pending-writes-put-pair!
                        (session-pending-writes c)
                        (subbytes prefix 0 prefix-len)
                        out)
                       (loop #t)
                       'queued-bounded)]))
              (if queued? 'queued-bounded 'bounded))))))

;; Take every frame the core queued on `c` and write it, in bounded batches:
;; take a batch into the pending-writes FIFO under the host lock, release the
;; lock, write and flush the batch, and repeat until the core queue was
;; observed empty. Only the session's writer runs this, so writes never
;; interleave and no reader waits on them. A dead transport's write error is
;; the caller's to tolerate.
(define (write-pending! c)
  ;; The loop-owned early-out above holds here too: the loop writes its own
  ;; wire, and this session's FIFO stays empty.
  (unless (host-loop-of (session-host c))
    (define tr (async-connection-transport (session-async c)))
    (let batch-loop ()
      ;; `empty` is the sole proof that no core frame was stranded behind the
      ;; FIFO's high-water stop.
      (define status
        (if (session-released? c)
            'empty
            (call-with-host (session-host c) (lambda () (drain-outbound! c)))))
      (define wrote?
        (let write-loop ([wrote? #f])
          (define out (pending-writes-try-get! (session-pending-writes c)))
          (if out
              (begin
                ((async-transport-write-frame! tr) out)
                (write-loop #t))
              wrote?)))
      (when wrote?
        ((async-transport-flush! tr)))
      (unless (eq? status 'empty) (batch-loop)))))
