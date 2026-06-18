#lang racket/base
;; Goblins half of the S5 snapshot benchmark — the counterpart to pancake's
;; `bench/snapshot_bench.zig`. It measures Goblins' local time-travel natively
;; (Racket), to sit beside pancake's native (Zig) numbers. Because that is
;; native-Racket vs native-Zig, compare the *shape* of each cost and the
;; *algorithmic tradeoff*, not the absolute nanoseconds. Every number is a
;; median over repeated warmed samples.
;;
;; Three axes, mirroring the Zig half:
;;   - snapshot: `snapshot-whactormap` copies the actormap spine (one pointer per
;;     object) and shares each object's behavior by reference — O(objects), flat in
;;     the bytes an object holds.
;;   - restore: `hasheq->whactormap` rebuilds a live actormap from a snapshot after
;;     every actor has diverged. The diverged behaviors are reclaimed by Goblins'
;;     GC, not freed in the timed window (pancake frees them eagerly instead).
;;   - divergence: with a snapshot outstanding, `become` (`bcom`) an actor holding
;;     an N-entry immutable hash to a path-copied version — O(log N), the shape
;;     pancake's persistent actors mirror.
;;
;; Measured natively rather than through the shared wire suite because
;; snapshot/restore is a local actormap operation, not an OCapN conversation, and
;; pancake does not project it over the C ABI the Racket binding drives. Run it:
;;
;;   racket bench/goblins/snapshot.rkt            # full sweep
;;   racket bench/goblins/snapshot.rkt --smoke    # tiny counts
;;
;; Needs `racket` and the `goblins` collection on PATH.
(require goblins racket/list)

