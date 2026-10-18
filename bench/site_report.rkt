#lang racket/base
;; Regenerate the benchmark reports on the performance pages from live runs.
;;
;;   zig build bench-site-report   (needs racket + goblins)
;;
;; Runs every bench in ReleaseFast, parses its output, renders compact
;; grouped-bar SVGs and HTML value tables, and splices each into its page
;; between `<!-- bench:<name> -->` markers, the same "tool writes into a
;; committed file" pattern as gen-header. glowcap's own costs go to
;; site/content/performance.smd and the comparisons with Cap'n Proto RPC and
;; Goblins to site/content/performance/compared.smd, both stamped with the
;; same run. Surrounding prose is left untouched. There is no stale-check:
;; bench numbers vary by machine, so the pages are a dated snapshot you
;; refresh, not a gated invariant.
;;
;; Parsers and renderers are pure and exercised by site_report-test.rkt; only
;; `main` runs benches and writes the file.
(require racket/string racket/list racket/format racket/system racket/port racket/file "site_chart.rkt")

(provide parse-codec parse-frameview parse-peer parse-goblins-md parse-snapshot parse-goblins-snapshot parse-iroh
         parse-langs-md parse-loam
         svg-bars legend html-table thousands splice PERF COMPARED
         codec-region peer-region frameview-region goblins-region snapshot-region iroh-region langs-region loam-region
         capnp-rpc-region glance-region)

;; ── Palette (site assets/style.css) ──────────────────────────────────────────
;; Each colour is a custom property with a literal fallback. The charts are
;; emitted inline into the page, so they read the site's tokens directly and
;; follow the theme. The fallback is what the light theme resolves to anyway,
;; and it is also what renders if these are ever viewed outside the page.
(define TEAL "var(--teal, #257f88)")           ; Goblins / Syrup / Cap'n Proto C++ RPC
(define AMBER "var(--accent, #c76f18)")        ; glowcap / Cap'n Proto codec
(define GREEN "var(--dia-green, #4f8a5b)")     ; glowcap + time-travel, Cap'n Proto Rust (third series)
(define AMBER-DEEP "var(--dia-accent-deep, #a4560c)") ; glowcap under its Cap'n Proto codec, beside the AMBER Syrup bar

