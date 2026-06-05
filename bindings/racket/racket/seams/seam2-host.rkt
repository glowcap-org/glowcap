#lang racket/base

;; Stack 2 HOST: a Goblins app on pancake's CapTP (captp.rkt) whose
;; bytes flow over Racket's own TCP sockets (racket-socket-netlayer).
;; Registers an echo actor at ECHO-SWISS-NUM on a TCP port.

(require goblins
         goblins/vat
         (file "../captp.rkt")
         (file "../racket-socket-netlayer.rkt"))

(define ECHO-SWISS-NUM
  (string->bytes/latin-1 "IO58l1laTyhcrgDKbEzFOO32MDd6zE5w"))

(define (^echo _bcom)
  (lambda args
    (printf "[echo] received ~v; echoing back~n" args)
    args))

(define listen-host "127.0.0.1")
(define listen-port
  (string->number (vector-ref (current-command-line-arguments) 0)))

(file-stream-buffer-mode (current-output-port) 'line)
(file-stream-buffer-mode (current-error-port) 'line)

(define a-vat (make-vat))
(a-vat
 'run
 (lambda ()
   (define nl (spawn ^racket-socket-netlayer listen-host listen-port))
   (define mycapn (spawn-mycapn nl))
   (define nonce-registry ($ mycapn 'get-registry))
   (define echo (spawn ^echo))
   ($ nonce-registry 'register echo ECHO-SWISS-NUM)
   (printf "[stack2-host] listening on ~a:~a (racket/tcp transport, pancake CapTP)~n"
           listen-host listen-port)
   (printf "[stack2-host] echo cap registered at swiss ~v~n"
           (bytes->string/latin-1 ECHO-SWISS-NUM))
   (printf "[stack2-host] ready~n")))

(sync (make-semaphore))
