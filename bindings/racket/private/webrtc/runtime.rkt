#lang racket/base
;; The WebRTC signaling exchanges for the driver loop.
;;
;; The netlayer calls four functions while it signals for the driver: send the
;; offer of a dial, send the answer of an accept, send a local candidate, and
;; tell us the exchange is over. Each runs inside `glowcap_driver_step` or, for
;; an answer, inside `glowcap_webrtc_netlayer_provide_offer`, on the Racket
;; thread that made the call, in atomic mode, so each returns at once and
;; starts threads instead of waiting. The application's signaling procedures
;; can wait, so they run in Racket threads that hand the far peer's answer and
;; candidates back with the `provide` verbs. The one exception is `answer`,
;; which the application runs inside the callback because its failure refuses
;; the offer. Racket threads share one OS thread, a foreign call in progress
;; is never preempted, and the callbacks are atomic, so those verbs cannot
;; overlap a step. The exchange table is the one authority on which exchanges
;; are live. A thread checks it and calls the verb in one atomic section, so a
;; late answer never reaches a netlayer the driver has let go.
;;
;; A signaling procedure that raises records its error on the Host, as any
;; detached failure does, and gives its exchange up, so a dial fails at the
;; driver's next step instead of at the handshake deadline. An exchange ends
;; one way, in `end!`, whether the driver finished it or its callback failed.

(require ffi/unsafe
         ffi/unsafe/atomic
         racket/lazy-require
         "../constants.rkt"
         "../errors.rkt"
         "../ffi-webrtc.rkt"
         "../host/state.rkt"
         "../seam.rkt"
         "netlayer.rkt")

(lazy-require ["../loop.rkt" (driver-loop-add-provider! driver-loop-host loop-ffi-live?)])

(provide webrtc-adopt-loop!
         make-exchange-callbacks
         (struct-out exchange-callbacks)
         (struct-out exchange-verbs)
         netlayer-verbs
         (struct-out signaling)
         (struct-out webrtc-target))

