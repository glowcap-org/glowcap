#lang racket/base
;; One independently loadable family from the Racket binding dogfood.

(require racket/random
         "../../glowcap-tcp.rkt"
         "../../private/session.rkt"
         "../../private/session/establish.rkt"
         "../../private/host.rkt"
         "../../private/async.rkt"
         "../../private/constants.rkt"
         "support.rkt")

;; ── Two peers over a channel smaller than one frame ──────────────────────────
;; Each pipe holds 64 bytes, so every frame write waits for the partner to
;; read. Each side must keep reading while its own writer waits, or each waits
;; for the other to read: the handshake alone deadlocks. Four concurrent
;; 4096-byte echoes then cross in both directions at once.
(define-values (bp-forward-in bp-forward-out) (make-pipe 64))
(define-values (bp-backward-in bp-backward-out) (make-pipe 64))
(define bp-exporter (make-host (crypto-random-bytes 32)))
(define bp-dialer (make-host (crypto-random-bytes 32)))
(host-publish bp-exporter "echo" (lambda (_method . args) (car args)))
(define bp-accepted-ch (make-channel))
(void
 (thread
  (lambda ()
    (channel-put
     bp-accepted-ch
     (with-handlers ([exn? values])
       (establish-accepted-session bp-exporter "tcp" "127.0.0.1:9011"
                                   (port-transport bp-forward-in bp-backward-out)
                                   #:designator-scheme DESIGNATOR-SCHEME-ADDRESS
                                   #:handshake-timeout-ms 5000))))))
(define bp-dialed
  (establish-dialed-locator-session bp-dialer (tcp-locator "127.0.0.1" 9011)
                                    (port-transport bp-backward-in bp-forward-out)
                                    #:handshake-timeout-ms 5000))
(define bp-accepted (channel-get bp-accepted-ch))
(when (exn? bp-accepted) (raise bp-accepted))
(define bp-serving
  (for/list ([c (list bp-accepted bp-dialed)])
    (thread (lambda () (with-handlers ([exn:fail? void]) (session-serve c))))))
(define bp-echo (session-fetch bp-dialed "echo"))
(define bp-replies (make-channel))
(for ([index (in-range 4)])
  (thread
   (lambda ()
     (define payload (make-bytes 4096 index))
     (channel-put bp-replies
                  (with-handlers ([exn? values])
                    (equal? payload (session-send bp-dialed bp-echo 'echo payload)))))))
(define bp-results (for/list ([_ (in-range 4)]) (sync/timeout 10 bp-replies)))
(expect (andmap (lambda (result) (eq? result #t)) bp-results)
        (format "a pipe smaller than a frame carries both directions at once: ~s" bp-results))
(host-close! bp-dialer)
(host-close! bp-exporter)
(for ([t (in-list bp-serving)]) (sync/timeout 5 t))
