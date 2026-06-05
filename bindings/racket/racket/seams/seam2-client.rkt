#lang racket/base

;; Stack 2 CLIENT: STOCK Spritely Goblins — goblins/ocapn/captp +
;; Spritely's own racket/tcp netlayer (goblins-peer tcp-netlayer.rkt),
;; UNCHANGED. Dials the pancake-captp host and invokes echo. SUCCESS
;; is getting the echo result back.

(require racket/async-channel
         goblins
         goblins/vat
         goblins/ocapn/captp                       ; UPSTREAM stock
         goblins/ocapn/structs-urls                ; UPSTREAM stock
         (file "/home/coder/src/github.com/jimisaacs/pancake/ffi-wasm/reference/implementations/goblins-peer/racket/tcp-netlayer.rkt")) ; UPSTREAM stock

(define ECHO-SWISS-NUM
  (string->bytes/latin-1 "IO58l1laTyhcrgDKbEzFOO32MDd6zE5w"))

(define host "127.0.0.1")
(define port
  (string->number (vector-ref (current-command-line-arguments) 0)))

(file-stream-buffer-mode (current-output-port) 'line)

(define a-vat (make-vat))
(define result-ch (make-async-channel))
(a-vat
 'run
 (lambda ()
   (define nl
     (spawn ^tcp-netlayer "127.0.0.1" (+ port 100) "127.0.0.1"))
   (define mycapn (spawn-mycapn nl))
   (define target-location
     (ocapn-node 'tcp (format "~a:~a" host port) #f))
   (define echo-sturdyref
     (ocapn-sturdyref target-location ECHO-SWISS-NUM))
   (printf "[client] enlivening echo sturdyref at ~a:~a~n" host port)
   (define echo-vow (<- mycapn 'enliven echo-sturdyref))
   (on echo-vow
       (lambda (echo)
         (printf "[client] enlivened echo; invoking echo \"hello\" \"world\"~n")
         (on (<- echo "hello" "world")
             (lambda (echo-result)
               (printf "[client] echo returned: ~v~n" echo-result)
               (async-channel-put result-ch `(ok ,echo-result)))
             #:catch
             (lambda (err)
               (printf "[client] echo invocation broke: ~v~n" err)
               (async-channel-put result-ch `(err invoke ,err)))))
       #:catch
       (lambda (err)
         (printf "[client] enliven broke: ~v~n" err)
         (async-channel-put result-ch `(err enliven ,err))))))

(define reply (sync/timeout 15.0 result-ch))
(cond
  [(and (pair? reply) (eq? (car reply) 'ok))
   (printf "OK: stack2 — pancake-captp host over Racket TCP sockets echoed via stock Goblins client: ~v~n"
           (cadr reply))]
  [reply
   (printf "FAIL: ~v~n" reply)
   (exit 1)]
  [else
   (printf "FAIL: timeout~n")
   (exit 2)])
