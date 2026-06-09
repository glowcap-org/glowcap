#lang racket
;; handoff-introducer-host.rkt — the Goblins side of a live three-party handoff,
;; with pancake playing the recipient (Carol).
;;
;; Two Goblins vats in one process:
;;   * Bob  — hosts a `^greeter` cap (the exporter / gift origin).
;;   * Alice — enlivens Bob's greeter, then hosts an `^introducer` cap that hands
;;             that live ref out. Alice is the gifter; the introducer is what the
;;             recipient enlivens and asks for the greeter.
;;
;; A recipient (pancake) enlivens Alice's introducer over TCP, calls
;; `(introducer 'get-greeter)`, and receives Bob's greeter by OCapN three-party
;; handoff: Alice's mycapn sends a `desc:handoff-give`, and the recipient must dial
;; Bob directly and present a `desc:handoff-receive` to use the ref. The whole point
;; is that the recipient's call to the greeter goes *directly to Bob*, not proxied
;; through Alice.
;;
;; Usage:
;;   racket handoff-introducer-host.rkt <alice-port> <bob-port>
;;
;; Stdout (line-buffered NDJSON):
;;   {"v":1,"event":"vat-ready","vat":"alice","listen":"127.0.0.1:<alice-port>"}
;;   {"v":1,"event":"cap-published","vat":"alice","name":"introducer","swiss":"<swiss>"}
;; then sleeps until killed.

(require goblins
         goblins/vat
         goblins/ocapn/captp
         goblins/ocapn/structs-urls
         "tcp-netlayer.rkt")

(file-stream-buffer-mode (current-output-port) 'line)
(file-stream-buffer-mode (current-error-port) 'line)

;; A fixed swiss for the introducer so the recipient can address it.
(define INTRODUCER-SWISS
  (string->bytes/latin-1 "introducerSwissnum0123456789ABCD"))

(define (^greeter _bcom my-name)
  (lambda (your-name)
    (format "Hello ~a, I'm ~a — handed off directly from the exporter!" your-name my-name)))

(define (^introducer _bcom greeter-ref)
  (lambda args
    (case (and (pair? args) (car args))
      [(get-greeter) greeter-ref]
      [else (error '^introducer "unknown command: ~v" args)])))

(define argv (current-command-line-arguments))
(define alice-port (if (>= (vector-length argv) 1) (string->number (vector-ref argv 0)) 9011))
(define bob-port   (if (>= (vector-length argv) 2) (string->number (vector-ref argv 1)) 9012))

(define (emit-ndjson event-fields)
  (define (escape s) (regexp-replace* #px"[\\\\\"]" s "\\\\\\0"))
  (define pairs
    (for/list ([f event-fields]) (format "\"~a\":\"~a\"" (car f) (escape (cdr f)))))
  (printf "{\"v\":1,~a}~n" (string-join pairs ",")))

;; ── Bob: host the greeter, register a sturdyref Alice will enliven ───────────
(define bob-vat (make-vat))
(define bob-greeter-sref
  (bob-vat
   'run
   (lambda ()
     (define netlayer (spawn ^tcp-netlayer "127.0.0.1" bob-port))
     (define mycapn (spawn-mycapn netlayer))
     (define greeter (spawn ^greeter "Bob"))
     ($ mycapn 'register greeter 'tcp))))

;; ── Alice: enliven Bob's greeter, host an introducer over it ─────────────────
(define alice-vat (make-vat))
(alice-vat
 'run
 (lambda ()
   (define netlayer (spawn ^tcp-netlayer "127.0.0.1" alice-port))
   (define mycapn (spawn-mycapn netlayer))
   (define nonce-registry ($ mycapn 'get-registry))
   ;; Enliven Bob's greeter (opens an Alice -> Bob connection); pass the vow to the
   ;; introducer — Goblins pipelining lets the introducer hand out the vow.
   (define greeter-vow (<- mycapn 'enliven bob-greeter-sref))
   (define introducer (spawn ^introducer greeter-vow))
   ($ nonce-registry 'register introducer INTRODUCER-SWISS)
   (on (<- netlayer 'our-location)
       (lambda (_loc)
         (emit-ndjson `(("event" . "vat-ready") ("vat" . "alice")
                        ("listen" . ,(format "127.0.0.1:~a" alice-port))))
         (emit-ndjson `(("event" . "cap-published") ("vat" . "alice")
                        ("name" . "introducer")
                        ("swiss" . ,(bytes->string/latin-1 INTRODUCER-SWISS))))))))

(sync (make-semaphore))
