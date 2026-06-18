#lang racket/base
;; Pure-parser checks for site_report.rkt. Run with:
;;   racket bench/site_report-test.rkt
;; No benches run here — the fixtures are captured ReleaseFast output, so the
;; parsers work without a build. Exit code is nonzero on any failure.
(require rackunit rackunit/text-ui (file "site_report.rkt"))

(define codec-out
  (string-append
   "encode codec=syrup iters=200000 frame_bytes=70 ns_per_op=133.7 mb_per_sec=524 mode=ReleaseFast\n"
   "decode codec=syrup iters=200000 frame_bytes=70 ns_per_op=93.0 mb_per_sec=752 mode=ReleaseFast\n"
   "encode codec=capnp iters=200000 frame_bytes=264 ns_per_op=173.1 mb_per_sec=1525 mode=ReleaseFast\n"
   "decode codec=capnp iters=200000 frame_bytes=264 ns_per_op=58.3 mb_per_sec=4531 mode=ReleaseFast\n"
   "dispatch turns=50000 ns_per_turn=179.1 turns_per_sec=5582434\n"
   "sparse_export_table inserts=100000 ns_per_insert=37.4\n"))

(define fv-out
  (string-append
   "frame_view iterations=1000000 bytes=27 checksum=27000000\n"
   "model_layout Argument=88 Message=208 Reference=80 Resolution=96\n"
   "wire_path turns=1024 total_allocs=1024 per_turn=1\n"))

(define peer-out
  (string-append
   "peer_scaling scenario=idle sample=2000 inline_struct_bytes=728 heap_per_peer_bytes=0.0 bytes_per_conn=728.0 mem_at_500k_gib=0.339\n"
   "peer_scaling scenario=warmed sample=2000 inline_struct_bytes=728 heap_per_peer_bytes=608.0 bytes_per_conn=1336.0 mem_at_500k_gib=0.622\n"
   "peer_scaling scenario=active16 sample=2000 inline_struct_bytes=728 heap_per_peer_bytes=1016.0 bytes_per_conn=1744.0 mem_at_500k_gib=0.812\n"))

