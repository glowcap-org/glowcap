#lang racket
;; handoff-introducer-host.rkt — the Goblins side of a live three-party handoff,
;; with glowcap playing the recipient (Carol).
;;
;; Two Goblins vats in one process:
;;   * Bob  — hosts a `^greeter` cap (the exporter / gift origin).
;;   * Alice — enlivens Bob's greeter, then hosts an `^introducer` cap that hands
;;             that live ref out. Alice is the gifter; the introducer is what the
;;             recipient enlivens and asks for the greeter.
;;
;; A recipient (glowcap) enlivens Alice's introducer over TCP or iroh, calls
;; `(introducer 'get-greeter)`, and receives Bob's greeter by OCapN three-party
;; handoff: Alice's mycapn sends a `desc:handoff-give`, and the recipient must dial
;; Bob directly and present a `desc:handoff-receive` to use the ref. The whole point
;; is that the recipient's call to the greeter goes *directly to Bob*, not proxied
;; through Alice.
;;
;; Usage:
;;   racket handoff-introducer-host.rkt <alice-port> <bob-port>
;;   racket handoff-introducer-host.rkt --iroh
;;
;; Stdout (line-buffered NDJSON):
;;   {"v":1,"event":"vat-ready","vat":"alice","listen":"127.0.0.1:<alice-port>"}
;;   {"v":1,"event":"cap-published","vat":"alice","name":"introducer","swiss":"<swiss>"}
;; then sleeps until killed.

(require goblins
         goblins/vat
         goblins/ocapn/captp
         goblins/ocapn/structs-urls
         racket/runtime-path
         "tcp-netlayer.rkt")

(file-stream-buffer-mode (current-output-port) 'line)
(file-stream-buffer-mode (current-error-port) 'line)

;; A fixed swiss for the introducer so the recipient can address it.
(define INTRODUCER-SWISS
  (string->bytes/latin-1 "introducerSwissnum0123456789ABCD"))

(define refreshed? (box #f))
(define changed-addresses (box #f))
(define (^greeter _bcom my-name)
  (lambda (your-name)
    (if (equal? your-name "refresh-addresses")
        (begin (set-box! refreshed? #t) (unbox changed-addresses))
        (format "Hello ~a, I'm ~a, handed off directly from the exporter!" your-name my-name))))

(define (^introducer _bcom greeter-ref)
  (lambda args
    (case (and (pair? args) (car args))
      [(get-greeter) greeter-ref]
      [(refresh-exporter) (<- greeter-ref "refresh-addresses")]
      [else (error '^introducer "unknown command: ~v" args)])))

(define argv (current-command-line-arguments))
(define iroh? (and (= (vector-length argv) 1) (equal? (vector-ref argv 0) "--iroh")))
(define transport (if iroh? 'iroh 'tcp))
;; Keep the TCP fixture independent of the optional iroh companion archive.
(define-runtime-path iroh-netlayer-path "iroh-netlayer.rkt")
(define-runtime-path iroh-binding-path "../../../bindings/racket/glowcap-iroh.rkt")
(define (make-netlayer port [advertise values])
  (if iroh?
      (spawn (dynamic-require iroh-netlayer-path '^iroh-netlayer)
             (dynamic-require iroh-binding-path 'IROH-REACH-DIRECT)
             #:advertise-direct-addresses advertise)
      (spawn ^tcp-netlayer "127.0.0.1" port)))
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
     (define netlayer
       (make-netlayer bob-port
                      (lambda (addresses)
                        ;; Change advice without dropping Alice's existing
                        ;; session. The added route is unused; the original
                        ;; bound route remains reachable throughout this test.
                        (define changed (string-append addresses ",127.0.0.1:1"))
                        (set-box! changed-addresses changed)
                        (if (unbox refreshed?) changed addresses))))
     (define mycapn (spawn-mycapn netlayer))
     (define greeter (spawn ^greeter "Bob"))
     ($ mycapn 'register greeter transport))))

;; ── Alice: enliven Bob's greeter, host an introducer over it ─────────────────
(define alice-vat (make-vat))
(alice-vat
 'run
 (lambda ()
   (define netlayer (make-netlayer alice-port))
   (define mycapn (spawn-mycapn netlayer))
   (define nonce-registry ($ mycapn 'get-registry))
   ;; Enliven Bob's greeter (opens an Alice -> Bob connection); pass the vow to the
   ;; introducer, Goblins pipelining lets the introducer hand out the vow.
   (define greeter-vow (<- mycapn 'enliven bob-greeter-sref))
   (define introducer (spawn ^introducer greeter-vow))
   ($ nonce-registry 'register introducer INTRODUCER-SWISS)
   (on (<- netlayer 'our-location)
       (lambda (loc)
         (define fields (struct->vector loc))
         (define hints (vector-ref fields 3))
         (emit-ndjson
          (append `(("event" . "vat-ready") ("vat" . "alice"))
                  (if iroh?
                      `(("node-id" . ,(vector-ref fields 2))
                        ("exporter-id" . ,(ocapn-node-designator
                                            (ocapn-sturdyref-node bob-greeter-sref)))
                        ("direct-addresses" . ,(hash-ref hints "direct-addresses")))
                      `(("listen" . ,(format "127.0.0.1:~a" alice-port))))))
         (emit-ndjson `(("event" . "cap-published") ("vat" . "alice")
                        ("name" . "introducer")
                        ("swiss" . ,(bytes->string/latin-1 INTRODUCER-SWISS))))))))

(sync (make-semaphore))
