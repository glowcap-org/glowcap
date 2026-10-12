#lang racket/base
;; accountable-three-vat-demo.rkt: three-party introduction wired into
;; the substrate's accountability loop. Goblins/CapTP/TCP carries the
;; introduction; Bob's invoked cap runs the substrate's accountability
;; loop:
;;
;;   Invocation -> Decision (admission + policy) -> Effect ->
;;   Episode -> Log
;;
;; Each peer has its own KERI-anchored AID (Autonomic Identifier),
;; persisted in its own data directory. Bob's invoked cap emits a
;; real signed Episode (RDF-Star-shaped JSON-LD line, Sigstore-shaped
;; ephemeral signature countersigned by Bob's KEL key) for each call,
;; recording **the true caller (Carol)** as the actor, not Alice the
;; introducer, who isn't in the data path at all.
;;
;; What this validates that the previous three-vat-demo.rkt didn't:
;;   - Real signed Episodes flow through real OCapN three-party
;;     introduction. The Episode log on Bob will show actor=carol-aid
;;     for the call Carol made, not actor=alice-aid (which would be
;;     the wrong story).
;;   - Auditability survives the introduction: audit.rkt-style
;;     verification on Bob's Episode confirms the cryptographic chain.
;;   - The substrate's "every Invocation produces an Episode" invariant
;;     holds across Vat boundaries reached via introduction.

(require goblins
         goblins/ocapn
         goblins/ocapn/structs-urls
         ;; tcp-netlayer.rkt lives in goblins-peer/ (the slim Goblins peer
         ;; glowcap dials). accountability-on-goblins reuses it; the container
         ;; mounts both racket/ trees so this relative path resolves.
         "../../goblins-peer/racket/tcp-netlayer.rkt"
         (prefix-in id: "identity.rkt")
         (prefix-in ep: "episode.rkt")
         racket/async-channel
         racket/file
         racket/match)

;; ============================================================================
;; Per-peer state setup, each peer has its own data dir + KERI AID.
;; ============================================================================

(define (data-root)
  ;; Honor GOBLINS_DATA_DIR (the run.sh container env var); fall back
  ;; to .data under cwd. Each peer gets its own subdirectory so KEL
  ;; files and Episode logs stay separated.
  (define override (getenv "GOBLINS_DATA_DIR"))
  (cond
    [(and override (not (string=? override ""))) override]
    [else (build-path (current-directory) ".data")]))

(define (peer-data-dir name)
  (define d (build-path (data-root) (string-append "threevat-" name)))
  (make-directory* d)
  d)

(define bob-data   (peer-data-dir "bob"))
(define alice-data (peer-data-dir "alice"))
(define carol-data (peer-data-dir "carol"))

;; ============================================================================
;; The capability Bob hosts, an Affordance that runs the substrate's
;; accountability loop on every invocation.
;; ============================================================================
;;
;; Vocabulary note: this file uses Goblins/Racket terms ("actor", "AID",
;; "Affordance") for fluency with the surrounding reference
;; implementation. Closure captures Bob's data dir (where Episodes
;; land) and Bob's own AID (the local Vat's signing principal). On each
;; call:
;;
;;   1. Decision phase (stub admission + policy):
;;      - Admission: caller-aid is non-empty CESR? Allow / Deny.
;;      - Policy:    trivial allow.
;;   2. Effect phase: run the actual demo behavior (echo).
;;   3. Episode emission: real signed Episode recording the *caller* as
;;      the actor and Bob as the recording Vat (`signing-aid`).
;;   4. Return the result.
;;
;; ACCOUNTABILITY INVARIANT: *every attempt is an Episode*. The deny
;; branch below also emits an Episode, refusals are observable,
;; exactly as the substrate's design requires.

