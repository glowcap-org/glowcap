#lang racket/base

;; tcp-bridge.rkt — wires a PancakePeer to a PancakeEndpointTcp.
;;
;; Pre-Matrix-#3 this file owned the socket lifecycle, the reader
;; thread that parsed Syrup frame boundaries via syrup-framing.rkt,
;; and the pump thread that drove feed_inbound / step /
;; take_outbound / write-to-socket. ~160 lines of concurrency-
;; careful code per binding.
;;
;; Post-Matrix-#3: pancake-ffi owns the socket + Syrup framing
;; through `pancake_endpoint_tcp_*`. This file is now one Racket
;; thread that polls in a loop:
;;
;;   1. read_frame with a short timeout (50 ms); on WOULD_BLOCK,
;;      proceed without inbound.
;;   2. step + drain take_outbound to write_frame.
;;   3. Repeat until close.
;;
;; Single-thread design (vs. the dual reader/step threads earlier
;; drafts of this file used) avoids the Racket-FFI deadlock where
;; one Racket thread blocked inside a Rust syscall would starve
;; the green-thread scheduler. The endpoint surface's read-timeout
;; setter (`pancake_endpoint_tcp_set_read_timeout_ms`) lets the
;; poll loop yield back to Racket's scheduler between reads.

(provide start-tcp-bridge!
         stop-tcp-bridge!
         tcp-bridge-peer
         tcp-bridge-stopped?
         (struct-out tcp-bridge))

(require "pancake-ffi.rkt")

;; Read timeout in milliseconds — how long read_frame waits
;; before returning WOULD_BLOCK. Trade-off: shorter = more
;; responsive to other Racket threads but more syscalls; longer
;; = less CPU but laggier handshakes.
(define READ-TIMEOUT-MS 50)

(struct tcp-bridge
  (peer                ; PancakePeer FFI handle (owner of accessor calls)
   endpoint            ; PancakeEndpointTcp FFI handle (owned by bridge)
   pump-thread         ; the single Racket thread that pumps
   stop-evt)           ; semaphore the bridge signals on close
  #:transparent)

(define (tcp-bridge-stopped? bridge)
  (sync/timeout 0 (semaphore-peek-evt (tcp-bridge-stop-evt bridge))))

;; Start a bridge for an already-constructed peer + endpoint.
;;
;; The bridge:
;;   1. Sets the endpoint's read-timeout so the poll loop yields
;;      back to Racket between reads.
;;   2. Calls pancake-peer-send-start-session on `peer` with the
;;      supplied transport+designator.
;;   3. Spawns the pump thread (one).
;;   4. Returns a tcp-bridge handle.
;; The caller continues to own `peer` for accessor calls
;; (session-state, poll-event-*) but MUST NOT call
;; feed_inbound / take_outbound / step / read_frame / write_frame
;; itself — those belong to the pump.
;;
;; The bridge OWNS `endpoint` and closes it in stop-tcp-bridge!.
;;
;; Keyword args:
;;   #:peer        — PancakePeer FFI handle
;;   #:endpoint    — PancakeEndpointTcp FFI handle (bridge takes ownership)
;;   #:transport, #:designator — both required.
;;   #:label       — diagnostic label included in error messages.
(define (start-tcp-bridge! #:peer peer
                           #:endpoint endpoint
                           #:transport transport
                           #:designator designator
                           #:label [label "bridge"])
  (pancake-endpoint-tcp-set-read-timeout-ms endpoint READ-TIMEOUT-MS)
  (define stop-sem (make-semaphore 0))

  ;; Kick the handshake. The peer's stored keypair (if any)
  ;; drives whether the outbound StartSession is signed.
  (pancake-peer-send-start-session peer transport designator)

  (define pump
    (thread
      (lambda ()
        (let loop ()
          ;; 1. Try one inbound frame (poll-style; returns
          ;; 'would-block after READ-TIMEOUT-MS if nothing ready).
          (define frame (pancake-endpoint-tcp-read-frame endpoint))
          (case frame
            [(would-block) (void)] ; no inbound this tick
            [(closed eof)
             (semaphore-post stop-sem)
             (kill-thread (current-thread))]
            [(malformed)
             (eprintf "[~a] malformed inbound frame; bridge stopping~n" label)
             (semaphore-post stop-sem)
             (kill-thread (current-thread))]
            [else
             (cond
               [(bytes? frame) (pancake-peer-feed-inbound peer frame)]
               [else
                (eprintf "[~a] unexpected read_frame ~v; bridge stopping~n"
                         label frame)
                (semaphore-post stop-sem)
                (kill-thread (current-thread))])])
          ;; 2. Step + drain outbound.
          (pancake-peer-step peer)
          (let drain ()
            (define out (pancake-peer-take-outbound peer))
            (when out
              (pancake-endpoint-tcp-write-frame endpoint out)
              (drain)))
          ;; 3. Check for graceful close.
          (cond
            [(= (pancake-peer-session-state peer) PANCAKE_SESSION_CLOSED)
             (semaphore-post stop-sem)]
            [else
             ;; Yield to other Racket green threads. Racket's
             ;; scheduler doesn't preempt across FFI calls, and
             ;; (sleep 0) isn't always treated as a yield point;
             ;; (sleep 0.001) is the smallest reliable yield that
             ;; lets caller-side accessor threads run.
             (sleep 0.001)
             (loop)])))))

  (tcp-bridge peer endpoint pump stop-sem))

(define (stop-tcp-bridge! bridge)
  (semaphore-post (tcp-bridge-stop-evt bridge))
  (with-handlers ([exn? (lambda (_) (void))])
    (kill-thread (tcp-bridge-pump-thread bridge))
    ;; Close the endpoint — unblocks anyone still reading; releases
    ;; the underlying socket.
    (pancake-endpoint-tcp-close (tcp-bridge-endpoint bridge))))
