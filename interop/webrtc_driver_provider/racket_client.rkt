#lang racket
;; Live WebRTC proofs for the Racket binding through the C provider, in order.
;;
;; Dial (ADR-0226): the binding installs `webrtc-provider` with its own
;; signaling, then an ordinary `runtime-connect` dials the Zig WebRTC answerer by
;; locator, fetches its greeter, and calls it.
;;
;; Listen (ADR-0232): the binding listens with `listen-webrtc`, the Zig WebRTC
;; offerer dials the listener, and the accepted session names the offerer's key.
;;
;; Each Zig peer is a separate process that speaks one JSON object per line on
;; stdio. This client's signaling authority writes to its stdin and reads its
;; stdout: the offer, the answer, and each local candidate out, the far peer's
;; offer or answer and candidates in. A line outside that protocol fails the
;; proof, and so does a peer that goes quiet.
;;
;; Needs `racket` plus the WebRTC library (`zig build webrtc-abi`) and both
;; peers (`zig build webrtc-answerer webrtc-offerer`). Run via
;; `zig build racket-webrtc-driver-provider`.

(require json
         racket/runtime-path
         "../../bindings/racket/glowcap.rkt"
         "../../bindings/racket/glowcap-webrtc.rkt"
         "../_common/racket/helpers.rkt")

(define-runtime-path bin-dir "../../zig-out/bin")

(define GATE "racket-webrtc-driver-provider")
(define WAIT-SECONDS 20)
(define GREETING "hello over webrtc")

(ignore-port-args GATE)

;; ── one Zig peer over stdio ─────────────────────────────────────────────────

(struct peer (proc from to))

