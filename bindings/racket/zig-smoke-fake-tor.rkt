#lang racket/base
;; A fake Tor daemon for `zig-smoke.rkt`, run as a child process.
;;
;; It answers the exact control and SOCKS requests the onion transport sends, so
;; the smoke needs no Tor and no network. The bytes it replays are pinned on the
;; Zig side, in `test/net/onion_control_test.zig` and
;; `test/net/onion_socks5_test.zig`, against the pinned Spritely Goblins netlayer
;; and the upstream OCapN suite. A green run here means the Racket surface reached
;; those bytes, never that a real Tor answers the same way.
;;
;; **This is a separate process because Racket cannot serve one in-process.** A
;; foreign call marked `#:blocking?` tells the runtime it may block, so the
;; collector stays cooperative; it does not hand the scheduler to another Racket
;; thread. Every green thread in the place stops for the whole call. `listen` and
;; `accept` on the onion transport are such calls, and each waits on an answer from
;; this daemon, so a daemon written as a thread beside them would be waiting for a
;; scheduler that cannot run until it replies. That is a deadlock, not a slow test.
;; A caller with its own loop stays off those calls entirely by selecting on the
;; readiness descriptor both handles expose.
;;
;; The parent reads this process's stdout, one line-oriented record per event:
;;
;;   control <host:port>   the control endpoint, printed once at startup
;;   socks <host:port>     the SOCKS endpoint, printed once at startup
;;   line <text>           a control line the daemon received
;;   wrote <text>          the first bytes a dialer sent after the SOCKS reply
;;
;; It runs until the parent kills it.

(require racket/tcp)

;; A real, checksum-valid version 3 id, from the pinned Goblins source. Using a
;; well-formed one matters: the transport refuses anything else before it opens a
;; socket, so a placeholder would pass for the wrong reason.
(define service-id "wy46gxdweyqn5m7ntzwlxinhdia2jjanlsh37gxklwhfec7yxqr4k3qd")
(define service-key "ED25519-V3:c3RvcmVk")

(define (report fmt . args)
  (apply printf fmt args)
  (flush-output))

(define (listen-loopback)
  (define listener (tcp-listen 0 4 #t "127.0.0.1"))
  (define-values (_host port _peer-host _peer-port) (tcp-addresses listener #t))
  (values listener port))

;; Answer control conversations. pancake holds one open for a listener's whole
;; life, so each gets its own thread and the loop keeps accepting.
(define (serve-control listener)
  (let accept-loop ()
    (define-values (in out) (tcp-accept listener))
    (thread
     (lambda ()
       (let loop ()
         (define line (read-line in 'any))
         (unless (eof-object? line)
           (report "line ~a\n" line)
           (if (regexp-match #rx"^ADD_ONION" line)
               (fprintf out "250-ServiceID=~a\r\n250-PrivateKey=~a\r\n250 OK\r\n"
                        service-id service-key)
               (fprintf out "250 OK\r\n"))
           (flush-output out)
           (loop)))))
    (accept-loop)))

;; Answer one SOCKS5 handshake, then report the first bytes the dialer sent.
;;
;; The daemon does not proxy. A real Tor splices the circuit onto the service's
;; forward target; what the transport owes is that the stream is a transparent byte
;; pipe positioned after the reply, so this stands in for the far peer directly.
(define (serve-socks listener)
  (let accept-loop ()
    (define-values (in out) (tcp-accept listener))
    (thread
     (lambda ()
       ;; Version 5, one method, no authentication.
       (read-bytes 3 in)
       (write-bytes (bytes 5 0) out)
       (flush-output out)
       ;; Four header bytes, the length byte, the 62-character address, the port.
       (read-bytes 69 in)
       ;; Success, reserved, IPv4, then the null bound address Tor reports.
       (write-bytes (bytes 5 0 0 1 0 0 0 0 0 0) out)
       (flush-output out)
       (define buf (make-bytes 256))
       (define n (read-bytes-avail! buf in))
       (unless (eof-object? n)
         (report "wrote ~a\n" (bytes->string/utf-8 (subbytes buf 0 n) #\?)))))
    (accept-loop)))

(define-values (control-listener control-port) (listen-loopback))
(define-values (socks-listener socks-port) (listen-loopback))
(report "control 127.0.0.1:~a\n" control-port)
(report "socks 127.0.0.1:~a\n" socks-port)
(thread (lambda () (serve-socks socks-listener)))
(serve-control control-listener)
