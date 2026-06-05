#lang racket/base

;; pancake-tcp-tls-goblins-netlayer.rkt — a Goblins netlayer (stock
;; OCapN netlayer protocol) whose transport is pancake's TCP+TLS
;; endpoint. Pairs with STACK 3 (pancake OCapN over pancake TLS) as the
;; dialer/host that stock `goblins/ocapn/captp` plugs into unmodified.
;;
;; Same shape as pancake-iroh-goblins-netlayer.rkt (the proven stack-4
;; netlayer) — the only differences are the FFI entry points (rustls
;; TCP instead of QUIC-over-iroh) and addressing: TLS peers are named
;; by "host:port", which is directly dialable, so there's no
;; EndpointId->addr hint table (iroh needs one without discovery).
;;
;; The netlayer seam is `read-message`/`write-message` (syrup-read /
;; syrup-write); pancake frames are exactly one self-delimiting Syrup
;; value, so the bridge is: read = poll tls read_frame + syrup-read;
;; write = syrup-write to a buffer + tls write_frame. captp drives
;; these on its own syscaller-free threads.

(provide ^pancake-tcp-tls-goblins-netlayer
         (rename-out [^pancake-tcp-tls-goblins-netlayer ^tcp-tls-netlayer]))

(require racket/match
         racket/string
         goblins
         goblins/actor-lib/methods
         (submod goblins/core np-extern)
         goblins/ocapn/structs-urls
         syrup
         "pancake-ffi.rkt")

(define POLL-MS 50)

(define (tls-conn->message-procs conn)
  (pancake-endpoint-tcp-tls-set-read-timeout-ms conn POLL-MS)
  (define (read-message unmarshallers)
    (let loop ()
      (define f (pancake-endpoint-tcp-tls-read-frame conn))
      (cond
        [(bytes? f) (syrup-read (open-input-bytes f) #:unmarshallers unmarshallers)]
        [(eq? f 'would-block) (sleep 0.001) (loop)]
        [(eq? f 'closed) eof]
        [(eq? f 'malformed)
         (error 'pancake-tcp-tls-goblins-netlayer "malformed inbound Syrup frame")]
        [else (error 'pancake-tcp-tls-goblins-netlayer "unexpected read-frame ~a" f)])))
  (define (write-message msg marshallers)
    (define buf (open-output-bytes))
    (syrup-write msg buf #:marshallers marshallers)
    (pancake-endpoint-tcp-tls-write-frame conn (get-output-bytes buf)))
  (values read-message write-message))

(define (^pancake-tcp-tls-goblins-netlayer bcom listen-host listen-port)
  (define our-designator (format "~a:~a" listen-host listen-port))
  (define our-loc (ocapn-node 'tcp-tls our-designator #f))
  (define listener (pancake-endpoint-tcp-tls-listen listen-host listen-port))

  (define (start-listening conn-establisher)
    (thread
      (lambda ()
        (let loop ()
          (with-handlers ([exn?
                           (lambda (e)
                             (eprintf "[pancake-tcp-tls-goblins-netlayer] accept failed: ~a~n"
                                      (exn-message e)))])
            (define c (pancake-endpoint-tcp-tls-accept-timed listener POLL-MS))
            (cond
              [(eq? c 'would-block) (sleep 0.001)]
              [else
               (define-values (rm wm) (tls-conn->message-procs c))
               (<-np-extern conn-establisher rm wm #f)]))
          (loop)))))

  (define base-beh
    (methods
     [(netlayer-name) 'tcp-tls]
     [(our-location) our-loc]))

  (define (ready-beh conn-establisher)
    (methods
     #:extends base-beh
     [(self-location? loc) (same-node-location? our-loc loc)]
     [(connect-to remote-node)
      (match remote-node
        [(ocapn-node 'tcp-tls designator _hints)
         (define parts (string-split designator ":"))
         (define host (car parts))
         (define port (string->number (cadr parts)))
         ;; "host:port" is directly dialable (loopback-fast blocking
         ;; FFI inline in the vat turn); return the conn-establisher's
         ;; vow, like the iroh netlayer.
         (define c (pancake-endpoint-tcp-tls-connect host port))
         (define-values (rm wm) (tls-conn->message-procs c))
         (<- conn-establisher rm wm remote-node)]
        [_ (error 'pancake-tcp-tls-goblins-netlayer
                  "connect-to: not a tcp-tls ocapn-node: ~v" remote-node)])]))

  (define pre-setup-beh
    (methods
     #:extends base-beh
     [(setup conn-establisher)
      (start-listening conn-establisher)
      (bcom (ready-beh conn-establisher))]))

  pre-setup-beh)