;; Start the Zig binary `step` builds. Exiting the proof kills it, so a failed
;; step never leaves a peer running.
(define (spawn-peer step . args)
  (define path (simplify-path (build-path bin-dir (string-append "glowcap-" step))))
  (unless (file-exists? path)
    (fail GATE (format "missing ~a: run `zig build ~a`" path step)))
  (define-values (proc from to _stderr)
    (apply subprocess #f #f (current-error-port) (path->string path) args))
  (plumber-add-flush! (current-plumber) (lambda (_) (subprocess-kill proc #t)))
  (peer proc from to))

;; The peer's first line names its key designator.
(define (read-identity who p)
  (unless (sync/timeout WAIT-SECONDS (peer-from p))
    (fail GATE (format "no identity line from the ~a within ~a seconds" who WAIT-SECONDS)))
  (define line (read-line (peer-from p)))
  (define message
    (and (string? line) (with-handlers ([exn:fail? (lambda (_) #f)]) (string->jsexpr line))))
  (unless (and (hash? message) (equal? (hash-ref message 'type #f) "identity"))
    (fail GATE (format "the ~a did not open with an identity line: ~s" who line)))
  (hash-ref message 'designator))

;; Lines go to the peer from a writer thread, so a signaling procedure that must
;; not wait (the answer runs in atomic mode) only queues. `'close` ends the
;; peer's stdin once signaling is over.
(define (make-line-writer out)
  (define writer
    (thread
     (lambda ()
       (with-handlers ([exn:fail? (lambda (error)
                                    (fail GATE (format "writing to the peer failed: ~a"
                                                       (exn-message error))))])
         (let loop ()
           (define message (thread-receive))
           (cond
             [(eq? message 'close) (close-output-port out)]
             [else
              (write-json message out)
              (newline out)
              (flush-output out)
              (loop)]))))))
  (lambda (message) (thread-send writer message)))

;; Candidates that arrive before anyone subscribes wait here. A subscription
;; replays them and then receives each new one. Returns the procedure the pump
;; calls with a candidate's JSON text and the one `#:on-candidate` calls with
;; its sink, which gives back the thunk that ends the subscription.
(define (make-candidate-hub)
  (define lock (make-semaphore 1))
  (define pending '())
  (define sinks '())
  (define (deliver! text)
    (call-with-semaphore
     lock
     (lambda ()
       (if (null? sinks)
           (set! pending (append pending (list text)))
           (for ([sink (in-list sinks)]) (sink text))))))
  (define (subscribe! sink)
    (call-with-semaphore
     lock
     (lambda ()
       (for ([text (in-list pending)]) (sink text))
       (set! pending '())
       (set! sinks (cons sink sinks))))
    (lambda ()
      (call-with-semaphore lock (lambda () (set! sinks (remq sink sinks))))))
  (values deliver! subscribe!))

;; ── the stdout pump ─────────────────────────────────────────────────────────

;; Route every line of the peer's stdout. A line `route` rejects ends the pump
;; and its exception waits in `failure`, and a clean end means the peer closed
;; its stdout.
(struct pump (thread failure))

(define (start-pump p route)
  (define failure (box #f))
  (pump (thread
         (lambda ()
           (with-handlers ([(lambda (error) (not (exn:break? error)))
                            (lambda (error) (set-box! failure error))])
             (for ([line (in-lines (peer-from p))])
               (route (string->jsexpr line))))))
        failure))

(define (outside-protocol who message)
  (error 'pump "the ~a wrote a line outside the protocol: ~s" who message))

;; Run `thunk` unless the pump stops first. The failure names the line that
;; broke the protocol, or says the peer left early.
(define (unless-pump-stops pump-state what thunk)
  (define result (box #f))
  (define step
    (thread
     (lambda ()
       (set-box! result
                 (with-handlers ([(lambda (error) (not (exn:break? error)))
                                  (lambda (error) (cons 'raised error))])
                   (cons 'ok (thunk)))))))
  (sync/timeout WAIT-SECONDS (thread-dead-evt step) (thread-dead-evt (pump-thread pump-state)))
  (cond
    [(thread-dead? step)
     (define outcome (unbox result))
     (if (eq? (car outcome) 'ok) (cdr outcome) (raise (cdr outcome)))]
    [(thread-dead? (pump-thread pump-state))
     (kill-thread step)
     (define failure (unbox (pump-failure pump-state)))
     (fail GATE (if failure
                    (format "~a: ~a" what (exn-message failure))
                    (format "~a: the Zig peer closed its stdout first" what)))]
    [else
     (kill-thread step)
     (fail GATE (format "~a did not finish within ~a seconds" what WAIT-SECONDS))]))

;; ── dial ────────────────────────────────────────────────────────────────────

(define (dial-proof)
  (define answerer (spawn-peer "webrtc-answerer"))
  (define designator (read-identity "answerer" answerer))
  (define write! (make-line-writer (peer-to answerer)))
  (define-values (deliver! on-candidate) (make-candidate-hub))
  (define answer-box (box #f))
  (define answer-ready (make-semaphore 0))
  (define signaling
    (make-webrtc-signaling
     #:offer (lambda (_exchange _target sdp)
               (write! (hasheq 'type "offer" 'sdp sdp))
               (unless (sync/timeout WAIT-SECONDS answer-ready)
                 (fail GATE (format "no answer from the answerer within ~a seconds" WAIT-SECONDS)))
               (unbox answer-box))
     #:answer (lambda (_exchange _target _sdp) (error 'answer "this authority only dials"))
     #:candidate (lambda (_exchange ice)
                   (write! (hasheq 'type "candidate" 'candidate (string->jsexpr ice))))
     #:on-candidate (lambda (_exchange _target sink) (on-candidate sink))))
  (define pump-state
    (start-pump answerer
                (lambda (message)
                  (case (hash-ref message 'type #f)
                    [("answer")
                     (set-box! answer-box (hash-ref message 'sdp))
                     (semaphore-post answer-ready)]
                    [("candidate") (deliver! (jsexpr->string (hash-ref message 'candidate)))]
                    [else (outside-protocol "answerer" message)]))))
  (define runtime
    (open-runtime
     #:providers (list (webrtc-provider signaling
                                        (webrtc-config #:include-loopback-candidates? #t)))))
  (define reply
    (dynamic-wind
     void
     (lambda ()
       (unless-pump-stops
        pump-state "dial"
        (lambda ()
          (define session (runtime-connect runtime (webrtc-locator designator)))
          (dynamic-wind
           void
           (lambda () (session-send session (session-fetch session "greeter") 'greet))
           (lambda () (session-close! session))))))
     (lambda () (runtime-close! runtime))))
  (unless (and (string? reply) (positive? (string-length reply)))
    (fail GATE (format "greet returned ~s" reply)))
  (printf "~a: OK the Racket binding dialed the answerer and heard ~s\n" GATE reply))

;; ── listen ──────────────────────────────────────────────────────────────────

(define (listen-proof)
  ;; The authority exists before the offerer does, because the listener's
  ;; designator is the offerer's argument.
  (define writer-box (box #f))
  (define (write! message) ((unbox writer-box) message))
  (define-values (deliver! on-candidate) (make-candidate-hub))
  (define signaling
    (make-webrtc-signaling
     #:offer (lambda (_exchange _target _sdp) (error 'offer "this authority only answers"))
     #:answer (lambda (_exchange _target sdp) (write! (hasheq 'type "answer" 'sdp sdp)))
     #:candidate (lambda (_exchange ice)
                   (write! (hasheq 'type "candidate" 'candidate (string->jsexpr ice))))
     #:on-candidate (lambda (_exchange _target sink) (on-candidate sink))))
  (define server
    (listen-webrtc signaling (webrtc-config #:include-loopback-candidates? #t)))
  (dynamic-wind
   void
   (lambda ()
     (host-publish (webrtc-server-host server) "greeter" (methods [(greet) GREETING]))
     (define advertised (webrtc-server-locator server))
     (unless (and (equal? (locator-transport advertised) "webrtc")
                  (equal? (locator-designator advertised) (webrtc-server-designator server)))
       (fail GATE (format "the listener advertised ~s" advertised)))

     (define offerer (spawn-peer "webrtc-offerer" (webrtc-server-designator server)))
     (set-box! writer-box (make-line-writer (peer-to offerer)))
     (define offerer-designator (read-identity "offerer" offerer))
     (define pump-state
       (start-pump offerer
                   (lambda (message)
                     (case (hash-ref message 'type #f)
                       [("offer")
                        (webrtc-server-provide-offer! server offerer-designator
                                                      (hash-ref message 'sdp))]
                       [("candidate")
                        (deliver! (jsexpr->string (hash-ref message 'candidate)))]
                       [else (outside-protocol "offerer" message)]))))
     (define session
       (unless-pump-stops pump-state "accept" (lambda () (webrtc-server-accept server))))
     ;; The channel is open, so signaling is over: close the carrier.
     (write! 'close)
     (define partner (session-partner-identity session))
     (unless (and (equal? (partner-identity-designator partner) offerer-designator)
                  (partner-identity-durable-authenticated? partner))
       (fail GATE (format "the accepted session names ~s, not ~s"
                          (partner-identity-designator partner) offerer-designator)))
     ;; The offerer drops the carrier once it has its greeting, so serving ends
     ;; with a glowcap failure. Anything else serving raises fails the proof.
     (define serve-failure (box #f))
     (define serving
       (thread
        (lambda ()
          (with-handlers ([(lambda (error) (not (or (exn:break? error) (exn:fail:glowcap? error))))
                           (lambda (error) (set-box! serve-failure error))])
            (session-serve session)))))
     (unless (sync/timeout WAIT-SECONDS (peer-proc offerer))
       (fail GATE (format "the offerer did not exit within ~a seconds" WAIT-SECONDS)))
     (unless (zero? (subprocess-status (peer-proc offerer)))
       (fail GATE (format "the offerer exited with ~a" (subprocess-status (peer-proc offerer)))))
     (unless (sync/timeout WAIT-SECONDS (thread-dead-evt serving))
       (fail GATE "serving did not end after the offerer left"))
     (when (unbox serve-failure)
       (fail GATE (format "serving failed: ~a" (exn-message (unbox serve-failure)))))
     (printf "~a: OK the Racket binding accepted the offerer and named its key\n" GATE))
   ;; Closing the Host retires the accepted session with it.
   (lambda ()
     (webrtc-server-close! server)
     (host-close! (webrtc-server-host server)))))

(dial-proof)
(listen-proof)