(define goblins-md
  (apply string-append
         "| suite | backend | p50 | p99 | p999 | rps | conn | per_conn |\n"
         (for/list ([s '("echo" "registry" "mint" "taskboard")] [g '(0.36 0.66 0.73 1.35)] [gr '(2077 1176 1145 614)]
                    [p '(0.06 0.12 0.11 0.23)] [pr '(15117 8118 8205 2430)]
                    [t '(0.07 0.13 0.12 0.24)] [tr '(13900 7600 7900 2300)])
           (format (string-append "| ~a | goblins | ~a | 2.0 | 6.0 | ~a | 3.7 | 2.2 |\n"
                                   "| ~a | pancake | ~a | 0.3 | 0.5 | ~a | 7.0 | 4.0 |\n"
                                   "| ~a | pancake-tt | ~a | 0.3 | 0.5 | ~a | 7.0 | 5.0 |\n")
                   s g gr s p pr s t tr))))

(define snap-out
  (string-append
   "snapshot_by_objects k=64 m=256 snapshot_ns=1125 ns_per_object=17.6 restore_ns=2292\n"
   "snapshot_by_objects k=256 m=256 snapshot_ns=5500 ns_per_object=21.5 restore_ns=10250\n"
   "snapshot_by_bytes k=1024 m=64 snapshot_ns=23459 ns_per_object=22.9\n"
   "snapshot_by_bytes k=1024 m=16384 snapshot_ns=26375 ns_per_object=25.8\n"))

(define gsnap-out
  (string-append
   "goblins_snapshot_by_objects k=64 m=256 snapshot_ns=7750 ns_per_object=121 restore_ns=3667\n"
   "goblins_snapshot_by_objects k=256 m=256 snapshot_ns=37750 ns_per_object=147 restore_ns=13500\n"
   "goblins_snapshot_by_bytes k=1024 m=64 snapshot_ns=171625 ns_per_object=168\n"
   "goblins_snapshot_by_bytes k=1024 m=16384 snapshot_ns=167041 ns_per_object=163\n"))

(define iroh-out
  (string-append
   "roundtrip transport=tcp calls=3000 warmup=300 p50_ns=43750 p99_ns=79084 mean_ns=44977 rps=22234 mode=ReleaseFast\n"
   "roundtrip transport=iroh calls=3000 warmup=300 p50_ns=155209 p99_ns=251958 mean_ns=158251 rps=6319 mode=ReleaseFast\n"))

(define langs-md
  (string-append
   "| client | runtime | p50 ms | p99 ms | p999 ms | mean ms | req/s | setup ms/conn | mem kB/conn | cold ms |\n"
   "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |\n"
   "| zig | native-zig | 0.76 | 0.91 | 0.91 | 0.80 | 1262 | 4.91 | 144.0 | 15.47 |\n"
   "| python | cpython/3.13.5 | 0.69 | 1.09 | 1.09 | 0.71 | 1513 | 7.09 | 6.0 | 45.40 |\n"
   "| goblins-ref | racket-cs/goblins | 1.33 | 2.56 | 2.56 | 1.48 | 768 | 8.93 | 34.0 | 394.88 |\n"))

(define suite
  (test-suite "site_report parsers + renderers"
    (test-case "codec"
      (define c (parse-codec codec-out))
      (check-equal? (length (hash-ref c 'rows)) 4)
      (check-equal? (hash-ref c 'dispatch_tps) 5582434)
      (check-equal? (hash-ref c 'sparse_ns) 37.4)
      (check-equal? (car (hash-ref c 'rows)) (list "encode" "syrup" 70 133.7 524))
      (check-true (regexp-match? #px"<svg" (codec-region c))))
    (test-case "frame-view"
      (define fv (parse-frameview fv-out))
      (check-equal? (hash-ref fv 'per_turn) 1)
      (check-equal? (hash-ref fv 'arg) 88)
      (check-equal? (hash-ref fv 'msg) 208)
      (check-equal? (hash-ref fv 'iters) 1000000)
      (check-true (regexp-match? #px"<table" (frameview-region fv))))
    (test-case "peer-scaling"
      (define rows (parse-peer peer-out))
      (check-equal? (length rows) 3)
      (check-equal? (car rows) (list "idle" 728.0 0.339))
      (check-equal? (caddr rows) (list "active16" 1744.0 0.812))
      (check-false (regexp-match? #px"```" (peer-region rows))))
    (test-case "goblins"
      (define g (parse-goblins-md goblins-md))
      (check-equal? (car (hash-ref (hash-ref g "echo") 'goblins)) 0.36)
      (check-equal? (cdr (hash-ref (hash-ref g "echo") 'goblins)) 2077)
      (check-equal? (cdr (hash-ref (hash-ref g "taskboard") 'pancake)) 2430)
      ;; The third series — pancake with time-travel on for all actors — parses
      ;; (the longer backend name must not be swallowed by the `pancake` prefix).
      (check-equal? (car (hash-ref (hash-ref g "echo") 'pancake-tt)) 0.07)
      (check-equal? (cdr (hash-ref (hash-ref g "taskboard") 'pancake-tt)) 2300)
      (define region (goblins-region g))
      (check-true (regexp-match? #px"bench-legend" region))
      (check-true (regexp-match? #px"pancake binding \\+ time-travel" region))
      (check-true (regexp-match? #px"pancake \\+tt p50" region)))
    (test-case "snapshot"
      (define p (parse-snapshot snap-out))
      (define g (parse-goblins-snapshot gsnap-out))
      (check-equal? (length (hash-ref p 'by_objects)) 2)
      (check-equal? (car (hash-ref p 'by_objects)) (list 64 1125 2292))
      (check-equal? (car (hash-ref g 'by_objects)) (list 64 7750 3667))
      (define region (snapshot-region p g))
      ;; Snapshot and restore stay; the divergence chart and its mutable-vs-
      ;; persistent vocabulary were pulled off the public page — that detail
      ;; lives only in the benchmark programs' own .md reports now.
      (check-true (regexp-match? #px"Snapshot — µs" region))
      (check-false (regexp-match? #px"Divergence|pancake mutable|pancake persistent|entries / actor" region)))
    (test-case "iroh"
      (define h (parse-iroh iroh-out))
      (check-equal? (hash-ref (hash-ref h "tcp") 'p50) 43750)
      (check-equal? (hash-ref (hash-ref h "iroh") 'p50) 155209)
      (check-equal? (hash-ref (hash-ref h "iroh") 'rps) 6319)
      (define region (iroh-region h))
      (check-true (regexp-match? #px"encrypted QUIC" region))
      (check-true (regexp-match? #px"round-trips / s" region))
      ;; latency renders in µs: 155209 ns -> 155.2 µs.
      (check-true (regexp-match? #px"155.2" region)))
    (test-case "langs"
      (define rows (parse-langs-md langs-md))
      ;; Three data rows; the header separator (`| --- | ...`) must not parse.
      (check-equal? (length rows) 3)
      (check-equal? (car rows) (list "zig" "native-zig" 0.76 1262 "4.91" "144.0" 15.47))
      (check-equal? (list-ref (caddr rows) 0) "goblins-ref")
      (check-equal? (list-ref (caddr rows) 6) 394.88)
      (define region (langs-region rows))
      (check-true (regexp-match? #px"<svg" region))
      (check-true (regexp-match? #px"Cold start" region))
      (check-true (regexp-match? #px"goblins-ref" region))
      (check-true (regexp-match? #px"not a language race" region)))))

(exit (if (zero? (run-tests suite)) 0 1))