(define smoke? (and (member "--smoke" (vector->list (current-command-line-arguments))) #t))

;; An opaque M-byte actor for the snapshot/restore axes. Goblins behaviors are
;; immutable, so isolating a snapshot from a mutation means `become`-ing a fresh
;; bytevector — the O(M) shape pancake's mutable copy-on-write also pays.
(define (^blob bcom data)
  (lambda (method . args)
    (case method
      [(touch)
       (define next (bytes-copy data))
       (when (> (bytes-length next) 0)
         (bytes-set! next 0 (modulo (add1 (bytes-ref next 0)) 256)))
       (bcom (^blob bcom next))]
      [(get) (if (> (bytes-length data) 0) (bytes-ref data 0) 0)]
      [else (error '^blob "no method ~a" method)])))

;; An actor holding an N-entry immutable hash for the divergence axis. A touch
;; `become`s a path-copied version (`hash-set` on an immutable HAMT is O(log N)),
;; sharing every untouched subtree with the snapshot.
(define (^pmap bcom h)
  (lambda (method . args)
    (case method
      [(touch) (bcom (^pmap bcom (hash-set h (car args) (cadr args))))]
      [(get) (hash-ref h (car args) 0)]
      [else (error '^pmap "no method ~a" method)])))

(define (ms) (current-inexact-monotonic-milliseconds))
(define (ns-since t0) (* (- (ms) t0) 1e6))
(define (median xs) (let ([v (sort xs <)]) (list-ref v (quotient (length v) 2))))
(define (r x) (inexact->exact (round x)))

;; Build an actormap of K `^blob` actors of M bytes. The actormap holds keys
;; weakly, so the returned refrs must be kept alive or GC collects entries
;; mid-snapshot and crashes `snapshot-whactormap`. A real vat keeps its actors
;; alive; so does this bench.
(define (build-blob K M)
  (define am (make-actormap))
  (define refs (for/list ([_ (in-range K)]) (actormap-spawn! am ^blob (make-bytes M 0))))
  (values am refs))

;; Build an actormap of K `^pmap` actors, each over the same N-entry base hash
;; (immutable, so sharing it is free). Refrs kept alive for the same reason.
(define (build-pmap K N)
  (define am (make-actormap))
  (define base (for/hasheqv ([i (in-range N)]) (values i i)))
  (define refs (for/list ([_ (in-range K)]) (actormap-spawn! am ^pmap base)))
  (values am refs))

;; The actormap holds actors weakly and the returned refrs do not keep the
;; mactors alive, so a garbage collection can both trip `snapshot-whactormap`'s
;; `in-weak-hash` iterator mid-pass ("no element at index") *and*, more quietly,
;; reclaim actors just before a snapshot so it captures too few entries and times
;; too low. Neither is a signal in the data — a collection-free pass over the
;; whole population is the answer. `with-retry` reruns a measurement on the rare
;; trip (`collect-garbage` first clears the dead attempt); `expect-full` rejects
;; an undercounted snapshot so a retry rebuilds rather than reporting a low lie.
(define (with-retry thunk)
  (let loop ([tries 0])
    (with-handlers ([exn:fail?
                     (lambda (e)
                       (if (< tries 40) (begin (collect-garbage) (loop (add1 tries))) (raise e)))])
      (thunk))))

(define (expect-full snap K)
  (unless (= (hash-count snap) K)
    (error 'snapshot "undercount: ~a of ~a actors survived to the snapshot" (hash-count snap) K))
  snap)

;; A module-level anchor for the live population. A measurement's `am`/`refs` are
;; locals inside the retry lambda; Racket CS "safe-for-space" can drop them
;; mid-loop even with a trailing reference, letting the weak actormap shed actors
;; before a snapshot. Anchoring here keeps the whole population reachable for the
;; duration; `(pin! #f)` releases it. Holding the refrs keeps every weak entry.
(define live-pin (box #f))
(define (pin! v) (set-box! live-pin v) v)

;; Median snapshot ns over `samples` snapshots of a fresh K-object / M-byte
;; population. Each snapshot must capture all K actors or the pass is rejected.
(define (median-snapshot K M)
  (with-retry
   (lambda ()
     (define-values (am refs) (build-blob K M))
     (pin! refs)
     (begin0
       (median (for/list ([_ (in-range samples)])
                 (define t0 (ms))
                 (define snap (snapshot-whactormap am))
                 (begin0 (ns-since t0) (expect-full snap K))))
       (pin! #f)))))

;; Median restore ns after every actor has diverged: snapshot the pre-divergence
;; state, `become` each actor, then time rebuilding a live actormap from the
;; snapshot (`hasheq->whactormap` iterates a strong hash).
(define (median-restore K M)
  (with-retry
   (lambda ()
     (define-values (am refs) (build-blob K M))
     (pin! refs)
     (define snap (expect-full (snapshot-whactormap am) K))
     (for ([rf (in-list refs)]) (actormap-poke! am rf 'touch))
     (begin0
       (median (for/list ([_ (in-range samples)])
                 (define t0 (ms))
                 (define restored (hasheq->whactormap snap))
                 (begin0 (ns-since t0) (void restored))))
       (pin! #f)))))

;; Per-actor divergence (ns/actor): with a snapshot outstanding, `become` every
;; actor's N-entry hash to a path-copied version.
(define (time-diverge K N)
  (with-retry
   (lambda ()
     (define-values (am refs) (build-pmap K N))
     (pin! refs)
     (define snap (expect-full (snapshot-whactormap am) K))
     (define t0 (ms))
     (for ([rf (in-list refs)]) (actormap-poke! am rf 'touch 0 1))
     (begin0 (/ (ns-since t0) (max K 1)) (begin (void snap) (pin! #f))))))

(define samples (if smoke? 3 25))
(define k-sweep (if smoke? '(16 64) '(64 256 1024 4096)))
(define m-sweep (if smoke? '(64 1024) '(64 1024 16384)))
(define n-sweep (if smoke? '(64 1024) '(64 1024 16384)))
(define fixed-m 256)
(define fixed-k (if smoke? 64 1024))
(define diverge-k (if smoke? 32 256))

;; Warmup: Goblins is Racket/Chez, so the first turns pay JIT and heap-growth
;; costs. Run each path off the clock, then settle GC, so the measured medians
;; are steady state — the same hygiene the wire suite applies.
(unless smoke?
  (for ([_ (in-range 5)])
    (median-snapshot 256 256)
    (median-restore 256 256)
    (time-diverge 256 256))
  (collect-garbage)
  (collect-garbage))

(define (med thunk) (median (for/list ([_ (in-range samples)]) (thunk))))

(for ([k (in-list k-sweep)])
  (define snap-ns (median-snapshot k fixed-m))
  (define rest-ns (median-restore k fixed-m))
  (printf "goblins_snapshot_by_objects k=~a m=~a snapshot_ns=~a ns_per_object=~a restore_ns=~a\n"
          k fixed-m (r snap-ns) (r (/ snap-ns (max k 1))) (r rest-ns)))
(for ([m (in-list m-sweep)])
  (define snap-ns (median-snapshot fixed-k m))
  (printf "goblins_snapshot_by_bytes k=~a m=~a snapshot_ns=~a ns_per_object=~a\n"
          fixed-k m (r snap-ns) (r (/ snap-ns (max fixed-k 1)))))
(for ([n (in-list n-sweep)])
  (define d-ns (med (lambda () (time-diverge diverge-k n))))
  (printf "goblins_diverge n=~a k=~a become_ns=~a\n" n diverge-k (r d-ns)))
