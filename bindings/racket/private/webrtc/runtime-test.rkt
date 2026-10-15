#lang racket/base
;; The signaling exchange logic, driven with fake verbs and no loop or C
;; library. Every wait on a detached thread is bounded, and a count that must
;; stay put is read after the thread that could change it has died.

(require rackunit
         "../constants.rkt"
         (only-in "../errors.rkt" raise-glowcap exn:fail:glowcap? exn:fail:glowcap-code)
         "runtime.rkt")

(define deadline-seconds 5)

;; Poll `ready?` until it holds or the deadline passes. Returns its last value.
(define (wait-until ready?)
  (define end (+ (current-inexact-milliseconds) (* 1000 deadline-seconds)))
  (let loop ()
    (cond
      [(ready?) #t]
      [(> (current-inexact-milliseconds) end) #f]
      [else (sleep 0.005) (loop)])))

;; Wait for the thread a signaling procedure stored in `th` to finish.
(define (wait-dead th)
  (and (wait-until (lambda () (unbox th)))
       (sync/timeout deadline-seconds (thread-dead-evt (unbox th)))
       #t))

;; A list that threads add to, read through `items` in arrival order.
(define (make-log)
  (define lock (make-semaphore 1))
  (define entries '())
  (values (lambda (entry)
            (call-with-semaphore lock (lambda () (set! entries (cons entry entries)))))
          (lambda () (call-with-semaphore lock (lambda () (reverse entries))))))

;; A refusal as the netlayer raises it for a code.
(define (refusal code) (raise-glowcap 'fake code "refused"))

;; Build callbacks over fake verbs. Verb behavior is `answer-fails?`,
;; `candidate-fails?`, and `fail-code`, the code the fail verb refuses with, if
;; any. `open?` is the netlayer's liveness. Returns the callbacks, the verb log,
;; and the error log.
(define (fixture sig #:answer-fails? [answer-fails? #f] #:candidate-fails? [candidate-fails? #f]
                 #:fail-code [fail-code #f] #:open? [open? #t])
  (define-values (log-verb verbs-seen) (make-log))
  (define-values (log-error errors-seen) (make-log))
  (define verbs
    (exchange-verbs
     (lambda (nl designator sdp)
       (log-verb (list 'offer nl designator sdp))
       77)
     (lambda (nl id text)
       (log-verb (list 'answer nl id text))
       (when answer-fails? (error 'answer "refused")))
     (lambda (nl id text)
       (log-verb (list 'candidate nl id text))
       (when candidate-fails? (error 'candidate "refused")))
     (lambda (nl id)
       (log-verb (list 'fail nl id))
       (when fail-code (refusal fail-code)))))
  (define callbacks (make-exchange-callbacks sig log-error verbs (lambda () open?)))
  ((exchange-callbacks-set-netlayer! callbacks) 'nl)
  (values callbacks verbs-seen errors-seen))

(define (count-of kind items) (length (filter (lambda (e) (eq? (car e) kind)) items)))

(define (offer! cb id [introducer #f])
  ((exchange-callbacks-send-offer cb) id (webrtc-target "peer" introducer) "offer-sdp"))
(define (answer! cb id [designator "offerer"])
  ((exchange-callbacks-send-answer cb) id (webrtc-target designator #f) "answer-sdp"))
(define (candidate! cb id) ((exchange-callbacks-send-candidate cb) id "ice"))
(define (done! cb id) ((exchange-callbacks-done cb) id))

(define (quiet-signaling #:offer [offer (lambda (x d s) "answer-sdp")]
                         #:answer [answer void]
                         #:candidate [candidate void]
                         #:on-candidate [on-candidate (lambda (x d sink) void)])
  (signaling offer answer candidate on-candidate))

(test-case "send-offer returns 0 and the answer reaches provide-answer!"
  (define-values (cb verbs errors) (fixture (quiet-signaling)))
  (check-equal? (offer! cb 1) OK)
  (check-true (wait-until (lambda () (= 1 (count-of 'answer (verbs))))))
  (check-equal? (verbs) '((answer nl 1 "answer-sdp")))
  (check-equal? (errors) '()))

(test-case "a reused id is refused and the first exchange still works"
  (define gate (make-channel))
  (define-values (cb verbs errors)
    (fixture (quiet-signaling #:offer (lambda (x d s) (sync/timeout deadline-seconds gate) "first"))))
  (check-equal? (offer! cb 7) OK)
  (check-equal? (offer! cb 7) ERR-IO)
  (check-true (and (sync/timeout deadline-seconds (channel-put-evt gate 'go)) #t))
  (check-true (wait-until (lambda () (= 1 (count-of 'answer (verbs))))))
  (check-equal? (verbs) '((answer nl 7 "first")))
  (check-equal? (errors) '()))

(test-case "done disposes once and late arrivals reach no verb"
  (define gate (make-channel))
  (define th (box #f))
  (define sink-box (box #f))
  (define disposed (box 0))
  (define-values (cb verbs errors)
    (fixture (quiet-signaling
              ;; The offer runs after the dispose thunk is stored, so `done`
              ;; below takes the stored thunk.
              #:offer (lambda (x d s)
                        (set-box! th (current-thread))
                        (sync/timeout deadline-seconds gate)
                        "late")
              #:on-candidate (lambda (x d sink)
                               (set-box! sink-box sink)
                               (lambda () (set-box! disposed (add1 (unbox disposed))))))))
  (check-equal? (offer! cb 3) OK)
  (check-true (wait-until (lambda () (unbox th))))
  (check-equal? (done! cb 3) (void))
  (check-true (wait-until (lambda () (= 1 (unbox disposed)))))
  ((unbox sink-box) "late-ice")
  (check-true (and (sync/timeout deadline-seconds (channel-put-evt gate 'go)) #t))
  (check-true (wait-dead th))
  (check-equal? (unbox disposed) 1)
  (check-equal? (verbs) '())
  (check-equal? (errors) '()))

(test-case "a dial that ends before its offer runs sends no offer"
  (define gate (make-channel))
  (define offers (box 0))
  (define disposed (box 0))
  (define-values (cb verbs errors)
    (fixture (quiet-signaling
              #:offer (lambda (x d s) (set-box! offers (add1 (unbox offers))) "answer")
              #:on-candidate (lambda (x d sink)
                               (sync/timeout deadline-seconds gate)
                               (lambda () (set-box! disposed (add1 (unbox disposed))))))))
  (check-equal? (offer! cb 2) OK)
  (check-equal? (done! cb 2) (void))
  (check-true (and (sync/timeout deadline-seconds (channel-put-evt gate 'go)) #t))
  (check-true (wait-until (lambda () (= 1 (unbox disposed)))))
  (check-equal? (unbox offers) 0)
  (check-equal? (verbs) '())
  (check-equal? (errors) '()))

(test-case "an offer that raises records once and fails the exchange once"
  (define th (box #f))
  (define-values (cb verbs errors)
    (fixture (quiet-signaling #:offer (lambda (x d s)
                                       (set-box! th (current-thread))
                                       (error 'offer "boom")))))
  (check-equal? (offer! cb 4) OK)
  (check-true (wait-dead th))
  (check-equal? (length (errors)) 1)
  (check-equal? (verbs) '((fail nl 4))))

(test-case "a candidate procedure that raises records once and fails the exchange once"
  (define gate (make-channel))
  (define th (box #f))
  (define-values (cb verbs errors)
    (fixture (quiet-signaling
              #:offer (lambda (x d s) (sync/timeout deadline-seconds gate) "a")
              #:candidate (lambda (x text)
                            (set-box! th (current-thread))
                            (error 'candidate "boom")))))
  (check-equal? (offer! cb 5) OK)
  (check-equal? (candidate! cb 5) OK)
  (check-true (wait-dead th))
  (check-equal? (length (errors)) 1)
  (check-equal? (verbs) '((fail nl 5)))
  (check-equal? (candidate! cb 99) ERR-IO)
  (sync/timeout deadline-seconds (channel-put-evt gate 'go)))

(test-case "a provide-answer! verb that raises records once and fails the exchange once"
  (define th (box #f))
  (define-values (cb verbs errors)
    (fixture (quiet-signaling #:offer (lambda (x d s) (set-box! th (current-thread)) "answer-sdp"))
             #:answer-fails? #t))
  (check-equal? (offer! cb 6) OK)
  (check-true (wait-dead th))
  (check-equal? (length (errors)) 1)
  (check-equal? (verbs) '((answer nl 6 "answer-sdp") (fail nl 6))))

(test-case "a provide-candidate! verb that raises records once and does not fail the exchange"
  (define gate (make-channel))
  (define sink-box (box #f))
  (define-values (cb verbs errors)
    (fixture (quiet-signaling
              #:offer (lambda (x d s) (sync/timeout deadline-seconds gate) "a")
              #:on-candidate (lambda (x d sink) (set-box! sink-box sink) void))
             #:candidate-fails? #t))
  (check-equal? (offer! cb 8) OK)
  (check-true (wait-until (lambda () (unbox sink-box))))
  ((unbox sink-box) "ice")
  (check-equal? (length (errors)) 1)
  (check-equal? (verbs) '((candidate nl 8 "ice")))
  (sync/timeout deadline-seconds (channel-put-evt gate 'go)))

(test-case "an on-candidate that raises fails that dial and a later done is a no-op"
  (define th (box #f))
  (define-values (cb verbs errors)
    (fixture (quiet-signaling #:on-candidate (lambda (x d sink)
                                              (set-box! th (current-thread))
                                              (error 'on-candidate "boom")))))
  (check-equal? (offer! cb 9) OK)
  (check-true (wait-dead th))
  (check-equal? (length (errors)) 1)
  (check-equal? (verbs) '((fail nl 9)))
  (check-equal? (done! cb 9) (void))
  (check-equal? (length (errors)) 1)
  (check-equal? (verbs) '((fail nl 9))))

(test-case "a refused start leaves no live exchange"
  (define-values (cb verbs errors) (fixture (quiet-signaling)))
  (define dead (make-custodian))
  (custodian-shutdown-all dead)
  ;; Starting a thread under a shut-down custodian raises inside the start.
  (check-equal? (parameterize ([current-custodian dead]) (offer! cb 10)) ERR-IO)
  (check-equal? (length (errors)) 1)
  ;; The id is free again and no live entry remains.
  (check-equal? (offer! cb 10) OK)
  (check-true (wait-until (lambda () (= 1 (count-of 'answer (verbs)))))))

(test-case "done for an unknown id is a no-op"
  (define-values (cb verbs errors) (fixture (quiet-signaling)))
  (check-equal? (done! cb 404) (void))
  (check-equal? (verbs) '())
  (check-equal? (errors) '()))

(test-case "an offer sent with an introducer reaches the routing procedures with that target"
  (define seen (box '()))
  (define sink-box (box #f))
  (define-values (cb verbs errors)
    (fixture (quiet-signaling
              #:offer (lambda (x t s) (set-box! seen (cons (list 'offer t) (unbox seen))) "answer")
              #:candidate (lambda (x text) (set-box! seen (cons (list 'candidate x) (unbox seen))))
              #:on-candidate (lambda (x t sink)
                               (set-box! seen (cons (list 'on-candidate t) (unbox seen)))
                               (set-box! sink-box sink)
                               void))))
  (check-equal? (offer! cb 11 "intro") OK)
  (check-true (wait-until (lambda () (= 1 (count-of 'answer (verbs))))))
  (check-equal? (candidate! cb 11) OK)
  (check-true (wait-until (lambda () (= 3 (length (unbox seen))))))
  (define target (webrtc-target "peer" "intro"))
  (check-equal? (sort (map car (unbox seen)) symbol<?) '(candidate offer on-candidate))
  (check-true (andmap (lambda (entry) (equal? (cadr entry) target))
                      (filter (lambda (entry) (not (eq? (car entry) 'candidate))) (unbox seen))))
  (check-equal? (cadr (assq 'candidate (unbox seen))) 11)
  (check-equal? (errors) '()))

(test-case "a dial with no introducer gets a target whose introducer is #f"
  (define seen (box #f))
  (define-values (cb verbs errors)
    (fixture (quiet-signaling #:offer (lambda (x t s) (set-box! seen t) "answer"))))
  (check-equal? (offer! cb 12) OK)
  (check-true (wait-until (lambda () (unbox seen))))
  (check-equal? (unbox seen) (webrtc-target "peer" #f)))

(test-case "an accept registers, answers once, and subscribes to the offerer's candidates"
  (define answered (box '()))
  (define sink-box (box #f))
  (define-values (cb verbs errors)
    (fixture (quiet-signaling
              #:answer (lambda (x t sdp) (set-box! answered (cons (list t sdp) (unbox answered))))
              #:on-candidate (lambda (x t sink) (set-box! sink-box sink) void))))
  (check-equal? (answer! cb 20) OK)
  (check-equal? (unbox answered) (list (list (webrtc-target "offerer" #f) "answer-sdp")))
  (check-true (wait-until (lambda () (unbox sink-box))))
  ((unbox sink-box) "ice")
  (check-equal? (verbs) '((candidate nl 20 "ice")))
  (check-equal? (candidate! cb 20) OK)
  (check-equal? (errors) '()))

(test-case "an answer that raises refuses the accept and ends it once"
  (define disposed (box 0))
  (define-values (cb verbs errors)
    (fixture (quiet-signaling
              #:answer (lambda (x t sdp) (error 'answer "refused"))
              #:on-candidate (lambda (x t sink)
                               (lambda () (set-box! disposed (add1 (unbox disposed))))))))
  (check-equal? (answer! cb 21) ERR-IO)
  (check-equal? (length (errors)) 1)
  ;; The exchange is gone, so its id is free and no candidate reaches it.
  (check-equal? (candidate! cb 21) ERR-IO)
  (check-true (wait-until (lambda () (= 1 (unbox disposed)))))
  (check-equal? (verbs) '())
  (check-equal? (answer! cb 21) ERR-IO)
  (check-equal? (length (errors)) 2))

(test-case "done ends an accept the same way it ends a dial"
  (define disposed (box 0))
  (define-values (cb verbs errors)
    (fixture (quiet-signaling
              #:on-candidate (lambda (x t sink)
                               (lambda () (set-box! disposed (add1 (unbox disposed))))))))
  (check-equal? (answer! cb 22) OK)
  (done! cb 22)
  (check-true (wait-until (lambda () (= 1 (unbox disposed)))))
  (check-equal? (candidate! cb 22) ERR-IO)
  (check-equal? (errors) '()))

(test-case "provide-offer reaches the verb and returns its exchange id"
  (define-values (cb verbs errors) (fixture (quiet-signaling)))
  (check-equal? ((exchange-callbacks-provide-offer cb) "peer-a" "offer-sdp") 77)
  (check-equal? (verbs) '((offer nl "peer-a" "offer-sdp")))
  (check-equal? (errors) '()))

(test-case "fail-exchange raises the netlayer's refusal and changes nothing"
  (define-values (cb verbs errors)
    (fixture (quiet-signaling) #:fail-code ERR-INVALID-ARGUMENT))
  (check-equal? (answer! cb 25) OK)
  (define caught
    (with-handlers ([exn:fail:glowcap? values])
      ((exchange-callbacks-fail-exchange cb) 999)
      #f))
  (check-true (exn:fail:glowcap? caught))
  (check-equal? (exn:fail:glowcap-code caught) ERR-INVALID-ARGUMENT)
  (check-equal? (verbs) '((fail nl 999)))
  (check-equal? (errors) '())
  ;; The live accept is still there to take candidates.
  (check-equal? (candidate! cb 25) OK))

(test-case "the application's verbs refuse once the netlayer is closed, calling no verb"
  (define-values (cb verbs errors) (fixture (quiet-signaling) #:open? #f))
  (define (code-of thunk)
    (with-handlers ([exn:fail:glowcap? exn:fail:glowcap-code]) (thunk) #f))
  (check-equal? (code-of (lambda () ((exchange-callbacks-provide-offer cb) "peer" "offer"))) ERR-CLOSED)
  (check-equal? (code-of (lambda () ((exchange-callbacks-fail-exchange cb) 1))) ERR-CLOSED)
  (check-equal? (verbs) '()))

(test-case "giving a dial up tolerates only no such exchange"
  (define (give-up code)
    (define th (box #f))
    (define-values (cb verbs errors)
      (fixture (quiet-signaling #:offer (lambda (x d s) (set-box! th (current-thread)) (error 'offer "boom")))
               #:fail-code code))
    (check-equal? (offer! cb 26) OK)
    (check-true (wait-dead th))
    (check-true (wait-until (lambda () (= 1 (count-of 'fail (verbs))))))
    (length (errors)))
  ;; The offer's own error is recorded either way. A refused give-up adds one.
  (check-equal? (give-up ERR-INVALID-ARGUMENT) 1)
  (check-equal? (give-up ERR-IO) 2))

(test-case "two exchanges with one target get distinct ids passed through"
  (define offered (box '()))
  (define answered (box '()))
  (define subscribed (box '()))
  (define candidates (box '()))
  (define (push! b v) (set-box! b (cons v (unbox b))))
  (define-values (cb verbs errors)
    (fixture (quiet-signaling
              #:offer (lambda (x t s) (push! offered (list x t)) "answer-sdp")
              #:answer (lambda (x t s) (push! answered (list x t)))
              #:candidate (lambda (x text) (push! candidates x))
              #:on-candidate (lambda (x t sink) (push! subscribed (list x t)) void))))
  (check-equal? (offer! cb 30) OK)
  (check-equal? (answer! cb 31 "peer") OK)
  (check-true (wait-until (lambda () (= 2 (length (unbox subscribed))))))
  (check-true (wait-until (lambda () (= 1 (length (unbox offered))))))
  (check-equal? (candidate! cb 30) OK)
  (check-equal? (candidate! cb 31) OK)
  (check-true (wait-until (lambda () (= 2 (length (unbox candidates))))))
  (define target (webrtc-target "peer" #f))
  (check-equal? (unbox offered) (list (list 30 target)))
  (check-equal? (unbox answered) (list (list 31 target)))
  (check-equal? (sort (map car (unbox subscribed)) <) '(30 31))
  (check-true (andmap (lambda (e) (equal? (cadr e) target)) (unbox subscribed)))
  (check-equal? (sort (unbox candidates) <) '(30 31))
  (check-equal? (errors) '()))
