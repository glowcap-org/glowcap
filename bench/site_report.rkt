#lang racket/base
;; Regenerate the benchmark reports on the performance page from live runs.
;;
;;   zig build bench-site-report   (needs racket + goblins)
;;
;; Runs every bench in ReleaseFast, parses its output, renders a compact
;; grouped-bar SVG (codec, peer-scaling, goblins) and/or an HTML value table
;; (all four), and splices each into site/content/performance.smd between
;; `<!-- bench:<name> -->` markers, the same "tool writes into a committed
;; file" pattern as gen-header. Surrounding prose is left untouched. There is no
;; stale-check: bench numbers vary by machine, so the page is a dated snapshot
;; you refresh on purpose, not a gated invariant.
;;
;; Parsers and renderers are pure and exercised by site_report-test.rkt; only
;; `main` runs benches and writes the file.
(require racket/string racket/list racket/format racket/system racket/port racket/file)

(provide parse-codec parse-frameview parse-peer parse-goblins-md parse-snapshot parse-goblins-snapshot parse-iroh
         parse-langs-md
         svg-bars legend html-table
         codec-region peer-region frameview-region goblins-region snapshot-region iroh-region langs-region)

;; ── Palette (site assets/style.css) ──────────────────────────────────────────
(define TEAL "#257f88")   ; Goblins / Syrup
(define AMBER "#c76f18")  ; pancake / Cap'n Proto
(define GREEN "#4f8a5b")  ; pancake + time-travel (third goblins-compare series)
(define INK "#3a3027")
(define SOFT "#6b5d4d")

(define PERF "site/content/performance.smd")
(define REPORTS "zig-out/bench-reports")

;; ── Parsers (pure) ───────────────────────────────────────────────────────────
(define (n s) (and s (string->number s)))

