#lang racket
;; griddle-goblins-host.rkt — Goblins harness for Stage 7
;; (Goblins-as-a-turmoil-host via griddle's SubprocessBridgePlugin).
;;
;; Spawns one or more Goblins vats, each on its own real-OS TCP
;; port, each registering an `^echo` cap at the canonical OCapN
;; conformance-suite echo swiss-num. Emits machine-readable NDJSON
;; readiness events to stdout (one `vat-ready` + one
;; `cap-published` line per vat), then sleeps until killed.
;;
;; Usage:
;;   racket griddle-goblins-host.rkt <bind-host> <bind-port>            ; one vat
;;   racket griddle-goblins-host.rkt <bind-host> <bind-port> <vats>     ; N vats
;;
;; In the multi-vat shape, vat `i` (0-indexed) binds on
;; `<bind-port> + i`. Vat names are `goblins-alice`, `goblins-bob`,
;; `goblins-carol`, …; if `<vats>` exceeds the named-vat list a
;; numeric suffix continues (`goblins-vat-3`, `goblins-vat-4`, …).
;;
;; Stdout (line-buffered NDJSON; per vat):
;;   {"v":1,"event":"vat-ready","vat":"goblins-alice","listen":"127.0.0.1:22045"}
;;   {"v":1,"event":"cap-published","vat":"goblins-alice","name":"echo","swiss":"IO58l1laTyhcrgDKbEzFOO32MDd6zE5w"}
;;   {"v":1,"event":"vat-ready","vat":"goblins-bob","listen":"127.0.0.1:22046"}
;;   {"v":1,"event":"cap-published","vat":"goblins-bob","name":"echo","swiss":"IO58l1laTyhcrgDKbEzFOO32MDd6zE5w"}
;;
;; Why NDJSON, not human prose: the bridge plugin parses these to
;; learn the real-OS address (for SubprocessBridgePlugin) and the
;; cap's swiss-num (for the griddle event stream). Same NDJSON
;; convention as the rest of the griddle pipeline.
;;
;; Why same swiss-num across vats: a multi-vat scenario is N peers
;; that all offer the same `^echo` cap (e.g. for visualizing
;; cross-vat fan-out, or for stress-testing). Different swiss-nums
;; per vat would be a different scenario shape; out of scope here.

(require goblins
         goblins/vat
         goblins/ocapn/captp
         goblins/ocapn/structs-urls
         "tcp-netlayer.rkt")

;; Line-buffer stdout so the bridge plugin sees the readiness lines
;; immediately, not block-buffered until exit. Same reason
;; seven-caps-peer.rkt does this.
(file-stream-buffer-mode (current-output-port) 'line)
(file-stream-buffer-mode (current-error-port) 'line)

;; OCapN conformance-suite canonical echo swiss-num (same as
;; seven-caps-peer.rkt and pancake-conformance-peer's SWISS_ECHO_GC).
(define ECHO-SWISS-NUM
  (string->bytes/latin-1 "IO58l1laTyhcrgDKbEzFOO32MDd6zE5w"))

;; Echo behavior — `(lambda args args)` returns its arguments
;; unchanged. Mirrors seven-caps-peer.rkt's `^echo`.
(define (^echo _bcom)
  (lambda args
    args))

;; ─── CLI ─────────────────────────────────────────────────────────

(define argv (current-command-line-arguments))

(define listen-host
  (if (>= (vector-length argv) 1)
      (vector-ref argv 0)
      "127.0.0.1"))

(define base-port
  (if (>= (vector-length argv) 2)
      (string->number (vector-ref argv 1))
      22045))

(define vat-count
  (if (>= (vector-length argv) 3)
      (string->number (vector-ref argv 2))
      1))

(unless (and (exact-positive-integer? vat-count) (<= vat-count 64))
  (error 'griddle-goblins-host
         "vat count must be a positive integer ≤ 64; got ~v"
         (and (>= (vector-length argv) 3)
              (vector-ref argv 2))))

;; Named vats first, then numeric `goblins-vat-<i>` for the tail. The
;; named list mirrors the convention pancake's griddle scenarios use
;; (`alice`, `bob`, `carol`, …). Single-vat invocations use
;; `goblins-alice` so the integration tests' assertions don't move.
(define NAMED-VATS
  '("goblins-alice"
    "goblins-bob"
    "goblins-carol"
    "goblins-dave"
    "goblins-eve"
    "goblins-frank"))

(define (vat-name-for i)
  (if (< i (length NAMED-VATS))
      (list-ref NAMED-VATS i)
      (format "goblins-vat-~a" i)))

;; ─── NDJSON readiness emission ───────────────────────────────────

(define (emit-ndjson event-fields)
  ;; Emit one JSON object per line. event-fields is an assoc list of
  ;; (key . string-value). Hand-roll the JSON to avoid pulling in
  ;; another package just for this — keys are static, values are
  ;; controlled, so escaping concerns are minimal.
  (define (escape s)
    (regexp-replace* #px"[\\\\\"]" s "\\\\\\0"))
  (define pairs
    (for/list ([f event-fields])
      (format "\"~a\":\"~a\"" (car f) (escape (cdr f)))))
  (printf "{\"v\":1,~a}~n" (string-join pairs ",")))

;; ─── Boot one vat ────────────────────────────────────────────────

;; Spawn one Goblins vat bound to `<host>:<port>`, registering the
;; canonical echo cap. Emits the per-vat NDJSON readiness lines once
;; the netlayer reports its `our-location`.
(define (boot-vat vat-id host port)
  (define a-vat (make-vat))
  (a-vat
   'run
   (lambda ()
     (define tcp-netlayer (spawn ^tcp-netlayer host port))
     (define mycapn (spawn-mycapn tcp-netlayer))
     (define nonce-registry ($ mycapn 'get-registry))
     (define echo (spawn ^echo))
     ($ nonce-registry 'register echo ECHO-SWISS-NUM)
     (on (<- tcp-netlayer 'our-location)
         (lambda (_location)
           (emit-ndjson
            `(("event" . "vat-ready")
              ("vat" . ,vat-id)
              ("listen" . ,(format "~a:~a" host port))))
           (emit-ndjson
            `(("event" . "cap-published")
              ("vat" . ,vat-id)
              ("name" . "echo")
              ("swiss" . ,(bytes->string/latin-1 ECHO-SWISS-NUM)))))))))

;; ─── Boot all vats ───────────────────────────────────────────────

(for ([i (in-range vat-count)])
  (boot-vat (vat-name-for i) listen-host (+ base-port i)))

(sync (make-semaphore))