(define PERF "site/content/performance.smd")
(define COMPARED "site/content/performance/compared.smd")
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
  (define sparse (regexp-match #px"sparse_import_table inserts=\\d+ ns_per_insert=([0-9.]+)" out))
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

;; iroh round-trip (bench/iroh_bench.zig): one `roundtrip` line per row,
;; carrying `codec=` and `call=` after the transport. The key is the
;; transport, then `+codec` for a codec other than the default Syrup, then
;; `:call` for a call other than `greet`: `tcp`, `tcp+capnp`, `tcp:report`,
;; `tcp+capnp:report`. So the plain greet rows stay addressable by transport.
;; The Cap'n Proto echo benches (bench/capnp/) print the same line without a
;; codec, with `transport=capnp-cpp` or `transport=capnp-rust`, so this parses
;; them too. Returns key -> (hash 'p50 'p99 'mean 'rps), all in the printed
;; units (latency ns, throughput round-trips/s).
(define (parse-iroh out)
  (define h (make-hash))
  (for ([m (regexp-match* #px"roundtrip transport=(\\S+)(?: codec=(\\S+))?(?: call=(\\S+))? calls=\\d+ warmup=\\d+ p50_ns=(\\d+) p99_ns=(\\d+) mean_ns=(\\d+) rps=(\\d+)"
                          out #:match-select values)])
    (define codec (list-ref m 2))
    (define call (list-ref m 3))
    (define key (string-append (list-ref m 1)
                               (if (or (not codec) (equal? codec "syrup")) "" (string-append "+" codec))
                               (if (or (not call) (equal? call "greet")) "" (string-append ":" call))))
    (hash-set! h key
               (hash 'p50 (n (list-ref m 4)) 'p99 (n (list-ref m 5))
                     'mean (n (list-ref m 6)) 'rps (n (list-ref m 7)))))
  ;; The design-point line: aggregate round-trips/s with `conns` connections
  ;; multiplexed on one event loop (ADR-0057), stored beside the per-transport
  ;; serial entries.
  (let ([lm (regexp-match #px"loop transport=iroh conns=(\\d+) calls_each=\\d+ aggregate_rps=(\\d+)" out)])
    (when lm
      (hash-set! h 'loop_conns (n (list-ref lm 1)))
      (hash-set! h 'loop_rps (n (list-ref lm 2)))))
  h)

;; goblins: parsed from the suite's generated markdown table. Returns a hash
;; suite -> (hash 'goblins (cons p50 rps) 'glowcap (cons p50 rps) 'glowcap-tt (cons p50 rps)).
;; `glowcap-tt` must precede `glowcap` in the alternation so the longer backend
;; name wins; a bare `glowcap` alternative would match its prefix and skip the row.
(define (parse-goblins-md md)
  (define h (make-hash))
  (for ([m (regexp-match* #px"\\| (\\S+) \\| (goblins|glowcap-tt|glowcap) \\| ([0-9.]+) \\| [0-9.]+ \\| [0-9.]+ \\| (\\d+) \\|"
                          md #:match-select values)])
    (define suite (list-ref m 1))
    (define cur (hash-ref h suite (lambda () (make-hash))))
    (hash-set! cur (string->symbol (list-ref m 2)) (cons (n (list-ref m 3)) (n (list-ref m 4))))
    (hash-set! h suite cur))
  h)

;; snapshot (glowcap, bench/snapshot_bench.zig): the O(objects) and flat-in-bytes
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

;; loam (`bench-loam -- --ordinary-only`): one row per conversation count for
;; the 4,096-byte message graph, as (conversations hot cold edit restart
;; footprint). hot/cold/edit are (p50 p99) ns, restart is (reads ns), and
;; footprint is (record_bytes cold_zig_heap_bytes).
(define LOAM-MESSAGE-BYTES "4096")
(define (parse-loam out)
  (define (by-count rx sel)
    (for/hash ([m (regexp-match* (pregexp rx) out #:match-select values)])
      (values (n (list-ref m 1)) (sel m))))
  (define (latency phase)
    (by-count (string-append "(?m:^" phase " conversations=(\\d+) message_bytes=" LOAM-MESSAGE-BYTES " .* p50_ns=(\\d+) p99_ns=(\\d+)$)")
              (lambda (m) (list (n (list-ref m 2)) (n (list-ref m 3))))))
  (define hot (latency "hot"))
  (define cold (latency "cold"))
  (define edit (latency "edit"))
  (define restart
    (by-count (string-append "restart conversations=(\\d+) message_bytes=" LOAM-MESSAGE-BYTES " reads=(\\d+) elapsed_ns=(\\d+)")
              (lambda (m) (list (n (list-ref m 2)) (n (list-ref m 3))))))
  (define footprint
    (by-count (string-append "footprint conversations=(\\d+) message_bytes=" LOAM-MESSAGE-BYTES " objects=\\d+ record_bytes=(\\d+) cold_zig_heap_bytes=(\\d+)")
              (lambda (m) (list (n (list-ref m 2)) (n (list-ref m 3))))))
  (for/list ([c (in-list (sort (hash-keys restart) <))])
    (list c (hash-ref hot c) (hash-ref cold c) (hash-ref edit c) (hash-ref restart c) (hash-ref footprint c))))

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
;; Numbers and bar charts come from site_chart.rkt.
(define (legend . pairs) ; pairs: (list name color) ...
  (string-append
   "<div class=\"bench-legend\">"
   (apply string-append (for/list ([pr (in-list pairs)]) (format "<span><i style=\"background:~a\"></i>~a</span>" (cadr pr) (car pr))))
   "</div>"))

(define (html-table headers rows)
  (string-append
   "<table>\n<thead><tr>" (apply string-append (map (lambda (h) (format "<th>~a</th>" h)) headers)) "</tr></thead>\n<tbody>\n"
   (apply string-append
          (for/list ([row (in-list rows)])
            (string-append "<tr>" (apply string-append (map (lambda (c) (format "<td>~a</td>" c)) row)) "</tr>\n")))
   "</tbody></table>"))

;; The chart is role="img", and an image role with no accessible name is
;; announced as nothing, so the figure lends its caption to the svg as the
;; aria-label. Captions here are plain sentences with no attribute-breaking
;; characters.
(define (figure caption svg #:legend [pairs #f])
  (string-append "<figure>\n<figcaption><strong>" caption "</strong></figcaption>\n"
                 (if pairs (string-append (apply legend pairs) "\n") "")
                 (string-replace svg "role=\"img\">"
                                 (string-append "role=\"img\" aria-label=\"" caption "\">"))
                 "\n</figure>"))
(define (charts . figs) (string-append "<div class=\"bench-charts\">\n" (string-join figs "\n") "\n</div>"))

;; One chart beside what reads with it, a table or a note, so a lone figure
;; does not sit in the middle of an empty row. They stack on a narrow screen.
(define (panel fig beside)
  (string-append "<div class=\"bench-panel\">\n" fig "\n<div>\n" beside "\n</div>\n</div>"))

;; The page's opening row: one figure per card, each linking to the section
;; that measures it. Every figure is glowcap's own, so the comparisons stay
;; with the charts that draw them.
(define (glance-card anchor value label)
  (format "<a class=\"card bench-glance-card\" href=\"#~a\"><strong>~a</strong><span>~a</span></a>" anchor value label))

(define (glance-region codec fv peer iroh langs loam)
  (define idle (findf (lambda (row) (string=? (car row) "idle")) peer))
  (define zig (findf (lambda (row) (string=? (car row) "zig")) langs))
  (define big (last loam))
  (define per-turn (hash-ref fv 'per_turn))
  (string-append
   "<div class=\"bench-glance\">\n"
   (string-join
    (list
     (glance-card "frame-ownership-and-dispatch" per-turn
                  (format "allocation~a per delivered message" (if (= per-turn 1) "" "s")))
     (glance-card "codec-throughput" (format "~aM" (~r (/ (hash-ref codec 'dispatch_tps) 1e6) #:precision 1))
                  "messages a second through the protocol engine, without sockets")
     (glance-card "per-connection-footprint" (format "~a B" (commas (cadr idle)))
                  "of protocol state for each idle connection")
     (glance-card "encrypted-transport-round-trip" (commas (hash-ref iroh 'loop_rps))
                  (format "encrypted round trips a second over ~a iroh connections on one thread" (hash-ref iroh 'loop_conns)))
     (glance-card "cost-through-each-language-binding" (format "~a ms" (r1 (list-ref zig 6)))
                  "from starting the Zig client to its first finished task")
     (glance-card "persistent-actors-in-loam" (format "~a µs" (r1 (/ (car (list-ref big 2)) 1000.0)))
                  (format "to call an actor asleep in LMDB, among ~a" (commas (car big)))))
    "\n")
   "\n</div>"))

;; ── Per-bench regions (body inside the =html block) ──────────────────────────
(define (codec-region c)
  (define (cell op cd f) (codec-cell c op cd f))
  (define svg (svg-bars '("encode" "decode")
                        (list (list "Syrup" TEAL (list (cell "encode" "syrup" 'ns) (cell "decode" "syrup" 'ns)))
                              (list "Cap'n Proto" AMBER (list (cell "encode" "capnp" 'ns) (cell "decode" "capnp" 'ns))))
                        (lambda (v) (~r v #:precision 0))))
  (define (row label op f fmt) (list label (fmt (cell op "syrup" f)) (fmt (cell op "capnp" f))))
  (string-append
   (panel
    (figure "Nanoseconds per message, lower is better." svg
            #:legend (list (list "Syrup" TEAL) (list "Cap'n Proto" AMBER)))
    (html-table '("" "Syrup" "Cap'n Proto")
                (list (row "encode ns" "encode" 'ns r1)
                      (row "decode ns" "decode" 'ns r1)
                      (row "encode MB/s" "encode" 'mbps commas)
                      (row "decode MB/s" "decode" 'mbps commas)
                      (row "frame bytes" "encode" 'frame commas))))
   (format "\n<p class=\"bench-note\">The protocol engine alone, with no sockets, handles ~a inbound messages a second, and adds an entry to a sparse import table in ~a ns.</p>"
           (commas (hash-ref c 'dispatch_tps)) (r1 (hash-ref c 'sparse_ns)))))

(define (peer-region rows)
  (define svg (svg-bars (map car rows)
                        (list (list "bytes / connection" TEAL (map cadr rows)))
                        commas))
  (panel
   (figure "Protocol-core bytes per connection, inline state plus heap, lower is better." svg)
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
                         commas))
  ;; iroh against itself: the single-stream serial reciprocal vs the aggregate
  ;; throughput when one readiness loop multiplexes many connections (its design
  ;; point). Not a TCP comparison (the loop is iroh's serving model; the bars are
  ;; both iroh), so the serial number reads as latency-bound, not a ceiling.
  (define loop-fig
    (and loop-rps
         (figure
          (format "iroh round trips a second, one stream against ~a connections on one thread, higher is better." loop-conns)
          (svg-bars (list "one stream" (format "~a connections" loop-conns))
                    (list (list "iroh" AMBER (list (g "iroh" 'rps) loop-rps)))
                    commas))))
  (define table
    (html-table '("transport" "p50 µs" "p99 µs" "round trips / s")
                (append
                 (list (list "TCP (cleartext)" (r1 (us (g "tcp" 'p50))) (r1 (us (g "tcp" 'p99))) (commas (g "tcp" 'rps)))
                       (list "iroh, one stream" (r1 (us (g "iroh" 'p50))) (r1 (us (g "iroh" 'p99))) (commas (g "iroh" 'rps))))
                 (if loop-rps
                     (list (list (format "iroh, ~a connections on one thread" loop-conns) "—" "—" (commas loop-rps)))
                     '()))))
  (string-append
   (legend (list "TCP (cleartext baseline)" TEAL) (list "iroh (encrypted QUIC)" AMBER))
   (charts
    (figure "Round-trip latency (µs, lower is better)." lat)
    (figure "Throughput (round trips a second, higher is better)." tput))
   (if loop-fig
       (panel loop-fig
              (format "<p class=\"bench-note\">Both bars are iroh. One stream keeps one call in flight. Beside it, ~a connections share one thread, the way a server carries many peers at once.</p>" loop-conns))
       "")
   table))

;; glowcap's `tcp` calls, under its Syrup codec and under its Cap'n Proto
;; codec, beside the same calls in the Cap'n Proto C++ reference library and
;; the Rust crate: `greet`, the smallest call, and `report`, one application
;; batch. one-core and two-core are parse-iroh hashes from runs pinned both
;; threads to one core, then each thread to its own core.
(define (capnp-rpc-region one-core two-core)
  (define (us h t) (/ (hash-ref (hash-ref h t) 'p50) 1000.0))
  ;; A fixed tenth, so 10.0 does not print as 10 beside 10.7.
  (define (tenth v) (~r v #:precision '(= 1)))
  (define impls (list (list "Cap'n Proto C++" "capnp-cpp" TEAL)
                      (list "glowcap, Syrup" "tcp" AMBER)
                      (list "glowcap, Cap'n Proto codec" "tcp+capnp" AMBER-DEEP)
                      (list "Cap'n Proto Rust" "capnp-rust" GREEN)))
  (define (key i call) (if (equal? call "greet") (cadr i) (string-append (cadr i) ":" call)))
  (define (bars call)
    (svg-bars '("one core" "one core each")
              (for/list ([i (in-list impls)])
                (list (car i) (caddr i) (list (us one-core (key i call)) (us two-core (key i call)))))
              tenth))
  (define (cell h i call) (format "~a µs" (tenth (us h (key i call)))))
  (define (legend* impls) (apply legend (for/list ([i (in-list impls)]) (list (car i) (caddr i)))))
  (string-append
   (legend* impls)
   (charts
    (figure "greet: one small call round trip over loopback TCP, p50 µs, lower is better." (bars "greet"))
    (figure "report: one application batch (a name, eight tags, sixty-four readings) answered with its count and sum, p50 µs, lower is better." (bars "report")))
   (html-table '("" "greet, one core" "greet, one core each" "report, one core" "report, one core each")
               (for/list ([i (in-list impls)])
                 (list (car i) (cell one-core i "greet") (cell two-core i "greet") (cell one-core i "report") (cell two-core i "report"))))))

;; The two fastest cores by maximum clock, so a pinned run stays off the slow
;; cluster on a mixed-core machine. Falls back to cores 0 and 1.
(define (fast-cores)
  (define cpus
    (for*/list ([d (in-list (directory-list "/sys/devices/system/cpu"))]
                [m (in-value (regexp-match #px"^cpu(\\d+)$" (path->string d)))]
                #:when m
                [f (in-value (build-path "/sys/devices/system/cpu" d "cpufreq/cpuinfo_max_freq"))]
                #:when (file-exists? f))
      (cons (n (cadr m)) (n (string-trim (file->string f))))))
  (define fast (sort (sort cpus < #:key car) > #:key cdr))
  (if (>= (length fast) 2) (list (car (car fast)) (car (cadr fast))) (list 0 1)))

(define (frameview-region fv)
  (html-table '("metric" "value")
              (list (list "Allocations per delivered turn" (format "~a (build check requires <code>== 1</code>)" (hash-ref fv 'per_turn)))
                    (list "Frame-view projections exercised" (commas (hash-ref fv 'iters)))
                    (list "Argument / Message struct bytes" (format "~a / ~a" (hash-ref fv 'arg) (hash-ref fv 'msg)))
                    (list "Reference / Resolution struct bytes" (format "~a / ~a" (hash-ref fv 'ref) (hash-ref fv 'res))))))

(define (goblins-region g)
  (define suites '("echo" "registry" "mint" "taskboard"))
  (define (val suite backend sel) (sel (hash-ref (hash-ref g suite) backend)))
  ;; Three series: Goblins, the glowcap binding, and the glowcap binding with
  ;; time-travel on for every actor (GREEN), measured the same way over the wire.
  (define lat (svg-bars suites
                        (list (list "Goblins" TEAL (for/list ([s suites]) (val s 'goblins car)))
                              (list "glowcap" AMBER (for/list ([s suites]) (val s 'glowcap car)))
                              (list "glowcap + time-travel" GREEN (for/list ([s suites]) (val s 'glowcap-tt car))))
                        (lambda (v) (~r v #:precision 2))))
  (define tput (svg-bars suites
                         (list (list "Goblins" TEAL (for/list ([s suites]) (val s 'goblins cdr)))
                               (list "glowcap" AMBER (for/list ([s suites]) (val s 'glowcap cdr)))
                               (list "glowcap + time-travel" GREEN (for/list ([s suites]) (val s 'glowcap-tt cdr))))
                         thousands))
  (string-append
   (legend (list "Goblins" TEAL) (list "glowcap binding" AMBER) (list "glowcap binding + time-travel" GREEN))
   (charts (figure "Latency (p50 ms, lower is better)." lat)
           (figure "Throughput (req/s, higher is better)." tput))
   (html-table '("suite" "Goblins p50 (ms)" "glowcap p50 (ms)" "glowcap +tt p50 (ms)"
                 "Goblins req/s" "glowcap req/s" "glowcap +tt req/s")
               (for/list ([s suites])
                 (list s (~r (val s 'goblins car) #:precision 2) (~r (val s 'glowcap car) #:precision 2)
                       (~r (val s 'glowcap-tt car) #:precision 2)
                       (commas (val s 'goblins cdr)) (commas (val s 'glowcap cdr))
                       (commas (val s 'glowcap-tt cdr)))))))

;; snapshot / restore comparison. p = glowcap hash, g = goblins hash. Rows align
;; by index across both. Snapshot and restore are shown in microseconds by actor
;; count. Measured in each runtime (glowcap in Zig, Goblins in Racket), so absolute times are
;; not directly comparable. Both runtimes snapshot in O(objects) and stay flat
;; as object size grows.
(define (snapshot-region p g)
  (define (us ns) (/ ns 1000.0))
  (define p-obj (hash-ref p 'by_objects))
  (define g-obj (hash-ref g 'by_objects))
  (define p-bytes (hash-ref p 'by_bytes))
  (define snap-svg
    (svg-bars (for/list ([row (in-list p-obj)]) (number->string (car row)))
              (list (list "Goblins" TEAL (for/list ([row (in-list g-obj)]) (us (cadr row))))
                    (list "glowcap" AMBER (for/list ([row (in-list p-obj)]) (us (cadr row)))))
              (lambda (v) (~r v #:precision 1))))
  (define restore-svg
    (svg-bars (for/list ([row (in-list p-obj)]) (number->string (car row)))
              (list (list "Goblins" TEAL (for/list ([row (in-list g-obj)]) (us (caddr row))))
                    (list "glowcap" AMBER (for/list ([row (in-list p-obj)]) (us (caddr row)))))
              (lambda (v) (~r v #:precision 1))))
  (define small (first p-bytes))
  (define big (last p-bytes))
  (string-append
   (legend (list "Goblins" TEAL) (list "glowcap" AMBER))
   (charts (figure "Snapshot (µs by actor count)." snap-svg)
           (figure "Restore (µs by actor count)." restore-svg))
   (html-table '("actors" "glowcap snapshot µs" "Goblins snapshot µs" "glowcap restore µs" "Goblins restore µs")
               (for/list ([pr (in-list p-obj)] [gr (in-list g-obj)])
                 (list (car pr) (r1 (us (cadr pr))) (r1 (us (cadr gr))) (r1 (us (caddr pr))) (r1 (us (caddr gr))))))
   (format "\n<p class=\"bench-note\">Both runtimes snapshot in O(objects) and stay flat as each actor grows larger (~a µs for ~a-byte actors, ~a µs for ~a-byte actors). They share each actor's state instead of copying it. The runtimes differ, so their absolute times are not directly comparable. The shared O(objects) trend is the result. On restore, glowcap frees the rewound copies right away, and Goblins leaves that cleanup to its garbage collector.</p>"
           (r1 (us (cadr small))) (car small)
           (r1 (us (cadr big))) (car big))))

;; Loam: call latency awake and asleep, and what memory holds, by graph size,
;; then every figure in one table.
(define (loam-region rows)
  (define (us ns) (/ ns 1000.0))
  (define (mib b) (/ b 1048576.0))
  (define groups (for/list ([r (in-list rows)]) (commas (car r))))
  (define big (last rows))
  (define (col sel) (for/list ([r (in-list rows)]) (sel r)))
  (define latency-svg
    (svg-bars groups
              (list (list "awake" AMBER (col (lambda (r) (us (car (list-ref r 1))))))
                    (list "asleep" GREEN (col (lambda (r) (us (car (list-ref r 2)))))))
              (lambda (v) (~r v #:precision 1))))
  (define memory-svg
    (svg-bars groups
              (list (list "records on disk" TEAL (col (lambda (r) (mib (car (list-ref r 5))))))
                    (list "Zig heap" AMBER (col (lambda (r) (mib (cadr (list-ref r 5)))))))
              (lambda (v) (~r v #:precision 1))))
  (string-append
   (charts (figure "Call latency (p50 µs by conversation count)." latency-svg
                   #:legend (list (list "awake" AMBER) (list "asleep" GREEN)))
           (figure "Memory (MiB by conversation count, all actors asleep)." memory-svg
                   #:legend (list (list "records on disk" TEAL) (list "Zig heap" AMBER))))
   (html-table '("conversations" "awake call p50 µs" "asleep call p50 / p99 µs" "edit p50 / p99 ms" "restart to first call ms" "records read at restart")
               (for/list ([r (in-list rows)])
                 (define cold (list-ref r 2))
                 (define edit (list-ref r 3))
                 (define restart (list-ref r 4))
                 (list (commas (car r)) (r1 (us (car (list-ref r 1))))
                       (format "~a / ~a" (r1 (us (car cold))) (r1 (us (cadr cold))))
                       (format "~a / ~a" (r1 (/ (car edit) 1e6)) (r1 (/ (cadr edit) 1e6)))
                       (r1 (/ (cadr restart) 1e6)) (car restart))))
   (format "\n<p class=\"bench-note\">Each conversation is one callable actor and four 4,096-byte messages in LMDB with synchronous commits. An asleep call loads the actor's record first. An edit is one call and one durable commit. A restart opens the database in a new Host and answers one call, reading only the record it calls. At ~a conversations the Zig heap holds ~a KiB per conversation, against ~a KiB of records on disk. The heap excludes LMDB's mapped pages, which the operating system caches separately.</p>"
           (commas (car big)) (r1 (/ (cadr (list-ref big 5)) 1024.0 (car big))) (r1 (/ (car (list-ref big 5)) 1024.0 (car big))))))

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
  (define rps-svg (svg-bars clients (series (lambda (r) (or (list-ref r 3) 0))) commas #:bar-colors bar-colors))
  (define cold-svg (svg-bars clients (series (lambda (r) (or (list-ref r 6) 0))) (lambda (v) (~r v #:precision 1)) #:bar-colors bar-colors))
  (string-append
   (legend (list "language client" AMBER) (list "Goblins reference (CapTP peer)" TEAL))
   (charts (figure "Latency (p50 ms, lower is better)." p50-svg)
           (figure "Throughput (req/s, higher is better)." rps-svg))
   (panel (figure "Cold start (ms from spawn through one completed task-board unit, lower is better)." cold-svg)
          "<p class=\"bench-note\">Each row is a whole consumer stack (runtime, binding, the app rewritten in that language, and its garbage collector) over one Zig host. Read it as consumer cost. The Goblins row is the reference CapTP implementation dialing in.</p>")
   (html-table '("client" "runtime" "p50 (ms)" "req/s" "setup (ms/conn)" "mem (kB/conn)" "cold (ms)")
               (for/list ([r (in-list rows)])
                 (list (car r) (list-ref r 1)
                       (~r (or (list-ref r 2) 0) #:precision 2) (commas (or (list-ref r 3) 0))
                       (list-ref r 4) (list-ref r 5) (~r (or (list-ref r 6) 0) #:precision 1))))))

;; ── Run + splice (effectful) ─────────────────────────────────────────────────
;; `system` returns #f on a non-zero exit without raising; check it so a failed
;; bench cannot leave the page half-freshened with a stale goblins/langs report.
;; CapTP flake retries live in `bench/goblins/bench.rkt`, not here.
;; Start a bench only once the machine's one-minute load is under 2, the
;; same gate the bench README's repeated runs use, so a build running in
;; another checkout does not land in the page's figures. A machine without
;; /proc/loadavg starts at once.
(define (quiet)
  (when (file-exists? "/proc/loadavg")
    (let loop ()
      (define load (string->number (car (string-split (file->string "/proc/loadavg")))))
      (when (and load (>= load 2)) (sleep 20) (loop)))))

(define (run cmd)
  (quiet)
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
  (format "<p class=\"bench-stamp\">Every figure on this page comes from one run of commit <code>~a</code> on ~a: ~a, ~a logical CPUs, ~a GiB RAM, ~a, Spritely Goblins v~a, and the <code>glowcap</code> archives built by Zig ~a in ReleaseFast. <code>zig build bench-site-report</code> repeats it.</p>"
          (sh1 "git rev-parse --short=9 HEAD") (sh1 "date +%Y-%m-%d") (sh1 "uname -sm") (sh1 "nproc") gib
          racket-v goblins-v (sh1 "zig version")))

;; Replace the body of the `=html` block tagged with the bench marker in
;; `text`, read from `file`, which only the error names.
(define (splice file text name body)
  (define pat (pregexp (string-append "(?s:```=html\n<!-- bench:" name " GENERATED[^\n]*-->.*?```)")))
  (define repl (string-append "```=html\n<!-- bench:" name " GENERATED by `zig build bench-site-report`; edits are overwritten -->\n" body "\n```"))
  (unless (regexp-match? pat text) (error 'site-report "marker not found in ~a: bench:~a" file name))
  (regexp-replace pat text (lambda _ repl)))

;; Splice every (name . body) region into `file` and write it back.
(define (splice-file file regions)
  (define out
    (for/fold ([t (file->string file)]) ([pair (in-list regions)])
      (splice file t (car pair) (cdr pair))))
  (call-with-output-file file (lambda (o) (display out o)) #:exists 'replace))

(module+ main
  ;; Every tool a bench needs, checked before the first bench, so a missing one
  ;; fails in a second instead of after twenty minutes of runs. A container
  ;; older than the Dockerfile is the usual cause, and rebuilding it is the fix.
  (for ([tool '("cargo" "capnp" "g++" "pkg-config")])
    (unless (find-executable-path tool)
      (error 'site-report "~a is not on PATH; rebuild the devcontainer (.devcontainer/bin/up.sh --rebuild)" tool)))
  (unless (system "pkg-config --exists capnp-rpc")
    (error 'site-report "the capnp-rpc library is missing; rebuild the devcontainer (.devcontainer/bin/up.sh --rebuild)"))
  (printf "running benches in ReleaseFast (this takes a few minutes)...\n") (flush-output)
  ;; Goblins first: fail fast on the CapTP step before burning ReleaseFast
  ;; minutes on the Zig benches. Retries for CapTP flakes are inside bench-goblins.
  ;; Child builds do not inherit the report step's optimize mode. Name it on
  ;; every Zig command, including those that install the binding's archives.
  (run "zig build bench-goblins -Doptimize=ReleaseFast 2>&1")
  (define goblins (parse-goblins-md (latest-goblins-md)))
  (define codec (parse-codec (run "zig build bench-codec -Doptimize=ReleaseFast 2>&1")))
  (define fv (parse-frameview (run "zig build bench-frame-view -Doptimize=ReleaseFast 2>&1")))
  (define peer (parse-peer (run "zig build bench-peer-scaling -Doptimize=ReleaseFast 2>&1")))
  (define snap-p (parse-snapshot (run "zig build bench-snapshot -Doptimize=ReleaseFast 2>&1")))
  (define snap-g (parse-goblins-snapshot (run "racket bench/goblins/snapshot.rkt 2>&1")))
  (define iroh (parse-iroh (run "zig build bench-iroh -Doptimize=ReleaseFast 2>&1")))
  (define loam (parse-loam (run "zig build bench-loam -Doptimize=ReleaseFast -- --ordinary-only 2>&1")))
  (define cores (fast-cores))
  (define capnp
    (let* ([a (car cores)] [b (cadr cores)])
      (for/list ([pin (list (format "~a,~a" a a) (format "~a,~a" a b))])
        (parse-iroh (string-append
                     (run (format "zig build bench-capnp -Doptimize=ReleaseFast -- --pin=~a 2>&1" pin))
                     (run (format "zig build bench-iroh -Doptimize=ReleaseFast -- --transport=tcp --row=greet --pin=~a 2>&1" pin))
                     (run (format "zig build bench-iroh -Doptimize=ReleaseFast -- --transport=tcp --row=report --pin=~a 2>&1" pin))
                     (run (format "zig build bench-iroh -Doptimize=ReleaseFast -- --transport=tcp --row=greet --codec=capnp --pin=~a 2>&1" pin))
                     (run (format "zig build bench-iroh -Doptimize=ReleaseFast -- --transport=tcp --row=report --codec=capnp --pin=~a 2>&1" pin)))))))
  (run (format "zig build bench-langs -Doptimize=ReleaseFast -- --pin=~a,~a 2>&1" (car cores) (cadr cores)))
  (define langs (parse-langs-md (latest-langs-md)))
  (printf "rendering + splicing into ~a and ~a...\n" PERF COMPARED) (flush-output)
  (define stamp (stamp-region))
  (splice-file PERF (list (cons "stamp" stamp)
                          (cons "glance" (glance-region codec fv peer iroh langs loam))
                          (cons "codec" (codec-region codec))
                          (cons "peer-scaling" (peer-region peer))
                          (cons "frame-view" (frameview-region fv))
                          (cons "langs" (langs-region langs))
                          (cons "iroh" (iroh-region iroh))
                          (cons "loam" (loam-region loam))))
  (splice-file COMPARED (list (cons "stamp" stamp)
                              (cons "capnp-rpc" (capnp-rpc-region (car capnp) (cadr capnp)))
                              (cons "goblins" (goblins-region goblins))
                              (cons "snapshot" (snapshot-region snap-p snap-g))))
  (printf "done. validate with: zig build site\n"))
