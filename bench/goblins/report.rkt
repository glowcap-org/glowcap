#lang racket/base
;; Rendering for the cross-implementation benchmark: a Markdown report (value
;; tables plus Mermaid bar charts that render on Codeberg/GitHub) and standalone
;; SVG bar charts (self-contained, no JS, the same shape the site's hand-authored
;; diagrams use). Pure string building over the orchestrator's results hash; no
;; measurement happens here.
(require racket/string racket/list racket/format)

(provide render-markdown render-svg-bars BACKENDS)

;; Palette lifted from the site (assets/style.css) so charts drop into the docs
;; without a second theme: pancake in the accent amber, Goblins in teal, and
;; pancake-with-time-travel in green (the same green the site uses for pancake's
;; persistent/functional series).
(define GOBLINS-COLOR "#257f88")
(define PANCAKE-COLOR "#c76f18")
(define PANCAKE-TT-COLOR "#4f8a5b")
(define INK "#3a3027")
(define INK-SOFT "#6b5d4d")
(define PAPER "#fff9ee")
(define RULE "#e7d4b7")

;; The three measured series, in chart order. `pancake-tt` is the pancake binding
;; with time-travel on for every actor.
(define BACKENDS '("goblins" "pancake" "pancake-tt"))
(define COLORS (list GOBLINS-COLOR PANCAKE-COLOR PANCAKE-TT-COLOR))

(define (esc s)
  (regexp-replaces (format "~a" s) '((#rx"&" "\\&amp;") (#rx"<" "\\&lt;") (#rx">" "\\&gt;"))))

;; A field as stored by the orchestrator (a string), or #f.
(define (field results suite backend key)
  (define r (hash-ref results (list suite backend) #f))
  (and r (let ([c (assq key r)]) (and c (cdr c)))))

;; A field as a number (0 when missing/unparseable), for chart scaling.
(define (numof results suite backend key)
  (or (string->number (or (field results suite backend key) "")) 0))

;; Grouped bars: one bar per backend in `BACKENDS`, per suite.
;; value-of : (suite backend) -> real ; fmt : real -> string for the bar labels.
(define (render-svg-bars title y-label suites value-of fmt)
  (define W 760) (define H 430)
  (define ml 72) (define mr 24) (define mt 56) (define mb 80)
  (define pw (- W ml mr)) (define ph (- H mt mb))
  (define x0 ml) (define y1 (+ mt ph))
  (define n (length suites))
  (define nb (length BACKENDS))
  (define vals (for*/list ([s (in-list suites)] [b (in-list BACKENDS)]) (value-of s b)))
  (define maxv (apply max 0.0001 vals))
  (define gw (/ pw (max 1 n)))
  ;; The grouped bars span ~70% of each group's slot, split evenly across backends.
  (define band (* gw 0.70))
  (define slot (/ band nb))
  (define bw (* slot 0.86))
  (define (bar-y v) (- y1 (* (/ v maxv) ph)))
  (define out (open-output-string))
  (define (o . xs) (for ([x (in-list xs)]) (display x out)) (newline out))
  (define ymid (+ mt (/ ph 2)))
  (o "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 " W " " H "\" font-family=\"system-ui,-apple-system,sans-serif\" role=\"img\">")
  (o "<rect width=\"" W "\" height=\"" H "\" fill=\"" PAPER "\" rx=\"10\"/>")
  (o "<text x=\"" (/ W 2) "\" y=\"30\" text-anchor=\"middle\" font-size=\"18\" font-weight=\"700\" fill=\"" INK "\">" (esc title) "</text>")
  (o "<text x=\"18\" y=\"" ymid "\" text-anchor=\"middle\" font-size=\"12\" fill=\"" INK-SOFT
     "\" transform=\"rotate(-90 18 " ymid ")\">" (esc y-label) "</text>")
  ;; baseline + a dashed max gridline with its value
  (o "<line x1=\"" x0 "\" y1=\"" mt "\" x2=\"" (+ x0 pw) "\" y2=\"" mt "\" stroke=\"" RULE "\" stroke-dasharray=\"3 3\"/>")
  (o "<line x1=\"" x0 "\" y1=\"" y1 "\" x2=\"" (+ x0 pw) "\" y2=\"" y1 "\" stroke=\"" INK "\" stroke-width=\"1.5\"/>")
  (o "<text x=\"" (- x0 8) "\" y=\"" (+ mt 4) "\" text-anchor=\"end\" font-size=\"11\" fill=\"" INK-SOFT "\">" (fmt maxv) "</text>")
  (o "<text x=\"" (- x0 8) "\" y=\"" (+ y1 4) "\" text-anchor=\"end\" font-size=\"11\" fill=\"" INK-SOFT "\">0</text>")
  (for ([s (in-list suites)] [i (in-naturals)])
    (define cx (+ x0 (* gw (+ i 0.5))))
    (define band-left (- cx (/ band 2)))
    (for ([b (in-list BACKENDS)] [c (in-list COLORS)] [j (in-naturals)])
      (define v (value-of s b))
      (define bx (+ band-left (* j slot) (/ (- slot bw) 2)))
      (define by (bar-y v))
      (o "<rect x=\"" (exact->inexact bx) "\" y=\"" (exact->inexact by) "\" width=\"" (exact->inexact bw)
         "\" height=\"" (exact->inexact (max 0 (- y1 by))) "\" fill=\"" c "\" rx=\"2\"/>")
      (o "<text x=\"" (exact->inexact (+ bx (/ bw 2))) "\" y=\"" (exact->inexact (- by 4))
         "\" text-anchor=\"middle\" font-size=\"9\" fill=\"" INK "\">" (fmt v) "</text>"))
    (o "<text x=\"" (exact->inexact cx) "\" y=\"" (+ y1 18) "\" text-anchor=\"middle\" font-size=\"12\" fill=\"" INK "\">" (esc s) "</text>"))
  (define ly (+ y1 44))
  (for ([b (in-list BACKENDS)] [c (in-list COLORS)] [k (in-naturals)])
    (define lx (+ x0 (* k 200)))
    (o "<rect x=\"" lx "\" y=\"" (- ly 11) "\" width=\"13\" height=\"13\" fill=\"" c "\" rx=\"2\"/>")
    (o "<text x=\"" (+ lx 19) "\" y=\"" ly "\" font-size=\"13\" fill=\"" INK "\">" b "</text>"))
  (o "</svg>")
  (get-output-string out))

;; ── Markdown: value table + Mermaid bar charts ────────────────────────────────
(define (md-table suites results)
  (string-append
   "| suite | backend | p50 ms | p99 ms | p999 ms | req/s | setup ms/conn | mem kB/conn |\n"
   "| --- | --- | --- | --- | --- | --- | --- | --- |\n"
   (string-join
    (for*/list ([s (in-list suites)] [b (in-list BACKENDS)])
      (format "| ~a | ~a | ~a | ~a | ~a | ~a | ~a | ~a |"
              s b
              (or (field results s b 'p50) "-") (or (field results s b 'p99) "-")
              (or (field results s b 'p999) "-") (or (field results s b 'rps) "-")
              (or (field results s b 'conn_ms) "-") (or (field results s b 'per_conn_kb) "-")))
    "\n")
   "\n"))

;; Mermaid xychart-beta renders grouped bars but has no per-series legend, so the
;; series order is named in the title (one bar per backend, in `BACKENDS` order).
(define (mermaid-chart title y-label suites results key)
  (define (series b)
    (string-join (for/list ([s (in-list suites)]) (number->string (numof results s b key))) ", "))
  (string-append
   "```mermaid\n"
   "xychart-beta\n"
   (format "    title \"~a, bars in order: ~a\"\n" title (string-join BACKENDS ", "))
   (format "    x-axis [~a]\n" (string-join suites ", "))
   (format "    y-axis \"~a\"\n" y-label)
   (apply string-append (for/list ([b (in-list BACKENDS)]) (format "    bar [~a]\n" (series b))))
   "```\n"))

(define (render-markdown suites results mode lat-n tput-n conns svg-files)
  (string-append
   "# pancake vs Spritely Goblins — benchmark\n\n"
   (format "Mode **~a** · latency n=~a · throughput n=~a · connections=~a. One shared Racket application per substrate, over real loopback TCP.\n\n"
           mode lat-n tput-n conns)
   "> These numbers come from a single machine on a single run. They are not a leaderboard — reproduce them with `zig build bench-goblins`, and read the [methodology](https://github.com/jimisaacs/pancake/blob/main/bench/goblins/METHODOLOGY.md) for the caveats (sequential driving, no pipelining, coarse per-connection memory).\n\n"
   "## Results\n\n"
   (md-table suites results)
   "\n## Latency — p50, milliseconds (lower is better)\n\n"
   (mermaid-chart "Latency p50 (ms)" "ms" suites results 'p50)
   (if (assq 'latency svg-files) (format "\n![latency p50](~a)\n" (cdr (assq 'latency svg-files))) "")
   "\n## Throughput — requests/second (higher is better)\n\n"
   (mermaid-chart "Throughput (req/s)" "req/s" suites results 'rps)
   (if (assq 'throughput svg-files) (format "\n![throughput](~a)\n" (cdr (assq 'throughput svg-files))) "")
   "\n"))

;; Numeric accessor re-exported for the orchestrator's SVG value-of closures.
(provide numof)
