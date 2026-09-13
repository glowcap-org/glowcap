#lang racket
;; gc-echo-host.rkt — Goblins vat host for the live `goblins-gc` driver.
;;
;; Same echo swiss as goblins-host.rkt / the CapTP suite, plus a background
;; `(collect-garbage)` loop so CapTP's will-executor can fire `op:gc-exports`
;; for imports the echo turn no longer retains. Without that nudge, Racket may
;; never collect the import refr in a short interop run.
;;
;; Usage:
;;   racket gc-echo-host.rkt <bind-host> <bind-port>
;;
;; Stdout (line-buffered NDJSON):
;;   {"v":1,"event":"vat-ready","vat":"goblins-gc","listen":"127.0.0.1:22130"}
;;   {"v":1,"event":"cap-published","vat":"goblins-gc","name":"echo","swiss":"IO58l1laTyhcrgDKbEzFOO32MDd6zE5w"}

(require goblins
         goblins/vat
         goblins/ocapn/captp
         goblins/ocapn/structs-urls
         "tcp-netlayer.rkt"
         "gc-probe.rkt")

(file-stream-buffer-mode (current-output-port) 'line)
(file-stream-buffer-mode (current-error-port) 'line)

(define ECHO-SWISS-NUM
  (string->bytes/latin-1 "IO58l1laTyhcrgDKbEzFOO32MDd6zE5w"))

(define (^echo _bcom)
  (lambda args
    args))

(define argv (current-command-line-arguments))

(define listen-host
  (if (>= (vector-length argv) 1)
      (vector-ref argv 0)
      "127.0.0.1"))

(define listen-port
  (if (>= (vector-length argv) 2)
      (string->number (vector-ref argv 1))
      22130))

(define (emit-ndjson event-fields)
  (define (escape s)
    (regexp-replace* #px"[\\\\\"]" s "\\\\\\0"))
  (define pairs
    (for/list ([f event-fields])
      (format "\"~a\":\"~a\"" (car f) (escape (cdr f)))))
  (printf "{\"v\":1,~a}~n" (string-join pairs ",")))

(define a-vat (make-vat))
(a-vat
 'run
 (lambda ()
   (define tcp-netlayer (spawn ^tcp-netlayer listen-host listen-port))
   (define mycapn (spawn-mycapn tcp-netlayer))
   (define nonce-registry ($ mycapn 'get-registry))
   (register-gc-probe! nonce-registry)
   (define echo (spawn ^echo))
   ($ nonce-registry 'register echo ECHO-SWISS-NUM)
   (on (<- tcp-netlayer 'our-location)
       (lambda (_location)
         (emit-ndjson
          `(("event" . "vat-ready")
            ("vat" . "goblins-gc")
            ("listen" . ,(format "~a:~a" listen-host listen-port))))
         (emit-ndjson
          `(("event" . "cap-published")
            ("vat" . "goblins-gc")
            ("name" . "echo")
            ("swiss" . ,(bytes->string/latin-1 ECHO-SWISS-NUM))))))))

;; CapTP registers wills on import refrs; those wills enqueue op:gc-exports
;; only after the refr is collected. Nudge the collector so a short interop
;; run can observe the release.
(define (gc-loop)
  (sleep 0.2)
  (collect-garbage)
  (gc-loop))

(thread gc-loop)
(sync (make-semaphore))
