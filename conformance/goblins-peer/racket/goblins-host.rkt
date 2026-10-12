#lang racket
;; goblins-host.rkt, a Goblins vat host for the live OCapN interop driver.
;;
;; Spawns one or more Goblins vats, each on its own real-OS TCP
;; port, each registering an `^echo` cap at the canonical OCapN
;; conformance-suite echo swiss-num and a `^record` cap (returns a
;; string-keyed hash, i.e. an OCapN Struct) behind a fixed swiss-num
;; for the driver's `op:get` leg. Emits machine-readable NDJSON
;; readiness events to stdout (one `vat-ready` + one
;; `cap-published` line per cap per vat), then sleeps until killed.
;;
;; Usage:
;;   racket goblins-host.rkt <bind-host> <bind-port>            ; one vat
;;   racket goblins-host.rkt <bind-host> <bind-port> <vats>     ; N vats
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
;; Why NDJSON, not human prose: the interop driver parses these to
;; learn the real-OS listen address and the cap's swiss-num, and it
;; waits for these readiness lines before it dials in.
;;
;; Why same swiss-num across vats: a multi-vat scenario is N peers
;; that all offer the same `^echo` cap (e.g. for visualizing
;; cross-vat fan-out, or for stress-testing). Different swiss-nums
;; per vat would be a different scenario shape; out of scope here.

(require goblins
         goblins/vat
         goblins/ocapn/captp
         goblins/ocapn/structs-urls
         goblins/utils/url-base64
         "tcp-netlayer.rkt"
         "gc-probe.rkt")

;; Line-buffer stdout so the bridge plugin sees the readiness lines
;; immediately, not block-buffered until exit. Same reason
;; seven-caps-peer.rkt does this.
(file-stream-buffer-mode (current-output-port) 'line)
(file-stream-buffer-mode (current-error-port) 'line)

;; OCapN conformance-suite canonical echo swiss-num (same as
;; seven-caps-peer.rkt and glowcap-conformance-peer's SWISS_ECHO_GC).
(define ECHO-SWISS-NUM
  (string->bytes/latin-1 "IO58l1laTyhcrgDKbEzFOO32MDd6zE5w"))

;; Echo behavior, `(lambda args args)` returns its arguments
;; unchanged. Mirrors seven-caps-peer.rkt's `^echo`.
(define (^echo _bcom)
  (lambda args
    args))

;; Swiss-num for the record cap the interop driver's `op:get` leg
;; fetches. The driver hardcodes the same constant (the way the
;; listener scenarios fix their actor swiss-num) instead of parsing a
;; second NDJSON line, so the echo `cap-published` line stays the
;; first `swiss` line every interop client parses.
(define RECORD-SWISS-NUM
  (string->bytes/latin-1 "glowcapRecordSwissnumABCDEF12345"))

;; Record behavior, returns an OCapN Struct (a string-keyed Racket
;; hash) carrying its argument, so a partner can pipeline `op:get`
;; against the call's answer and have a named field resolve out of it
;; (captp.rkt answers an inbound op:get with a `hash-ref` vow).
(define (^record _bcom)
  (lambda (name)
    (hash "kind" "record"
          "name" name)))

;; Swiss-num for the tally cap. A one-way deliver carries no answer, so
;; the only way a partner can prove its `tell` arrived is to change
;; something and read it back: `bump` takes no answer and increments,
;; `read` answers with the count so far.
(define TALLY-SWISS-NUM
  (string->bytes/latin-1 "glowcapTallySwissnumABCDEF123456"))

;; Tally behavior. `bump` is what a partner's one-way deliver targets;
;; it returns a new behavior with the count raised, so the effect
;; outlives the delivery that caused it. `read` answers the count.
(define (^tally bcom [n 0])
  (lambda (verb . args)
    (case verb
      [(bump) (bcom (^tally bcom (add1 n)))]
      [(read) n]
      [else (error '^tally "no such method: ~a" verb)])))

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
  (error 'goblins-host
         "vat count must be a positive integer ≤ 64; got ~v"
         (and (>= (vector-length argv) 3)
              (vector-ref argv 2))))

;; Named vats first, then numeric `goblins-vat-<i>` for the tail. The
;; named list runs `alice`, `bob`, `carol`, … in order. Single-vat
;; invocations use `goblins-alice` so the integration tests' assertions
;; don't move.
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
  ;; another package just for this, keys are static, values are
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
     (register-gc-probe! nonce-registry)
     (define echo (spawn ^echo))
     ($ nonce-registry 'register echo ECHO-SWISS-NUM)
     (define record (spawn ^record))
     ($ nonce-registry 'register record RECORD-SWISS-NUM)
     (define tally (spawn ^tally))
     ($ nonce-registry 'register tally TALLY-SWISS-NUM)
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
              ("swiss" . ,(bytes->string/latin-1 ECHO-SWISS-NUM))
              ("sturdyref-path" . ,(url-base64-encode ECHO-SWISS-NUM))))
           ;; Emitted after echo's line: raw-swiss consumers take
           ;; the first `swiss` line as the echo cap.
           (emit-ndjson
            `(("event" . "cap-published")
              ("vat" . ,vat-id)
              ("name" . "record")
              ("swiss" . ,(bytes->string/latin-1 RECORD-SWISS-NUM))))
           (emit-ndjson
            `(("event" . "cap-published")
              ("vat" . ,vat-id)
              ("name" . "tally")
              ("swiss" . ,(bytes->string/latin-1 TALLY-SWISS-NUM)))))))))

;; ─── Boot all vats ───────────────────────────────────────────────

(for ([i (in-range vat-count)])
  (boot-vat (vat-name-for i) listen-host (+ base-port i)))

(sync (make-semaphore))
