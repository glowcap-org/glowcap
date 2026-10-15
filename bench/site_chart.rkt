#lang racket/base
;; Numbers and grouped-bar charts for the performance page, drawn as inline
;; SVG that reads the site's color tokens. site_report.rkt fills them in.
(require racket/format racket/list racket/math)

(provide INK SOFT r1 commas thousands svg-bars)

;; Text colors, as custom properties with the light theme's value as fallback.
(define INK "var(--ink, #3a3027)")
(define SOFT "var(--ink-soft, #6b5d4d)")

(define (r1 x) (~r (exact->inexact x) #:precision 1))
(define (commas v) (~r v #:precision 0 #:groups '(3) #:group-sep ","))
;; A value label short enough for a crowded chart. The table beside the chart
;; keeps the exact count.
(define (thousands v) (if (< v 1000) (commas v) (string-append (~r (/ v 1000.0) #:precision '(= 1)) "k")))

;; Compact grouped-bar SVG. groups: (listof string). series: (listof (list name
;; color (listof real))), each values list aligned with groups. fmt: real->string
;; for the per-bar label.
;; bar-colors, when given, is a per-group color list that overrides the series
;; color, used for single-series charts where each bar (not each series) needs
;; its own hue, e.g. tinting the Goblins reference row apart from the languages.
;;
;; The chart is H pixels tall at any width. It is laid out on a W-wide grid and
;; every x is written as a percentage of it, so a wide column stretches the
;; bars and their spacing while the height and the type stay the same size.
;;
;; A value sits above its bar. Where two neighbors' values would touch at the
;; narrowest width a chart is drawn, the taller bar's value moves up a line,
;; and the plot gives up room at the top only when one does.
(define LABEL-PX 9.5) (define LABEL-LINE 10.5) (define NARROWEST-PX 300)
(define (label-width text W)
  (* (/ W NARROWEST-PX) LABEL-PX
     (for/sum ([c (in-string text)]) (if (memv c '(#\, #\.)) 0.28 0.58))))

(define (lift-labels xs ys texts W)
  (define y (list->vector ys))
  (define (touch? a b)
    (and (< (abs (- (list-ref xs a) (list-ref xs b)))
            (+ 2 (/ (+ (label-width (list-ref texts a) W) (label-width (list-ref texts b) W)) 2)))
         (< (abs (- (vector-ref y a) (vector-ref y b))) LABEL-LINE)))
  (for* ([pass (in-range 2)] [j (in-range 1 (length xs))])
    (define i (- j 1))
    (when (touch? i j)
      (define-values (high low) (if (<= (vector-ref y j) (vector-ref y i)) (values j i) (values i j)))
      (vector-set! y high (- (vector-ref y low) LABEL-LINE))))
  (vector->list y))

(define (svg-bars groups series fmt #:bar-colors [bar-colors #f])
  (define W 380) (define H 210)
  (define (x% x) (string-append (~r (* 100.0 (/ x W)) #:precision 2) "%"))
  (define padL 6) (define padR 6) (define padB 26)
  (define base (- H padB)) (define pw (- W padL padR))
  (define ng (length groups)) (define k (length series))
  (define gw (/ pw ng))
  (define barw (/ (* gw 0.72) k))
  (define gap 3)
  (define clusterw (+ (* k barw) (* (- k 1) gap)))
  (define maxv (apply max 0.0001 (append* (map caddr series))))
  ;; Every bar of every group, as (group-index x y height fill text label-y).
  (define (lay-out top)
    (define ph (- base top))
    (append*
     (for/list ([g (in-list groups)] [i (in-naturals)])
       (define startx (- (+ padL (* gw (+ i 0.5))) (/ clusterw 2)))
       (define bars
         (for/list ([s (in-list series)] [j (in-naturals)])
           (define v (list-ref (caddr s) i))
           (define bh (* (/ v maxv) ph))
           (list i (+ startx (* j (+ barw gap))) (- base bh) bh
                 (if bar-colors (list-ref bar-colors i) (cadr s)) (fmt v))))
       (define label-ys
         (lift-labels (map (lambda (b) (+ (cadr b) (/ barw 2))) bars)
                      (map (lambda (b) (- (caddr b) 3)) bars)
                      (map (lambda (b) (list-ref b 5)) bars) W))
       (map (lambda (b ly) (append b (list ly))) bars label-ys))))
  ;; A label's glyphs rise about LABEL-PX * 0.75 above its baseline.
  (define first-try (lay-out 18))
  (define highest (apply min (map last first-try)))
  (define room (- (* LABEL-PX 0.75) highest))
  (define bars (if (> room 0) (lay-out (+ 18 room)) first-try))
  (define o (open-output-string))
  (define (p . xs) (for ([x (in-list xs)]) (display x o)) (newline o))
  (p "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100%\" height=\"" H "\" font-family=\"var(--font-sans, system-ui, -apple-system, sans-serif)\" role=\"img\">")
  (p "<line x1=\"" (x% padL) "\" y1=\"" base "\" x2=\"" (x% (- W padR)) "\" y2=\"" base "\" stroke=\"" INK "\" stroke-width=\"1.2\"/>")
  (for ([g (in-list groups)] [i (in-naturals)])
    (for ([b (in-list bars)] #:when (= (car b) i))
      (define bx (cadr b))
      (p "<rect x=\"" (x% bx) "\" y=\"" (r1 (caddr b)) "\" width=\"" (x% barw) "\" height=\"" (r1 (cadddr b)) "\" fill=\"" (list-ref b 4) "\" rx=\"2\"/>")
      (p "<text x=\"" (x% (+ bx (/ barw 2))) "\" y=\"" (r1 (last b)) "\" text-anchor=\"middle\" font-size=\"" LABEL-PX "\" fill=\"" INK "\">" (list-ref b 5) "</text>"))
    (p "<text x=\"" (x% (+ padL (* gw (+ i 0.5)))) "\" y=\"" (+ base 16) "\" text-anchor=\"middle\" font-size=\"11\" fill=\"" SOFT "\">" g "</text>"))
  (p "</svg>")
  (get-output-string o))