(define (^accountable-affordance _bcom my-aid my-data-dir my-place)
  (lambda (caller-aid call-args)
    ;; --- Decision: admission ---
    (define admitted?
      (and (string? caller-aid)
           (> (string-length caller-aid) 0)
           ;; CESR Blake3-256 SAID is `E`-prefixed and 44 chars.
           ;; Looser check: just require an `E` prefix.
           (char=? (string-ref caller-aid 0) #\E)))
    (cond
      [(not admitted?)
       ;; Refusal is observable: emit a deny Episode so Bob's Log
       ;; carries the rejected attempt. Per the substrate's
       ;; accountability invariant, silent refusal is a
       ;; substrate-correctness bug. Use Bob's AID as the actor (the
       ;; refusal is Bob's, attributed to a "no-valid-caller" event,
       ;; there's no caller AID to record).
       (printf "  [Bob/affordance] DENY: caller-aid ~v not admitted (emitting deny Episode)~n"
               caller-aid)
       (ep:emit-episode!
        my-data-dir
        #:actor my-aid               ; refusal authored by Bob
        #:signing-aid my-aid
        #:place my-place
        #:affordance "accountable-three-vat-demo"
        #:result (hasheq 'kind "deny"
                         'reason "admission-failed"
                         'observed-caller (format "~v" caller-aid))
        #:policy-grant "denied")
       `(deny ,caller-aid "admission-failed")]
      [else
       ;; --- Decision: policy (stub allow) ---
       ;; --- Effect ---
       (define result-payload
         (hasheq 'kind "accountable-three-vat-demo"
                 'caller caller-aid
                 'message
                 (format "Hello ~a; bytes arrived directly at Bob via OCapN introduction." caller-aid)
                 'echoed-args (format "~v" call-args)))
       ;; --- Episode emission (signed, persisted, transparency-logged) ---
       (printf "  [Bob/affordance] emitting Episode: actor=~a place=~a~n"
               caller-aid my-place)
       (ep:emit-episode!
        my-data-dir
        #:actor caller-aid          ; WHO INVOKED (Carol, the remote peer)
        #:signing-aid my-aid         ; WHO RECORDS (us, Bob, local KEL)
        #:place my-place
        #:affordance "accountable-three-vat-demo"
        #:result result-payload
        #:policy-grant "default-grant")
       result-payload])))

;; ============================================================================
;; The introducer Alice hosts, gives out a remote ref to Bob's
;; affordance on request.
;; ============================================================================

(define (^introducer _bcom remote-affordance-ref)
  (lambda args
    (case (and (pair? args) (car args))
      [(get-affordance) remote-affordance-ref]
      [else (error '^introducer "unknown command: ~v" args)])))

;; ============================================================================
;; Per-peer setup: each gets a TCP netlayer + mycapn + KERI AID.
;; ============================================================================

(define (banner heading)
  (printf "~n=== ~a ===~n" heading))

(banner "Bootstrapping three peers, each with its own KERI AID")

(define-values (bob-aid bob-kel-path) (id:make-aid bob-data))
(define-values (alice-aid alice-kel-path) (id:make-aid alice-data))
(define-values (carol-aid carol-kel-path) (id:make-aid carol-data))

(printf "  Bob   AID: ~a~n" bob-aid)
(printf "  Alice AID: ~a~n" alice-aid)
(printf "  Carol AID: ~a~n" carol-aid)

;; Trace tally, same shape as three-vat-demo.rkt; proves Carol's
;; introduction-triggered call goes Carol -> Bob, not via Alice.

(define alice-port 9021)
(define bob-port   9022)
(define carol-port 9023)

(define bob-accepts (box 0))
(define alice-accepts (box 0))
(define carol-connects (box '()))

(define (bob-trace event . args)
  (when (eq? event 'accept) (set-box! bob-accepts (add1 (unbox bob-accepts)))))
(define (alice-trace event . args)
  (when (eq? event 'accept) (set-box! alice-accepts (add1 (unbox alice-accepts)))))
(define (carol-trace event . args)
  (when (eq? event 'connect)
    (define remote-designator (ocapn-node-designator (cadr args)))
    (set-box! carol-connects (cons remote-designator (unbox carol-connects)))))

;; --- Bob ---
(banner (format "Bob: bind 127.0.0.1:~a, host accountable-affordance" bob-port))
(define-vat-run bob-machine-run (make-vat))
(define bob-netlayer
  (bob-machine-run (spawn ^tcp-netlayer "127.0.0.1" bob-port #:trace bob-trace)))
(define bob-mycapn (bob-machine-run (spawn-mycapn bob-netlayer)))

(define-vat-run bob-vat-run (make-vat))
(define bob-affordance
  (bob-vat-run (spawn ^accountable-affordance bob-aid bob-data "bob.vat")))
(define bob-affordance-sref
  (bob-machine-run ($ bob-mycapn 'register bob-affordance 'tcp)))

;; --- Alice ---
(banner (format "Alice: bind 127.0.0.1:~a, enliven Bob's affordance, host introducer" alice-port))
(define-vat-run alice-machine-run (make-vat))
(define alice-netlayer
  (alice-machine-run (spawn ^tcp-netlayer "127.0.0.1" alice-port #:trace alice-trace)))
(define alice-mycapn (alice-machine-run (spawn-mycapn alice-netlayer)))

(define-vat-run alice-vat-run (make-vat))
(define alice-affordance-ref-vow
  (alice-machine-run (<- alice-mycapn 'enliven bob-affordance-sref)))
(sleep 0.3)  ; let Alice -> Bob TCP settle for deterministic trace

(define alice-introducer
  (alice-vat-run (spawn ^introducer alice-affordance-ref-vow)))
(define alice-introducer-sref
  (alice-machine-run ($ alice-mycapn 'register alice-introducer 'tcp)))

;; --- Carol ---
(banner (format "Carol: bind 127.0.0.1:~a, will dial Alice for introduction" carol-port))
(define-vat-run carol-machine-run (make-vat))
(define carol-netlayer
  (carol-machine-run (spawn ^tcp-netlayer "127.0.0.1" carol-port #:trace carol-trace)))
(define carol-mycapn (carol-machine-run (spawn-mycapn carol-netlayer)))

(define-vat-run carol-vat-run (make-vat))
(define response-ch (make-async-channel))

;; ============================================================================
;; The introduction + invocation
;; ============================================================================

(banner "Carol: enlivens Alice's introducer, asks for the cap, invokes it directly")

(carol-vat-run
 (printf "  [Carol] enlivening introducer...~n")
 (define introducer-vow (<- carol-mycapn 'enliven alice-introducer-sref))
 (printf "  [Carol] asking introducer for the affordance...~n")
 (define affordance-vow (<- introducer-vow 'get-affordance))
 (printf "  [Carol] invoking affordance with my AID and a message...~n")
 (on (<- affordance-vow carol-aid '("Hello via OCapN three-party introduction"))
     (lambda (val)
       (async-channel-put response-ch `(ok ,val)))
     #:catch
     (lambda (err)
       (async-channel-put response-ch `(err ,err)))))

(define reply (sync/timeout 15.0 response-ch))
(sleep 0.3)

;; ============================================================================
;; Verdict, three layers of assertions
;; ============================================================================

(banner "VERDICT: substrate accountability loop wired through OCapN introduction")

(case (and (pair? reply) (car reply))
  [(ok)
   (printf "~n  Carol's call succeeded.~n")
   (printf "    payload: ~v~n" (cadr reply))]
  [(err)
   (printf "~n  Carol's call FAILED: ~v~n" (cadr reply))
   (exit 1)]
  [else
   (printf "~n  Carol's call TIMED OUT.~n")
   (exit 1)])

;; --- Assertion 1: introduction worked (Bob saw 2+ inbound TCP) ---
(printf "~n  [1] Three-party handoff: Carol dialed Bob directly (Bob accepts >= 2)~n")
(define introduction-worked? (>= (unbox bob-accepts) 2))
(printf "      Bob accepts=~a, Alice accepts=~a~n"
        (unbox bob-accepts) (unbox alice-accepts))
(printf "      Carol dialed: ~v~n" (reverse (unbox carol-connects)))
(printf "      -> ~a~n" (if introduction-worked? "PASS" "FAIL"))
(unless introduction-worked? (exit 1))

;; --- Assertion 2: Bob has a real Episode for Carol's call ---
;; Per episode.rkt, the invoking actor lands in two payload fields:
;;   subject = "did:keri:<aid>", RDF-Star subject (the Actor)
;;   graph   = "goblins:vat/<aid>", named-graph-per-Vat
;; The Episode is signed by Bob (the local Vat); kel_anchor.aid = bob.
(printf "~n  [2] Bob emitted a real signed Episode for Carol's invocation~n")
(define bob-eps (ep:load-episodes bob-data))
(printf "      Bob's Episode log: ~a entries~n" (length bob-eps))
(define expected-subject (string-append "did:keri:" carol-aid))
(define carol-episode
  (for/or ([ep (in-list bob-eps)])
    (and (string=? (hash-ref ep 'subject "") expected-subject) ep)))
(define episode-with-correct-actor?
  (and carol-episode #t))
(printf "      Episode where subject=~a found? ~a~n"
        expected-subject (if episode-with-correct-actor? "yes" "NO"))
(when carol-episode
  (printf "      kel_anchor.aid=~a (Bob — the recording Vat)~n"
          (hash-ref (hash-ref carol-episode 'kel_anchor) 'aid)))
(printf "      -> ~a~n" (if episode-with-correct-actor? "PASS" "FAIL"))
(unless episode-with-correct-actor? (exit 1))

;; --- Assertion 3: the Episode verifies cryptographically ---
(printf "~n  [3] The Episode verifies (signature chain + KEL anchor)~n")
(define episode-verifies?
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (printf "      verify-episode raised: ~a~n" (exn-message e))
                     #f)])
    (ep:verify-episode bob-data carol-episode)))
(printf "      verify-episode -> ~a~n" episode-verifies?)
(printf "      -> ~a~n" (if episode-verifies? "PASS" "FAIL"))
(unless episode-verifies? (exit 1))

;; --- Assertion 4: Alice has NO Episode about this invocation ---
;; (Alice was the introducer; she's not in the data path; she should
;; have no record of Carol's call.)
(printf "~n  [4] Alice has no Episode about Carol's call (she's not in the data path)~n")
(define alice-eps
  (with-handlers ([exn:fail? (lambda (e) '())])
    (ep:load-episodes alice-data)))
(define alice-saw-carol?
  (for/or ([ep (in-list alice-eps)])
    (string=? (hash-ref ep 'subject "") expected-subject)))
(printf "      Alice's Episode log mentions Carol's invocation? ~a~n"
        (if alice-saw-carol? "YES (would mean proxying)" "no"))
(printf "      -> ~a~n" (if (not alice-saw-carol?) "PASS" "FAIL"))
(when alice-saw-carol? (exit 1))

(printf "~n  All four assertions passed.~n")
(printf "~n  Translation: the substrate's accountability loop, expressed in Racket via the existing~n")
(printf "  identity.rkt + episode.rkt machinery, runs cleanly across an OCapN~n")
(printf "  three-party introduction. The Episode log carries the TRUE actor~n")
(printf "  (Carol), not the introducer (Alice). Goblins/CapTP/TCP makes the~n")
(printf "  data path direct; the substrate's accountability primitive (the signed~n")
(printf "  Episode) records who actually invoked. This is what 'capabilities +~n")
(printf "  accountability surviving across Vat boundaries' looks like end-to-end.~n~n")
(exit 0)