;; codec: rows of (op codec frame-bytes ns/op MB/s), plus dispatch turns/s and
;; sparse-insert ns.
(define (parse-codec out)
  (define rows
    (for/list ([m (regexp-match* #px"(encode|decode) codec=(\\S+) iters=\\d+ frame_bytes=(\\d+) ns_per_op=([0-9.]+) mb_per_sec=(\\d+)"
                                 out #:match-select values)])
      (list (list-ref m 1) (list-ref m 2) (n (list-ref m 3)) (n (list-ref m 4)) (n (list-ref m 5)))))
  (define disp (regexp-match #px"dispatch turns=\\d+ ns_per_turn=[0-9.]+ turns_per_sec=(\\d+)" out))
  (define sparse (regexp-match #px"sparse_export_table inserts=\\d+ ns_per_insert=([0-9.]+)" out))
  (hash 'rows rows
        'dispatch_tps (and disp (n (list-ref disp 1)))
        'sparse_ns (and sparse (n (list-ref sparse 1)))))

;; codec cell lookup: op ∈ {"encode","decode"}, codec ∈ {"syrup","capnp"}.
(define (codec-cell c op codec field) ; field ∈ 'frame 'ns 'mbps
  (define row (findf (lambda (r) (and (string=? (car r) op) (string=? (cadr r) codec))) (hash-ref c 'rows)))
  (and row (list-ref row (case field [(frame) 2] [(ns) 3] [(mbps) 4]))))

(define (parse-frameview out)
  (define fv (regexp-match #px"frame_view iterations=(\\d+) bytes=(\\d+)" out))
  (define ml (regexp-match #px"model_layout Argument=(\\d+) Message=(\\d+) Reference=(\\d+) Resolution=(\\d+)" out))
  (define wp (regexp-match #px"wire_path turns=(\\d+) total_allocs=(\\d+) per_turn=(\\d+)" out))
  (hash 'iters (and fv (n (list-ref fv 1)))
        'arg (and ml (n (list-ref ml 1))) 'msg (and ml (n (list-ref ml 2)))
        'ref (and ml (n (list-ref ml 3))) 'res (and ml (n (list-ref ml 4)))
        'turns (and wp (n (list-ref wp 1))) 'per_turn (and wp (n (list-ref wp 3)))))

;; peer-scaling: list of (scenario bytes/conn gib@500k) in printed order.
(define (parse-peer out)
  (for/list ([m (regexp-match* #px"peer_scaling scenario=(\\S+) sample=\\d+ inline_struct_bytes=\\d+ heap_per_peer_bytes=[0-9.]+ bytes_per_conn=([0-9.]+) mem_at_500k_gib=([0-9.]+)"
                               out #:match-select values)])
    (list (list-ref m 1) (n (list-ref m 2)) (n (list-ref m 3)))))

;; iroh round-trip (bench/iroh_bench.zig): one `roundtrip` line per transport.
;; Returns transport -> (hash 'p50 'p99 'mean 'rps), all in the printed units
;; (latency ns, throughput round-trips/s).
(define (parse-iroh out)
  (define h (make-hash))
  (for ([m (regexp-match* #px"roundtrip transport=(\\S+) calls=\\d+ warmup=\\d+ p50_ns=(\\d+) p99_ns=(\\d+) mean_ns=(\\d+) rps=(\\d+)"
                          out #:match-select values)])
    (hash-set! h (list-ref m 1)
               (hash 'p50 (n (list-ref m 2)) 'p99 (n (list-ref m 3))
                     'mean (n (list-ref m 4)) 'rps (n (list-ref m 5)))))
  ;; The design-point line: aggregate round-trips/s with `conns` connections
  ;; multiplexed on one readiness loop (ADR-0057), stored beside the per-transport
  ;; serial entries.
  (let ([lm (regexp-match #px"loop transport=iroh conns=(\\d+) calls_each=\\d+ aggregate_rps=(\\d+)" out)])
    (when lm
      (hash-set! h 'loop_conns (n (list-ref lm 1)))
      (hash-set! h 'loop_rps (n (list-ref lm 2)))))
  h)

;; goblins: parsed from the suite's generated markdown table. Returns a hash
;; suite -> (hash 'goblins (cons p50 rps) 'pancake (cons p50 rps) 'pancake-tt (cons p50 rps)).
;; `pancake-tt` must precede `pancake` in the alternation so the longer backend
;; name wins; a bare `pancake` alternative would match its prefix and skip the row.
(define (parse-goblins-md md)
  (define h (make-hash))
  (for ([m (regexp-match* #px"\\| (\\S+) \\| (goblins|pancake-tt|pancake) \\| ([0-9.]+) \\| [0-9.]+ \\| [0-9.]+ \\| (\\d+) \\|"
                          md #:match-select values)])
    (define suite (list-ref m 1))
    (define cur (hash-ref h suite (lambda () (make-hash))))
    (hash-set! cur (string->symbol (list-ref m 2)) (cons (n (list-ref m 3)) (n (list-ref m 4))))
    (hash-set! h suite cur))
  h)

;; snapshot (pancake, bench/snapshot_bench.zig): the O(objects) and flat-in-bytes
;; sweeps. Each number is a median.
(define (parse-snapshot out)
  (define by-objects
    (for/list ([m (regexp-match* #px"snapshot_by_objects k=(\\d+) m=\\d+ snapshot_ns=(\\d+) ns_per_object=[0-9.]+ restore_ns=(\\d+)"
                                 out #:match-select values)])
      (list (n (list-ref m 1)) (n (list-ref m 2)) (n (list-ref m 3)))))
  (define by-bytes
    (for/list ([m (regexp-match* #px"snapshot_by_bytes k=\\d+ m=(\\d+) snapshot_ns=(\\d+) ns_per_object=[0-9.]+"
                                 out #:match-select values)])
      (list (n (list-ref m 1)) (n (list-ref m 2)))))
  (hash 'by_objects by-objects
        'by_bytes by-bytes))

;; snapshot (Goblins, bench/goblins/snapshot.rkt): the same sweeps over
;; snapshot-whactormap; ns/object is an integer there.
(define (parse-goblins-snapshot out)
  (define by-objects
    (for/list ([m (regexp-match* #px"goblins_snapshot_by_objects k=(\\d+) m=\\d+ snapshot_ns=(\\d+) ns_per_object=\\d+ restore_ns=(\\d+)"
                                 out #:match-select values)])
      (list (n (list-ref m 1)) (n (list-ref m 2)) (n (list-ref m 3)))))
  (define by-bytes
    (for/list ([m (regexp-match* #px"goblins_snapshot_by_bytes k=\\d+ m=(\\d+) snapshot_ns=(\\d+) ns_per_object=\\d+"
                                 out #:match-select values)])
      (list (n (list-ref m 1)) (n (list-ref m 2)))))
  (hash 'by_objects by-objects 'by_bytes by-bytes))

;; langs (per-language consumer cost): parsed from the langs bench's generated
;; markdown table. Returns an ordered list of (client runtime p50 rps setup mem
;; cold) rows, in roster order. The header separator row never matches because
;; the client column must begin with a letter, not a dash.
(define (parse-langs-md md)
  (for/list ([m (regexp-match* #px"\\| ([a-z][\\w-]*) \\| (\\S+) \\| ([0-9.]+) \\| [0-9.]+ \\| [0-9.]+ \\| [0-9.]+ \\| (\\d+) \\| ([0-9.-]+) \\| ([0-9.-]+) \\| ([0-9.]+) \\|"
                               md #:match-select values)])
    (list (list-ref m 1) (list-ref m 2)
          (n (list-ref m 3)) (n (list-ref m 4))
          (list-ref m 5) (list-ref m 6) (n (list-ref m 7)))))

;; ── Rendering (pure) ─────────────────────────────────────────────────────────
(define (r1 x) (~r (exact->inexact x) #:precision 1))
(define (commas v) (~r v #:precision 0 #:groups '(3) #:group-sep ","))

;; Compact grouped-bar SVG. groups: (listof string). series: (listof (list name
;; color (listof real))), each values list aligned with groups. fmt: real->string
;; for the per-bar label.
;; bar-colors, when given, is a per-group color list that overrides the series
;; color, used for single-series charts where each bar (not each series) needs
;; its own hue, e.g. tinting the Goblins reference row apart from the languages.
(define (svg-bars groups series fmt #:bar-colors [bar-colors #f])
  (define W 380) (define H 210)
  (define padL 6) (define padR 6) (define padT 18) (define padB 26)
  (define base (- H padB)) (define top padT)
  (define ph (- base top)) (define pw (- W padL padR))
  (define ng (length groups)) (define k (length series))
  (define gw (/ pw ng))
  (define barw (/ (* gw 0.72) k))
  (define gap 3)
  (define clusterw (+ (* k barw) (* (- k 1) gap)))
  (define maxv (apply max 0.0001 (append* (map caddr series))))
  (define o (open-output-string))
  (define (p . xs) (for ([x (in-list xs)]) (display x o)) (newline o))
  (p "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 " W " " H "\" font-family=\"system-ui,-apple-system,sans-serif\" role=\"img\">")
  (p "<line x1=\"" padL "\" y1=\"" base "\" x2=\"" (- W padR) "\" y2=\"" base "\" stroke=\"" INK "\" stroke-width=\"1.2\"/>")
  (for ([g (in-list groups)] [i (in-naturals)])
    (define cx (+ padL (* gw (+ i 0.5))))
    (define startx (- cx (/ clusterw 2)))
    (for ([s (in-list series)] [j (in-naturals)])
      (define v (list-ref (caddr s) i))
      (define bx (+ startx (* j (+ barw gap))))
      (define bh (* (/ v maxv) ph))
      (define by (- base bh))
      (define fill (if bar-colors (list-ref bar-colors i) (cadr s)))
      (p "<rect x=\"" (r1 bx) "\" y=\"" (r1 by) "\" width=\"" (r1 barw) "\" height=\"" (r1 bh) "\" fill=\"" fill "\" rx=\"2\"/>")
      (p "<text x=\"" (r1 (+ bx (/ barw 2))) "\" y=\"" (r1 (- by 3)) "\" text-anchor=\"middle\" font-size=\"9.5\" fill=\"" INK "\">" (fmt v) "</text>"))
    (p "<text x=\"" (r1 cx) "\" y=\"" (+ base 16) "\" text-anchor=\"middle\" font-size=\"11\" fill=\"" SOFT "\">" g "</text>"))
  (p "</svg>")
  (get-output-string o))

(define (legend . pairs) ; pairs: (list name color) ...
  (string-append
   "<div class=\"bench-legend\">"
   (apply string-append (for/list ([pr (in-list pairs)]) (format "<span><i style=\"background:~a\"></i>~a</span>" (cadr pr) (car pr))))
   "</div>"))

(define (html-table headers rows)
  (string-append
   "<table>\n<tr>" (apply string-append (map (lambda (h) (format "<th>~a</th>" h)) headers)) "</tr>\n"
   (apply string-append
          (for/list ([row (in-list rows)])
            (string-append "<tr>" (apply string-append (map (lambda (c) (format "<td>~a</td>" c)) row)) "</tr>\n")))
   "</table>"))

(define (figure caption svg) (string-append "<figure>\n<figcaption><strong>" caption "</strong></figcaption>\n" svg "\n</figure>"))
(define (charts . figs) (string-append "<div class=\"bench-charts\">\n" (string-join figs "\n") "\n</div>"))

;; ── Per-bench regions (body inside the =html block) ──────────────────────────
(define (codec-region c)
  (define (cell op cd f) (codec-cell c op cd f))
  (define svg (svg-bars '("encode" "decode")
                        (list (list "Syrup" TEAL (list (cell "encode" "syrup" 'ns) (cell "decode" "syrup" 'ns)))
                              (list "Cap'n Proto" AMBER (list (cell "encode" "capnp" 'ns) (cell "decode" "capnp" 'ns))))
                        (lambda (v) (~r v #:precision 0))))
  (string-append
   (legend (list "Syrup" TEAL) (list "Cap'n Proto" AMBER))
   (charts (figure "Encode / decode, nanoseconds per message, lower is better." svg))
   (html-table '("codec" "encode ns/op" "decode ns/op" "encode MB/s" "decode MB/s" "frame bytes")
               (list (list "Syrup" (r1 (cell "encode" "syrup" 'ns)) (r1 (cell "decode" "syrup" 'ns))
                           (commas (cell "encode" "syrup" 'mbps)) (commas (cell "decode" "syrup" 'mbps)) (cell "encode" "syrup" 'frame))
                     (list "Cap'n Proto" (r1 (cell "encode" "capnp" 'ns)) (r1 (cell "decode" "capnp" 'ns))
                           (commas (cell "encode" "capnp" 'mbps)) (commas (cell "decode" "capnp" 'mbps)) (cell "encode" "capnp" 'frame))))
   (format "\n<p class=\"bench-note\">Sans-io inbound dispatch, engine only with no sockets: ~a turns/s. Sparse export-table insert: ~a ns.</p>"
           (commas (hash-ref c 'dispatch_tps)) (r1 (hash-ref c 'sparse_ns)))))

(define (peer-region rows)
  (define svg (svg-bars (map car rows)
                        (list (list "bytes / connection" TEAL (map cadr rows)))
                        (lambda (v) (~r v #:precision 0))))
  (string-append
   (charts (figure "Protocol-core bytes per connection, inline state plus heap, lower is better." svg))
   (html-table '("connection state" "bytes / connection" "at 500k connections")
               (for/list ([row (in-list rows)])
                 (list (car row) (commas (cadr row)) (format "~a GiB" (~r (caddr row) #:precision 2)))))))

;; iroh vs TCP round-trip: latency (p50/p99 µs) and throughput (round-trips/s),
;; the encrypted QUIC path beside the cleartext TCP baseline on one machine.
(define (iroh-region h)
  (define (g t k) (hash-ref (hash-ref h t) k))
  (define (us ns) (/ ns 1000.0))
  (define loop-rps (hash-ref h 'loop_rps #f))
  (define loop-conns (hash-ref h 'loop_conns #f))
  (define lat (svg-bars '("p50" "p99")
                        (list (list "TCP" TEAL (list (us (g "tcp" 'p50)) (us (g "tcp" 'p99))))
                              (list "iroh" AMBER (list (us (g "iroh" 'p50)) (us (g "iroh" 'p99)))))
                        (lambda (v) (~r v #:precision 1))))
  (define tput (svg-bars '("round-trips / s")
                         (list (list "TCP" TEAL (list (g "tcp" 'rps)))
                               (list "iroh" AMBER (list (g "iroh" 'rps))))
                         (lambda (v) (~r v #:precision 0))))
  ;; iroh against itself: the single-stream serial reciprocal vs the aggregate
  ;; throughput when one readiness loop multiplexes many connections — its design
  ;; point. Not a TCP comparison (the loop is iroh's serving model; the bars are
  ;; both iroh), so the serial number reads as latency-bound, not a ceiling.
  (define loop-fig
    (and loop-rps
         (figure
          (format "iroh throughput — one stream vs ~a connections on one readiness loop, round-trips/s, higher is better." loop-conns)
          (svg-bars (list "single stream" (format "~a conns · one loop" loop-conns))
                    (list (list "iroh" AMBER (list (g "iroh" 'rps) loop-rps)))
                    (lambda (v) (~r v #:precision 0))))))
  (string-append
   (legend (list "TCP (cleartext baseline)" TEAL) (list "iroh (encrypted QUIC)" AMBER))
   (charts
    (figure "Round-trip latency — µs, lower is better." lat)
    (figure "Throughput — round-trips/s, higher is better." tput))
   (if loop-fig
       (string-append
        "\n<p class=\"bench-note\">The chart below is iroh against itself, not the TCP baseline: the serial single stream above — one call in flight — beside iroh's own serving model, many connections multiplexed on one readiness loop. Both bars are iroh.</p>"
        (charts loop-fig))
       "")
   (html-table '("transport" "p50 latency (µs)" "p99 latency (µs)" "round-trips / s")
               (append
                (list (list "TCP (cleartext)" (r1 (us (g "tcp" 'p50))) (r1 (us (g "tcp" 'p99))) (commas (g "tcp" 'rps)))
                      (list "iroh (encrypted, single stream)" (r1 (us (g "iroh" 'p50))) (r1 (us (g "iroh" 'p99))) (commas (g "iroh" 'rps))))
                (if loop-rps
                    (list (list (format "iroh (encrypted, ~a conns / one loop)" loop-conns) "—" "—" (commas loop-rps)))
                    '())))))

(define (frameview-region fv)
  (html-table '("metric" "value")
              (list (list "Allocations per delivered turn" (format "~a (gated <code>== 1</code>)" (hash-ref fv 'per_turn)))
                    (list "Frame-view projections exercised" (commas (hash-ref fv 'iters)))
                    (list "Argument / Message struct bytes" (format "~a / ~a" (hash-ref fv 'arg) (hash-ref fv 'msg)))
                    (list "Reference / Resolution struct bytes" (format "~a / ~a" (hash-ref fv 'ref) (hash-ref fv 'res))))))

(define (goblins-region g)
  (define suites '("echo" "registry" "mint" "taskboard"))
  (define (val suite backend sel) (sel (hash-ref (hash-ref g suite) backend)))
  ;; Three series: Goblins, the pancake binding, and the pancake binding with
  ;; time-travel on for every actor (GREEN), measured the same way over the wire.
  (define lat (svg-bars suites
                        (list (list "Goblins" TEAL (for/list ([s suites]) (val s 'goblins car)))
                              (list "pancake" AMBER (for/list ([s suites]) (val s 'pancake car)))
                              (list "pancake + time-travel" GREEN (for/list ([s suites]) (val s 'pancake-tt car))))
                        (lambda (v) (~r v #:precision 2))))
  (define tput (svg-bars suites
                         (list (list "Goblins" TEAL (for/list ([s suites]) (val s 'goblins cdr)))
                               (list "pancake" AMBER (for/list ([s suites]) (val s 'pancake cdr)))
                               (list "pancake + time-travel" GREEN (for/list ([s suites]) (val s 'pancake-tt cdr))))
                         (lambda (v) (~r v #:precision 0))))
  (string-append
   (legend (list "Goblins" TEAL) (list "pancake binding" AMBER) (list "pancake binding + time-travel" GREEN))
   (charts (figure "Latency — p50 ms, lower is better." lat)
           (figure "Throughput — req/s, higher is better." tput))
   (html-table '("suite" "Goblins p50 (ms)" "pancake p50 (ms)" "pancake +tt p50 (ms)"
                 "Goblins req/s" "pancake req/s" "pancake +tt req/s")
               (for/list ([s suites])
                 (list s (~r (val s 'goblins car) #:precision 2) (~r (val s 'pancake car) #:precision 2)
                       (~r (val s 'pancake-tt car) #:precision 2)
                       (commas (val s 'goblins cdr)) (commas (val s 'pancake cdr))
                       (commas (val s 'pancake-tt cdr)))))))

;; snapshot / restore comparison. p = pancake hash, g = goblins hash. Rows align
;; by index across both. Snapshot and restore are shown in microseconds by actor
;; count. Measured natively (pancake Zig, Goblins Racket), so the bars show the
;; *shape* of each cost, not a cross-runtime speed race: both runtimes snapshot
;; in O(objects) and flat in object size.
(define (snapshot-region p g)
  (define (us ns) (/ ns 1000.0))
  (define p-obj (hash-ref p 'by_objects))
  (define g-obj (hash-ref g 'by_objects))
  (define p-bytes (hash-ref p 'by_bytes))
  (define snap-svg
    (svg-bars (for/list ([row (in-list p-obj)]) (number->string (car row)))
              (list (list "Goblins" TEAL (for/list ([row (in-list g-obj)]) (us (cadr row))))
                    (list "pancake" AMBER (for/list ([row (in-list p-obj)]) (us (cadr row)))))
              (lambda (v) (~r v #:precision 1))))
  (define restore-svg
    (svg-bars (for/list ([row (in-list p-obj)]) (number->string (car row)))
              (list (list "Goblins" TEAL (for/list ([row (in-list g-obj)]) (us (caddr row))))
                    (list "pancake" AMBER (for/list ([row (in-list p-obj)]) (us (caddr row)))))
              (lambda (v) (~r v #:precision 1))))
  (define small (first p-bytes))
  (define big (last p-bytes))
  (string-append
   (legend (list "Goblins" TEAL) (list "pancake" AMBER))
   (charts (figure "Snapshot — µs by actor count." snap-svg)
           (figure "Restore — µs by actor count." restore-svg))
   (html-table '("actors" "pancake snapshot µs" "Goblins snapshot µs" "pancake restore µs" "Goblins restore µs")
               (for/list ([pr (in-list p-obj)] [gr (in-list g-obj)])
                 (list (car pr) (r1 (us (cadr pr))) (r1 (us (cadr gr))) (r1 (us (caddr pr))) (r1 (us (caddr gr))))))
   (format "\n<p class=\"bench-note\">Both runtimes snapshot in O(objects) and stay flat as each actor grows larger (~a µs for ~a-byte actors, ~a µs for ~a-byte actors) — they share each actor's state instead of copying it. These run natively (pancake in Zig, Goblins in Racket), so the absolute nanoseconds reflect the runtime, not a better algorithm; read the shape, not the race. On restore, pancake frees the rewound copies right away; Goblins leaves that cleanup to its garbage collector.</p>"
           (r1 (us (cadr small))) (car small)
           (r1 (us (cadr big))) (car big))))

;; Per-language consumer cost: one bar per client for latency p50, throughput,
;; and cold start, plus the full value table. The Goblins reference row keeps the
;; substrate bench's teal; the language rows take amber so a reader does not read
;; the reference as just another language.
(define (langs-region rows)
  (if (null? rows)
      "<p class=\"bench-note\">No client rows in this run.</p>"
      (langs-region* rows)))

(define (langs-region* rows)
  (define clients (map car rows))
  (define bar-colors (map (lambda (c) (if (string=? c "goblins-ref") TEAL AMBER)) clients))
  (define (series sel) (list (list "value" AMBER (map sel rows))))
  (define p50-svg (svg-bars clients (series (lambda (r) (or (list-ref r 2) 0))) (lambda (v) (~r v #:precision 2)) #:bar-colors bar-colors))
  (define rps-svg (svg-bars clients (series (lambda (r) (or (list-ref r 3) 0))) (lambda (v) (~r v #:precision 0)) #:bar-colors bar-colors))
  (define cold-svg (svg-bars clients (series (lambda (r) (or (list-ref r 6) 0))) (lambda (v) (~r v #:precision 1)) #:bar-colors bar-colors))
  (string-append
   (legend (list "language client" AMBER) (list "Goblins reference (CapTP peer)" TEAL))
   (charts (figure "Latency — p50 ms, lower is better." p50-svg)
           (figure "Throughput — req/s, higher is better." rps-svg)
           (figure "Cold start — ms from spawn to first settled call, lower is better." cold-svg))
   (html-table '("client" "runtime" "p50 (ms)" "req/s" "setup (ms/conn)" "mem (kB/conn)" "cold (ms)")
               (for/list ([r (in-list rows)])
                 (list (car r) (list-ref r 1)
                       (~r (or (list-ref r 2) 0) #:precision 2) (commas (or (list-ref r 3) 0))
                       (list-ref r 4) (list-ref r 5) (~r (or (list-ref r 6) 0) #:precision 1))))
   "\n<p class=\"bench-note\">Each row is a whole consumer stack — runtime, binding, the app rewritten in that language, and its garbage collector — over one native Zig host. Read it as consumer cost, not a language race; the Goblins row is the reference CapTP implementation dialing in, not a pancake binding.</p>"))

;; ── Run + splice (effectful) ─────────────────────────────────────────────────
;; `system` returns #f on a non-zero exit without raising; check it so a failed
;; bench cannot leave the page half-freshened with a stale goblins/langs report.
;; CapTP flake retries live in `bench/goblins/bench.rkt`, not here.
(define (run cmd)
  (printf "  $ ~a\n" cmd) (flush-output)
  (define out (open-output-string))
  (define ok (parameterize ([current-output-port out]
                            [current-error-port out])
               (system cmd)))
  (define text (get-output-string out))
  (display text)
  (unless ok (error 'site-report "command failed: ~a" cmd))
  text)

(define (sh1 cmd) (string-trim (with-output-to-string (lambda () (system cmd)))))

(define (latest-goblins-md)
  (define files (filter (lambda (f) (regexp-match? #px"^goblins-compare-\\d+\\.md$" (path->string f)))
                        (directory-list REPORTS)))
  (when (null? files) (error 'site-report "no goblins-compare-*.md under ~a" REPORTS))
  (file->string (build-path REPORTS (last (sort files string<? #:key path->string)))))

(define (latest-langs-md)
  (define files (filter (lambda (f) (regexp-match? #px"^langs-compare-\\d+\\.md$" (path->string f)))
                        (directory-list REPORTS)))
  (when (null? files) (error 'site-report "no langs-compare-*.md under ~a" REPORTS))
  (file->string (build-path REPORTS (last (sort files string<? #:key path->string)))))

(define (stamp-region)
  (define mem-kb (n (cadr (regexp-match #px"MemTotal:\\s+(\\d+)" (file->string "/proc/meminfo")))))
  (define gib (~r (/ mem-kb 1048576.0) #:precision 0))
  (define goblins-v
    (let ([m (regexp-match #px"GOBLINS_VERSION=\"([^\"]+)\"" (file->string ".devcontainer/pins.sh"))])
      (if m (list-ref m 1) "unknown")))
  (define racket-v
    (let ([m (regexp-match #px"v([0-9.]+) \\[(\\w+)\\]" (sh1 "racket --version"))])
      (if m (format "Racket v~a ~a" (list-ref m 1) (string-upcase (list-ref m 2))) "Racket")))
  (format "<p class=\"bench-stamp\"><em>Measured ~a on one machine: ~a, ~a logical CPUs, ~a GiB RAM, ~a, Spritely Goblins v~a, with the <code>pancake</code> archives built by Zig ~a in ReleaseFast. Measure your own with the commands below.</em></p>"
          (sh1 "date +%Y-%m-%d") (sh1 "uname -srm") (sh1 "nproc") gib
          racket-v goblins-v (sh1 "zig version")))

;; Replace the body of the `=html` block tagged with the bench marker.
(define (splice text name body)
  (define pat (pregexp (string-append "(?s:```=html\n<!-- bench:" name " GENERATED[^\n]*-->.*?```)")))
  (define repl (string-append "```=html\n<!-- bench:" name " GENERATED by `zig build bench-site-report`; edits are overwritten -->\n" body "\n```"))
  (unless (regexp-match? pat text) (error 'site-report "marker not found in ~a: bench:~a" PERF name))
  (regexp-replace pat text (lambda _ repl)))

(module+ main
  (printf "running benches in ReleaseFast (this takes a few minutes)...\n") (flush-output)
  ;; Goblins first: fail fast on the CapTP step before burning ReleaseFast
  ;; minutes on the Zig benches. Retries for CapTP flakes are inside bench-goblins.
  (run "zig build bench-goblins 2>&1")
  (define goblins (parse-goblins-md (latest-goblins-md)))
  (define codec (parse-codec (run "zig build bench-codec -Doptimize=ReleaseFast 2>&1")))
  (define fv (parse-frameview (run "zig build bench-frame-view -Doptimize=ReleaseFast 2>&1")))
  (define peer (parse-peer (run "zig build bench-peer-scaling -Doptimize=ReleaseFast 2>&1")))
  (define snap-p (parse-snapshot (run "zig build bench-snapshot -Doptimize=ReleaseFast 2>&1")))
  (define snap-g (parse-goblins-snapshot (run "racket bench/goblins/snapshot.rkt 2>&1")))
  (define iroh (parse-iroh (run "zig build bench-iroh -Doptimize=ReleaseFast 2>&1")))
  (run "zig build bench-langs -Doptimize=ReleaseFast 2>&1")
  (define langs (parse-langs-md (latest-langs-md)))
  (printf "rendering + splicing into ~a...\n" PERF) (flush-output)
  (define text (file->string PERF))
  (define out
    (for/fold ([t text]) ([pair (in-list (list (cons "stamp" (stamp-region))
                                                (cons "codec" (codec-region codec))
                                                (cons "peer-scaling" (peer-region peer))
                                                (cons "frame-view" (frameview-region fv))
                                                (cons "goblins" (goblins-region goblins))
                                                (cons "langs" (langs-region langs))
                                                (cons "snapshot" (snapshot-region snap-p snap-g))
                                                (cons "iroh" (iroh-region iroh))))])
      (splice t (car pair) (cdr pair))))
  (call-with-output-file PERF (lambda (o) (display out o)) #:exists 'replace)
  (printf "done. validate with: zig build site\n"))
