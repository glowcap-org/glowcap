#lang racket/base
;; pancake-export-listen.rkt — Goblins client that sends canonical export-side
;; `op:listen` against a live pancake object export.
;;
;; After enliven resolves to a remote object, `(listen provider listener-refr)`
;; drives Goblins' normal `cmd-send-listen` path, which marshals
;; `<op:listen <desc:export …> …>` on the wire. pancake fires fulfill of that
;; export immediately; the listener actor prints the success needle.
;;
;; Usage:
;;   racket pancake-export-listen.rkt <target-port> <swiss-ascii> [local-port]
;;
;; Prints `LISTEN OK` and exits 0 on success.

(require goblins
         goblins/vat
         goblins/ocapn
         goblins/ocapn/structs-urls
         "tcp-netlayer.rkt"
         racket/async-channel)

(file-stream-buffer-mode (current-output-port) 'line)

(define argv (current-command-line-arguments))
(define target-port (string->number (vector-ref argv 0)))
(define swiss-ascii (vector-ref argv 1))
(define local-port
  (if (>= (vector-length argv) 3)
      (string->number (vector-ref argv 2))
      19995))

(define response-ch (make-async-channel))
(define dialer-vat (make-vat))

(define (^listen-capture _bcom)
  (methods
   [(fulfill val) (async-channel-put response-ch `(ok ,val))]
   [(break err) (async-channel-put response-ch `(err ,err))]))

(dialer-vat
 'run
 (lambda ()
   (define netlayer (spawn ^tcp-netlayer "127.0.0.1" local-port))
   (define mycapn (spawn-mycapn netlayer))
   (define target
     (ocapn-sturdyref
      (ocapn-node 'tcp (format "127.0.0.1:~a" target-port) #f)
      (string->bytes/latin-1 swiss-ascii)))

   (on (<- mycapn 'enliven target)
       (lambda (provider)
         (define listener (spawn ^listen-capture))
         (listen provider listener))
       #:catch
       (lambda (err) (async-channel-put response-ch `(err enliven ,err)))))

(define reply (sync/timeout 10.0 response-ch))
(case (and (pair? reply) (car reply))
  [(ok)
   (printf "LISTEN OK: live export fulfilled the listener~n")
   (exit 0)]
  [(err)
   (printf "LISTEN ERR: ~v~n" (cadr reply))
   (exit 1)]
  [else
   (printf "LISTEN TIMEOUT~n")
   (exit 1)])
