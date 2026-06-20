#lang racket/base
;; episode.rkt, Episode emission.
;;
;; An Episode is a signed bitemporal RDF-Star quad recording a capability
;; invocation. Per substrate commitment, every Episode:
;;   - is built from invocation context (subject, predicate, object, place)
;;   - carries bitemporal columns (valid_time + transaction_time)
;;   - is signed by a per-Episode ephemeral keypair
;;   - has the ephemeral pubkey countersigned by the Actor's KERI rotation key
;;     (Sigstore-style ephemeral signing anchored in the AID's KEL)
;;   - is written as one JSON-LD line to .data/episodes.jsonld
;;     (TerminusDB-portable shape: RDF-Star quad, named graph per Vat,
;;      bitemporal columns, embedded provenance)
;;   - has its serialized bytes Blake3-hashed and registered in the local
;;     Sigstore-shaped transparency log

(require racket/contract
         racket/file
         racket/format
         racket/date
         racket/match
         json
         (prefix-in id: "identity.rkt")
         (prefix-in tlog: "log.rkt"))

(provide
 (contract-out
  ;; Build, sign, persist, and log an Episode. Returns the Episode hash table.
  ;;
  ;; The optional `#:signing-aid` lets a Vat sign an Episode about an
  ;; invocation whose actor is a different AID, e.g. a Vat that
  ;; observes a remote peer (via OCapN three-party introduction)
  ;; invoking one of its capabilities. The Episode's `actor` field
  ;; records WHO INVOKED; `signing-aid` is who attests they observed
  ;; it (defaults to actor for the single-Vat kernel case where they
  ;; are the same).
  [emit-episode! (->* (path-string?
                       #:actor string?
                       #:place string?
                       #:affordance string?
                       #:result jsexpr?
                       #:policy-grant string?)
                      (#:signing-aid string?)
                      hash?)]
  ;; Verify an Episode's signature chain against an AID's KEL.
  [verify-episode (-> path-string? hash? boolean?)]
  ;; Read all Episodes from the persisted JSON-LD file.
  [load-episodes (-> path-string? (listof hash?))]))

(define (episodes-file data-dir)
  (build-path data-dir "episodes.jsonld"))

(define (now-iso8601)
  (define now (current-seconds))
  (define gmt (seconds->date now #f))
  (format "~a-~a-~aT~a:~a:~aZ"
          (~r (date-year gmt) #:min-width 4 #:pad-string "0")
          (~r (date-month gmt) #:min-width 2 #:pad-string "0")
          (~r (date-day gmt) #:min-width 2 #:pad-string "0")
          (~r (date-hour gmt) #:min-width 2 #:pad-string "0")
          (~r (date-minute gmt) #:min-width 2 #:pad-string "0")
          (~r (date-second gmt) #:min-width 2 #:pad-string "0")))

(define (canonical-bytes-for-signing episode-without-signatures)
  ;; Sign the JSON-LD canonicalization of the Episode minus the signature
  ;; fields (sig, ephemeral_pubkey_sig). Same shape both sides hash → bytes.
  (string->bytes/utf-8 (jsexpr->string episode-without-signatures)))

;; Crypto suite identifier, names the primitive set the kernel signs Episodes
;; with. Carried in every Episode (substrate commitment #7, crypto-agility):
;; the verifier can refuse unknown suites. Changing primitive families bumps
;; the suite string; the actual versioning protocol (semver, namespacing,
;; suite-add procedure) is application-layer scaffold design, outside
;; pancake's ADR scope.
(define EPISODE-CRYPTO-SUITE "ed25519-blake3-cesr-v1")

(define (build-episode-payload #:actor actor
                               #:place place
                               #:affordance affordance
                               #:result result
                               #:policy-grant policy-grant
                               #:ephemeral-pk-cesr eph-pk-cesr)
  ;; JSON-LD quad shape (RDF-Star-oriented; full reification deferred to
  ;; TerminusDB integration at later (post-kernel)). Subject is the Actor's
  ;; KERI-anchored DID (`did:keri:<AID>` — KERI WebOfTrust convention,
  ;; forward-compatible with W3C DID landscape). The named graph stays in
  ;; the `goblins:vat/` namespace because the Vat is a substrate-internal
  ;; coordination-boundary identifier, not a federated DID. Predicate is
  ;; `goblins:invoked`. Object is the Affordance result. Bitemporal columns
  ;; are valid_time (when it happened) and transaction_time (when recorded);
  ;; kernel sets both to now. `crypto_suite` carries the primitive-family
  ;; version per substrate commitment #7.
  (define ts (now-iso8601))
  (hasheq
   '@context "https://goblins.org/contexts/episode-v1.jsonld"
   '@type "goblins:Episode"
   'crypto_suite EPISODE-CRYPTO-SUITE
   'subject (string-append "did:keri:" actor)
   'predicate "goblins:invoked"
   'object (hasheq 'affordance (string-append "goblins:affordance/" affordance)
                   'result result)
   'graph (string-append "goblins:vat/" actor)
   'place (string-append "goblins:place/" place)
   'valid_time_start ts
   'valid_time_end 'null
   'tx_time_start ts
   'tx_time_end 'null
   'policy_grant policy-grant
   'ephemeral_pubkey eph-pk-cesr))

(define (emit-episode! data-dir
                       #:actor actor
                       #:place place
                       #:affordance affordance
                       #:result result
                       #:policy-grant policy-grant
                       #:signing-aid [signing-aid actor])
  ;; The Vat that *records* the Episode is identified by `signing-aid`
  ;; (whose KEL must live in `data-dir`). The Vat that *invoked* the
  ;; capability is `actor`. In single-Vat scenarios these are the same;
  ;; in three-Vat-via-introduction scenarios, `actor` is a remote AID
  ;; and `signing-aid` is the local Vat's AID.

  ;; 1. Generate per-Episode ephemeral keypair, derived from the rotation chain
  ;;    in the sense that the AID's CURRENT key countersigns the ephemeral pk
  ;;    (Sigstore-style). The ephemeral private key is destroyed at function
  ;;    exit, only the public key + signature persist.
  (define-values (eph-pk eph-sk eph-pk-cesr)
    (id:aid-ephemeral-keypair data-dir signing-aid))

  ;; 2. Local AID rotation-key countersigns the ephemeral pubkey bytes.
  (define eph-pk-cesr-bytes (string->bytes/utf-8 eph-pk-cesr))
  (define eph-pk-sig-bytes (id:aid-sign data-dir signing-aid eph-pk-cesr-bytes))
  (define eph-pk-sig-cesr (id:cesr-encode-64 "0B" eph-pk-sig-bytes))

  ;; 3. Build Episode payload (without signatures).
  (define payload
    (build-episode-payload
     #:actor actor
     #:place place
     #:affordance affordance
     #:result result
     #:policy-grant policy-grant
     #:ephemeral-pk-cesr eph-pk-cesr))

  ;; 4. Sign Episode payload with ephemeral signing key, then zero it. The
  ;;    private key has no use after this point; explicit zero-fill is more
  ;;    honest than relying on GC. (Memory still lives until reclaimed; we
  ;;    don't claim immunity from process-memory inspection, see STATUS.md.)
  (define payload-bytes (canonical-bytes-for-signing payload))
  (define episode-sig-bytes (id:ephemeral-sign eph-sk payload-bytes))
  (bytes-fill! eph-sk 0)
  (define episode-sig-cesr (id:cesr-encode-64 "0B" episode-sig-bytes))

  ;; 5. Get the SIGNING AID's current event sequence (for KEL anchoring),
  ;;    needed by the audit verifier to find the right verkey to verify
  ;;    the ephemeral-pubkey countersignature.
  (define kel (id:load-kel data-dir signing-aid))
  (define current-seq
    (hash-ref (hash-ref (last-rec kel) 'event) 's))

  ;; 6. Assemble final Episode record. `kel_anchor` names the local
  ;;    signing AID; `actor` (in the payload) names the invoker.
  (define episode
    (hash-set*
     payload
     'sig episode-sig-cesr
     'ephemeral_pubkey_sig eph-pk-sig-cesr
     'kel_anchor (hasheq 'aid signing-aid 'seq current-seq)))

  ;; 7. Append JSON-LD line to .data/episodes.jsonld.
  (define ep-file (episodes-file data-dir))
  (call-with-output-file ep-file
    #:exists 'append
    (lambda (out)
      (write-string (jsexpr->string episode) out)
      (newline out)))

  ;; 8. Register the signed Episode bytes in the local transparency log.
  (define final-bytes (string->bytes/utf-8 (jsexpr->string episode)))
  (tlog:log-append! data-dir final-bytes)

  episode)

(define (last-rec lst)
  (cond [(null? (cdr lst)) (car lst)]
        [else (last-rec (cdr lst))]))

(define (verify-episode data-dir episode)
  ;; Two checks:
  ;;   1. The ephemeral pubkey signature was made by the AID's verkey
  ;;      at the seq named in kel_anchor.
  ;;   2. The Episode signature was made by the ephemeral pubkey.
  (define actor (hash-ref (hash-ref episode 'kel_anchor) 'aid))
  (define seq (hash-ref (hash-ref episode 'kel_anchor) 'seq))
  (define eph-pk-cesr (hash-ref episode 'ephemeral_pubkey))
  (define eph-pk-sig (id:cesr-sig->bytes (hash-ref episode 'ephemeral_pubkey_sig)))
  (define eph-pk-bytes (id:cesr-decode-32 eph-pk-cesr))
  ;; Reconstruct the payload (without sig + ephemeral_pubkey_sig + kel_anchor)
  ;; for signature verification.
  (define payload
    (let* ([h (hash-remove episode 'sig)]
           [h (hash-remove h 'ephemeral_pubkey_sig)]
           [h (hash-remove h 'kel_anchor)])
      h))
  (define payload-bytes (canonical-bytes-for-signing payload))
  (define ep-sig (id:cesr-sig->bytes (hash-ref episode 'sig)))
  ;; Check 1: AID@seq verkey verifies the ephemeral_pubkey_sig over eph-pk-cesr.
  (define eph-cesr-bytes (string->bytes/utf-8 eph-pk-cesr))
  (define check-1 (id:aid-verify data-dir actor seq eph-cesr-bytes eph-pk-sig))
  ;; Check 2: ephemeral_pubkey verifies the episode `sig` over payload-bytes.
  (define check-2 (id:verify-with-verkey eph-pk-bytes payload-bytes ep-sig))
  (and check-1 check-2))

(define (load-episodes data-dir)
  (define f (episodes-file data-dir))
  (cond
    [(not (file-exists? f)) '()]
    [else
     (for/list ([line (in-list (file->lines f))]
                #:when (not (zero? (string-length line))))
       (string->jsexpr line))]))