;; The peer one exchange is with. For a dial, `designator` is the dialed
;; locator's and `introducer` is the designator of the session that handed over
;; the reference this dial follows, so the application can carry signaling
;; through the party that knows the peer. It is `#f` for a dial the application
;; started itself or whose introducing session signed no designator, and for
;; every accept, whose `designator` is the offerer `provide-offer` named.
(struct webrtc-target (designator introducer) #:transparent)

;; The application's signaling, four procedures. Every one routes by the
;; exchange id the library minted, an exact integer. `offer` takes an exchange,
;; a target, and an SDP offer and returns the SDP answer. `answer` takes an
;; exchange, a target, and the SDP answer to an inbound offer and carries it to
;; the offerer, and raising refuses that offer. `candidate` takes an exchange
;; and one ICE candidate as JSON text. `on-candidate` takes an exchange, a
;; target, and a sink procedure, calls the sink with each of that exchange's
;; far candidates, and returns a thunk that ends the subscription. Two
;; exchanges with one target run side by side with distinct ids.
(struct signaling (offer answer candidate on-candidate))

;; A live exchange: the thunk that ends its candidate subscription, set once
;; the subscription exists.
(struct exchange ([dispose #:mutable]))

;; The four verbs an exchange uses to reach the netlayer. Each takes the
;; netlayer first. `provide-offer!` takes the offerer's designator and the SDP
;; offer and returns the accept's exchange id, `provide-answer!` and
;; `provide-candidate!` take an exchange id and text, and `fail-exchange!` takes
;; an exchange id.
(struct exchange-verbs (provide-offer! provide-answer! provide-candidate! fail-exchange!))

(define netlayer-verbs
  (exchange-verbs webrtc-netlayer-provide-offer!
                  webrtc-netlayer-provide-answer!
                  webrtc-netlayer-provide-candidate!
                  webrtc-netlayer-fail-exchange!))

;; The exchange logic as plain procedures. `send-offer` takes an id, a target,
;; and an SDP offer. `send-answer` takes an id, a target, and an SDP answer.
;; Both return `OK` or `ERR-IO`. `send-candidate` takes an id and candidate
;; text and returns the same. `done` takes an id. `set-netlayer!` names the
;; netlayer the verbs receive, once it exists. `provide-offer` and
;; `fail-exchange` are the application's two verbs, `provide-offer` taking a
;; designator and an SDP offer and returning the exchange id, `fail-exchange`
;; taking an id. Each raises on refusal.
(struct exchange-callbacks (send-offer send-answer send-candidate done set-netlayer!
                                       provide-offer fail-exchange))

;; The state a loop keeps for its WebRTC netlayers. The netlayer owns the
;; function pointers the C side calls. Keying on the loop keeps them reachable
;; for as long as the loop is.
(define retained (make-ephemeron-hasheq))

;; An invalid-argument refusal from the netlayer names an exchange that is not
;; signaling, which is a late arrival and no failure.
(define (no-such-exchange? error)
  (and (exn:fail:glowcap? error) (= (exn:fail:glowcap-code error) ERR-INVALID-ARGUMENT)))

;; Run `thunk` in one atomic section and return its value, or raise what it
;; raised after the section ends.
(define (atomically thunk)
  (start-atomic)
  (define outcome
    (with-handlers ([(lambda (_) #t) (lambda (error) (lambda () (raise error)))])
      (let ([value (thunk)]) (lambda () value))))
  (end-atomic)
  (outcome))

;; `open?` says whether the netlayer is still usable for the application's two
;; verbs, which need no live exchange to prove it.
(define (make-exchange-callbacks sig record! [verbs netlayer-verbs] [open? (lambda () #t)])
  (define live (make-hasheqv))
  (define netlayer-box (box #f))

  ;; Call `proc` with the netlayer for a live exchange in one atomic section.
  ;; A late arrival does nothing. A failure of the call itself is recorded,
  ;; because the caller is a detached thread. Returns whether the call failed.
  (define (call-live! id proc)
    (define failure
      (with-handlers ([(lambda (_) #t) values])
        (atomically
         (lambda ()
           (when (hash-ref live id #f)
             (proc (unbox netlayer-box)))))
        #f))
    (when failure (record! failure))
    (and failure #t))
  (define (fail-live! id)
    (call-live! id (lambda (netlayer)
                     (with-handlers ([no-such-exchange? void])
                       ((exchange-verbs-fail-exchange! verbs) netlayer id)))))
  ;; A refused answer means the dial cannot proceed, so it gives the dial up. A
  ;; refused candidate costs one candidate and leaves the dial running.
  (define (provide-answer! id text)
    (when (call-live! id (lambda (netlayer)
                           ((exchange-verbs-provide-answer! verbs) netlayer id text)))
      (fail-live! id)))
  (define (provide-candidate! id text)
    (call-live! id (lambda (netlayer)
                     ((exchange-verbs-provide-candidate! verbs) netlayer id text)))
    (void))

  ;; Run signaling for exchange `id` on its own thread. Its failure is
  ;; recorded and gives the exchange up. `#f` names no exchange.
  (define (detached id thunk)
    (thread
     (lambda ()
       (with-handlers ([(lambda (error) (not (exn:break? error)))
                        (lambda (error)
                          (record! error)
                          (when id (fail-live! id)))])
         (thunk)))))

  ;; Subscribe to the far peer's candidates for exchange `id`. Returns whether
  ;; the exchange is still live, because one the driver already ended needs no
  ;; subscription.
  (define (subscribe! id ex target)
    (define dispose
      ((signaling-on-candidate sig) id target
       (lambda (ice) (provide-candidate! id ice))))
    (start-atomic)
    (define ended? (not (eq? (hash-ref live id #f) ex)))
    (unless ended? (set-exchange-dispose! ex dispose))
    (end-atomic)
    (when ended? (dispose))
    (not ended?))

  ;; The one place an exchange ends. `only` limits it to that entry, so a
  ;; refusal never ends an exchange it did not add.
  (define (end! id only)
    (define ex (hash-ref live id #f))
    (when (and ex (or (not only) (eq? ex only)))
      (hash-remove! live id)
      (define dispose (exchange-dispose ex))
      (when dispose (detached #f dispose))))
  (define (end-recording! id only)
    (with-handlers ([(lambda (_) #t) record!])
      (end! id only)))

  ;; Open exchange `id` for `target`. A thread of its own subscribes to the far
  ;; peer's candidates and then runs `subscribed`. `step` runs now, and
  ;; whatever it raises refuses the exchange. A reused id is refused and leaves
  ;; the existing exchange alone. Returns `OK` or `ERR-IO`.
  (define (open-exchange! id target subscribed step)
    (cond
      [(hash-ref live id #f) ERR-IO]
      [else
       (define ex (exchange #f))
       (hash-set! live id ex)
       (with-handlers ([(lambda (_) #t)
                        (lambda (error)
                          (end-recording! id ex)
                          (record! error)
                          ERR-IO)])
         (detached id (lambda () (when (subscribe! id ex target) (subscribed))))
         (step)
         OK)]))

  (define (send-offer id target sdp)
    (open-exchange! id target
                    (lambda () (provide-answer! id ((signaling-offer sig) id target sdp)))
                    void))

  (define (send-answer id target sdp)
    (open-exchange! id target void
                    (lambda () ((signaling-answer sig) id target sdp))))

  (define (send-candidate id text)
    (with-handlers ([(lambda (_) #t) (lambda (error) (record! error) ERR-IO)])
      (cond
        [(hash-ref live id #f)
         (detached id (lambda () ((signaling-candidate sig) id text)))
         OK]
        [else ERR-IO])))

  (define (done id)
    (end-recording! id #f)
    (void))

  (define (require-open!)
    (unless (and (open?) (unbox netlayer-box))
      (raise-glowcap 'webrtc ERR-CLOSED "the webrtc netlayer is not open")))

  (define (provide-offer designator sdp)
    (atomically
     (lambda ()
       (require-open!)
       ((exchange-verbs-provide-offer! verbs) (unbox netlayer-box) designator sdp))))

  (define (fail-exchange id)
    (atomically
     (lambda ()
       (require-open!)
       ((exchange-verbs-fail-exchange! verbs) (unbox netlayer-box) id))))

  (exchange-callbacks send-offer send-answer send-candidate done
                      (lambda (netlayer) (set-box! netlayer-box netlayer))
                      provide-offer fail-exchange))

;; Install one WebRTC netlayer on the driver loop `lp` and return its
;; callbacks, whose `provide-offer` and `fail-exchange` are the application's
;; verbs. A provider that only dials and a listener share this one install.
(define (webrtc-adopt-loop! lp ice-servers loopback? sig)
  (define host (driver-loop-host lp))
  (define (record! error)
    (when host (record-host-runtime-failure! host error)))
  (define callbacks
    (make-exchange-callbacks sig record! netlayer-verbs (lambda () (loop-ffi-live? lp))))

  ;; Decode one borrowed C view into text, once.
  (define (text ptr len) (bytes->string/utf-8 (bytes<-c ptr len)))
  ;; A callback with no result channel records its failure and refuses.
  (define (guarded thunk)
    (with-handlers ([(lambda (_) #t) (lambda (error) (record! error) ERR-IO)])
      (thunk)))

  (define send-offer
    (function-ptr
     (lambda (_ctx id designator designator-len introducer introducer-len sdp sdp-len)
       (guarded
        (lambda ()
          ((exchange-callbacks-send-offer callbacks)
           id
           (webrtc-target
            (text designator designator-len)
            (and (positive? introducer-len) (text introducer introducer-len)))
           (text sdp sdp-len)))))
     _GlowcapWebrtcSendOfferFn))

  (define send-answer
    (function-ptr
     (lambda (_ctx id designator designator-len sdp sdp-len)
       (guarded
        (lambda ()
          ((exchange-callbacks-send-answer callbacks)
           id
           (webrtc-target (text designator designator-len) #f)
           (text sdp sdp-len)))))
     _GlowcapWebrtcSendAnswerFn))

  (define send-candidate
    (function-ptr
     (lambda (_ctx id ice ice-len)
       (guarded
        (lambda ()
          ((exchange-callbacks-send-candidate callbacks) id (text ice ice-len)))))
     _GlowcapWebrtcSendCandidateFn))

  (define done
    (function-ptr
     (lambda (_ctx id) ((exchange-callbacks-done callbacks) id))
     _GlowcapWebrtcExchangeDoneFn))

  (define-values (netlayer package close!)
    (webrtc-loop-provider-parts ice-servers loopback? send-offer send-answer send-candidate done))
  ((exchange-callbacks-set-netlayer! callbacks) netlayer)
  (with-handlers ([(lambda (_) #t) (lambda (e) (close!) (raise e))])
    (driver-loop-add-provider! lp package)
    (hash-update! retained lp (lambda (old) (cons netlayer old)) '())
    ;; Registration retained the callback context. Drop only the constructor's
    ;; reference. The raw handle stays for the exchange verbs while the loop
    ;; lives, which needs the driver's lease.
    (webrtc-netlayer-release! netlayer))
  callbacks)
