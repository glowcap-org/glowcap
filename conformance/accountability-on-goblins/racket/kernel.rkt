#lang racket/base
;; kernel.rkt — the substrate's accountability loop.
;;
;; Runs the smallest demonstrable Invocation → Decision → Effect → Episode
;; trace through one Goblins Vat:
;;   1. A Goblins Vat hosts one Actor.
;;   2. The Actor has a KERI-anchored DID (inception event).
;;   3. The Actor holds an OCapN-shaped capability reference (Goblins near-ref)
;;      to a built-in Affordance method.
;;   4. The Actor invokes the capability.
;;   5. The invocation produces an Episode (RDF-Star JSON-LD with bitemporal
;;      columns, named-graph-per-Vat).
;;   6. The Episode is signed by a per-Episode ephemeral key, countersigned
;;      by the AID's CURRENT rotation key (rotated once for kernel demo).
;;   7. The Episode is persisted (JSON-LD line + transparency-log Merkle leaf).
;;   8. The Episode is auditable (audit.rkt, run separately).
;;
;; Policy is a literal Racket data structure declared inline (the smallest
;; workable form; rich Policy authoring would land with a more developed
;; authority surface). No multi-Actor, no second capability, no Iroh, no
;; cross-Vat — single-Vat single-Actor scope throughout.

(require racket/match
         goblins
         (prefix-in id: "identity.rkt")
         (prefix-in ep: "episode.rkt"))

;; ============================================================================
;; Policy — minimal literal form
;; ============================================================================
;; Real Policies are governed artifacts; the kernel's Policy is a single
;; default-grant clause: any Actor in this Vat may invoke the demo Affordance
;; with `access` rights. A more developed authority surface would add
;; Policy authoring scaffolding.

(define KERNEL-POLICY
  '((default-grant
      (actor any)
      (right access)
      (affordance demo))))

;; Resolver: does the Policy authorize (actor, right, affordance)?
;; Returns the matching grant clause (truthy) or #f. Two clause forms:
;;   `(default-grant ...)` — applies to any actor; matches on right + affordance.
;;   `(actor-grant   ...)` — applies to a specific actor; matches on all three.
;; Per-actor scoping, role-based clauses, and Datalog-resolver shape land at
;; later (post-kernel).
(define (policy-authorizes? policy actor right affordance)
  (define (has? sym val spec)
    (member `(,sym ,val) spec))
  (for/or ([clause (in-list policy)])
    (case (car clause)
      [(default-grant)
       (and (has? 'right right (cdr clause))
            (has? 'affordance affordance (cdr clause))
            clause)]
      [(actor-grant)
       (and (has? 'actor actor (cdr clause))
            (has? 'right right (cdr clause))
            (has? 'affordance affordance (cdr clause))
            clause)]
      [else #f])))

;; ============================================================================
;; Affordance — built-in Goblins actor method
;; ============================================================================
;; For the kernel, the capability invokes a built-in Goblins actor method
;; directly. A WASM-Component-hosted Affordance with WIT-OCapN bindings is
;; the obvious post-kernel extension; not in scope here.

(define (^demo-affordance _bcom)
  ;; A trivial Affordance: invoking it returns a small structured result.
  ;; Real Affordances are WASM Components bound to OCapN refs at instantiation.
  (lambda args
    (case (length args)
      [(0) (hasheq 'kind "demo" 'message "kernel-loop-invoked" 'args '())]
      [else (hasheq 'kind "demo" 'message "kernel-loop-invoked" 'args args)])))

;; ============================================================================
;; Driver — runs the eight steps
;; ============================================================================

(define (data-dir)
  ;; Default: a sibling .data/ under the current directory. GOBLINS_DATA_DIR pins
  ;; the resolution when the entrypoint cds to a read-only path (e.g. raco
  ;; test cds into tests/, which lives under the :ro source mount); both
  ;; kernel.rkt and tests/kernel-test.rkt honor the same env var so they
  ;; agree on where the writable .data/ lives.
  (define override (getenv "GOBLINS_DATA_DIR"))
  (cond
    [(and override (not (string=? override ""))) override]
    [else (build-path (current-directory) ".data")]))

(define (banner step msg)
  (printf "[~a/8] ~a~n" step msg))

(define (run-kernel)
  (define D (data-dir))

  (banner 1 "Vat hosts one Actor")
  ;; Spawn a Vat. Goblins's vat is a dispatcher procedure; ('spawn ^actor)
  ;; spawns a new actor inside the vat's event loop and returns a near-ref.
  (define a-vat (make-vat))
  (define actor-ref (a-vat 'spawn ^demo-affordance))
  (printf "      vat instantiated; actor spawned.~n")

  (banner 2 "Actor has KERI-anchored DID (inception event)")
  (define-values (aid kel-path) (id:make-aid D))
  (printf "      AID: ~a~n" aid)
  (printf "      KEL: ~a~n" kel-path)

  (banner 3 "Actor holds OCapN-shaped capability ref to Affordance")
  ;; In Goblins, `actor-ref` IS the capability — possession of the reference
  ;; IS authorization. Capability discipline is enforced at the language level:
  ;; the only way to invoke the Affordance is through this reference.
  (printf "      capability: <Goblins near-ref to demo-affordance>~n")
  (printf "      policy: ~v~n" KERNEL-POLICY)

  (banner 4 "Actor invokes capability (eventual send)")
  ;; Policy gate: consult the Policy before invoking. A real substrate has
  ;; a Datalog Resolver doing this; the kernel uses a simple sexp matcher.
  (define grant (policy-authorizes? KERNEL-POLICY aid 'access 'demo))
  (unless grant
    (error 'run-kernel "Policy denied: actor=~a right=access affordance=demo" aid))
  (printf "      policy authorized: ~v~n" (car grant))
  ;; Invoke via the vat's synchronous-call interface.
  (define result (a-vat 'call actor-ref))
  (printf "      result: ~v~n" result)

  (banner 5 "Invocation produces Episode (JSON-LD quad; RDF-Star reification deferred)")
  ;; Before emitting, rotate the AID so step 6 demonstrates rotation working.
  (banner 6 "Episode signed by ephemeral key (countersigned by KERI rotation)")
  (define rot-said (id:rotate-aid D aid))
  (printf "      AID rotated; new event SAID: ~a~n" rot-said)

  ;; Now emit the Episode: ephemeral keypair, sign payload, countersign
  ;; ephemeral pubkey with AID's CURRENT (post-rotation) verkey, persist,
  ;; transparency-log.
  (define ep
    (ep:emit-episode!
     D
     #:actor aid
     #:place "kernel.local"
     #:affordance "demo"
     #:result result
     #:policy-grant "default-grant"))

  (banner 7 "Episode persisted")
  (printf "      episodes.jsonld: 1 line appended~n")
  (printf "      transparency.log: 1 leaf added~n")

  (banner 8 "Episode auditable")
  ;; Verify the loop closes: re-read and re-verify the freshly-emitted Episode.
  (define ok? (ep:verify-episode D ep))
  (printf "      verification: ~a~n" (if ok? "OK" "FAILED"))
  (unless ok?
    (error 'run-kernel "self-verification of emitted Episode failed"))

  (printf "~nKernel loop closed. Run audit.rkt to print the full trace.~n")
  (void))

(run-kernel)
