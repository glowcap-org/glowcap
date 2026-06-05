#lang racket/base

;; pancake-iroh-goblins-netlayer.rkt — a Goblins netlayer (the stock
;; OCapN netlayer protocol) whose transport is pancake's QUIC-over-iroh
;; endpoint. This is STACK 4: stock `goblins/ocapn/captp` (Spritely's
;; own OCapN/CapTP) running unmodified on top of a pancake-provided
;; netlayer. pancake supplies ONLY the byte transport here; Goblins
;; does the Syrup codec, the marshalling, and all of CapTP.
;;
;; It implements the same actor protocol as Spritely's own netlayers
;; (see goblins/ocapn/netlayer/fake-intarwebs.rkt):
;;
;;   (netlayer-name)            -> 'iroh
;;   (our-location)             -> (ocapn-node 'iroh <endpoint-id> #f)
;;   (self-location? loc)       -> same-node-location? against ours
;;   (setup conn-establisher)   -> start accept loop; transition to ready
;;   (connect-to remote-node)   -> dial; hand (read-message write-message)
;;                                  to conn-establisher
;;
;; The netlayer seam is `read-write-procs`: stock captp drives
;; `(read-message unmarshallers)` / `(write-message msg marshallers)`
;; on dedicated syscaller-free threads (captp.rkt new-connection). Each
;; OCapN message is exactly one self-delimiting Syrup value — which is
;; exactly one pancake frame — so the bridge is just:
;;   read-message  = poll pancake iroh read_frame, syrup-read the bytes
;;   write-message = syrup-write to a buffer, pancake iroh write_frame
;; No Racket-side framing or extra reader threads: captp owns the
;; threading, pancake owns the bytes + frame boundaries.
;;
;; Addressing: iroh peers are named by base32 EndpointId (the node
;; designator). With discovery off (loopback), the dialer also needs a
;; direct UDP "host:port" hint — registered out-of-band via the
;; `register-peer-addr!` method (in production, iroh discovery resolves
;; EndpointId -> addr and the hint is unnecessary).

(provide ^pancake-iroh-goblins-netlayer
         (rename-out [^pancake-iroh-goblins-netlayer ^iroh-netlayer]))

(require racket/match
         goblins
         goblins/actor-lib/methods
         (submod goblins/core np-extern)   ; <-np-extern: send into the vat from a plain thread
         goblins/ocapn/structs-urls        ; ocapn-node, same-node-location?
         syrup
         "pancake-ffi.rkt")

;; Poll cadence for the blocking read/accept FFI calls — bounds how
;; long a syscaller-free thread sits inside Rust before yielding.
(define POLL-MS 50)

;; Build the (read-message write-message) seam over one iroh conn.
(define (iroh-conn->message-procs conn)
  (pancake-endpoint-iroh-set-read-timeout-ms conn POLL-MS)
  (define (read-message unmarshallers)
    (let loop ()
      (define f (pancake-endpoint-iroh-read-frame conn))
      (cond
        [(bytes? f) (syrup-read (open-input-bytes f) #:unmarshallers unmarshallers)]
        [(eq? f 'would-block) (sleep 0.001) (loop)]
        [(eq? f 'closed) eof]
        [(eq? f 'malformed)
         (error 'pancake-iroh-goblins-netlayer "malformed inbound Syrup frame")]
        [else (error 'pancake-iroh-goblins-netlayer "unexpected read-frame ~a" f)])))
  (define (write-message msg marshallers)
    (define buf (open-output-bytes))
    (syrup-write msg buf #:marshallers marshallers)
    (pancake-endpoint-iroh-write-frame conn (get-output-bytes buf)))
  (values read-message write-message))

(define (^pancake-iroh-goblins-netlayer bcom)
  (define ep (pancake-endpoint-iroh-new))
  (define our-id (pancake-endpoint-iroh-endpoint-id ep))
  (define our-addr (pancake-endpoint-iroh-bound-addr ep))
  (define our-loc (ocapn-node 'iroh our-id #f))
  ;; EndpointId -> direct "host:port" for no-discovery loopback dials.
  (define peer-addrs (make-hash))
  (define listener (pancake-endpoint-iroh-listen ep))

  ;; Accept loop runs OUTSIDE the vat (a plain thread has no
  ;; syscaller); it forwards each accepted connection's seam into the
  ;; vat via <-np-extern, exactly as captp's own reader threads do.
  (define (start-listening conn-establisher)
    (thread
      (lambda ()
        (let loop ()
          (with-handlers ([exn?
                           (lambda (e)
                             (eprintf "[pancake-iroh-goblins-netlayer] accept failed: ~a~n"
                                      (exn-message e)))])
            (define c (pancake-endpoint-iroh-accept-timed listener POLL-MS))
            (cond
              [(eq? c 'would-block) (sleep 0.001)]
              [else
               (define-values (rm wm) (iroh-conn->message-procs c))
               (<-np-extern conn-establisher rm wm #f)]))
          (loop)))))

  (define base-beh
    (methods
     [(netlayer-name) 'iroh]
     [(our-location) our-loc]
     ;; iroh-specific surface so a dialer can locate this listener.
     [(endpoint-id) our-id]
     [(bound-addr) our-addr]
     ;; Loopback-only: tell this netlayer how to reach an EndpointId
     ;; without discovery (id -> "host:port").
     [(register-peer-addr! id addr) (hash-set! peer-addrs id addr)]))

  (define (ready-beh conn-establisher)
    (methods
     #:extends base-beh
     [(self-location? loc) (same-node-location? our-loc loc)]
     [(connect-to remote-node)
      (match remote-node
        [(ocapn-node 'iroh designator _hints)
         (define addr (hash-ref peer-addrs designator #f))
         ;; The dial is a (fast, loopback) blocking FFI call done inline
         ;; in the vat turn, then we return the conn-establisher's
         ;; promise — captp's connect path needs the vow that resolves
         ;; to the remote bootstrap object (mirrors fake-intarwebs's
         ;; `(on ... #:promise? #t)` shape; `<-np-extern` is
         ;; fire-and-forget and yields no vow, so it's wrong here).
         (define c (pancake-endpoint-iroh-connect ep designator addr))
         (define-values (rm wm) (iroh-conn->message-procs c))
         (<- conn-establisher rm wm remote-node)]
        [_ (error 'pancake-iroh-goblins-netlayer
                  "connect-to: not an iroh ocapn-node: ~v" remote-node)])]))

  (define pre-setup-beh
    (methods
     #:extends base-beh
     [(setup conn-establisher)
      (start-listening conn-establisher)
      (bcom (ready-beh conn-establisher))]))

  pre-setup-beh)
