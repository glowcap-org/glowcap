#lang racket/base
;; audit.rkt — entry point for the kernel's audit command.
;;
;; Reads .data/episodes.jsonld and the per-AID KEL files, verifies every
;; Episode's signature chain end-to-end, and prints a human-readable trace
;; in the form: "<aid> invoked <affordance> at <valid-time> under <policy-grant>".
;;
;; Drive externally via reference/tests/episode-audit/run.sh, which sets
;; GOBLINS_DATA_DIR to the sibling accountability-on-goblins/.data/ tree
;; the kernel populated, then invokes `racket audit.rkt`.

(require racket/string
         (prefix-in id: "identity.rkt")
         (prefix-in ep: "episode.rkt"))

(define (data-dir)
  ;; Mirror kernel.rkt's resolution rule: honor GOBLINS_DATA_DIR when set
  ;; (the pixi tasks under reference/ pin it explicitly), fall back to a
  ;; sibling .data/ under the current directory.
  (define override (getenv "GOBLINS_DATA_DIR"))
  (cond
    [(and override (not (string=? override ""))) override]
    [else (build-path (current-directory) ".data")]))

(define (short id)
  ;; Print AIDs / SAIDs in shortened form: first 8 + "…" + last 4 chars.
  (cond
    [(< (string-length id) 16) id]
    [else
     (string-append (substring id 0 8) "…" (substring id (- (string-length id) 4)))]))

(define (run-audit)
  (define D (data-dir))
  (define episodes (ep:load-episodes D))
  (cond
    [(null? episodes)
     (printf "No Episodes found at ~a/episodes.jsonld.~n" D)
     (printf "Run kernel.rkt first.~n")]
    [else
     (printf "=== Episode trace ===~n")
     (printf "(~a Episode~a from ~a/episodes.jsonld)~n~n"
             (length episodes)
             (if (= 1 (length episodes)) "" "s")
             D)
     (for ([ep (in-list episodes)]
           [i (in-naturals 1)])
       (define actor (hash-ref (hash-ref ep 'kel_anchor) 'aid))
       (define seq (hash-ref (hash-ref ep 'kel_anchor) 'seq))
       (define affordance
         (regexp-replace #rx"^goblins:affordance/" (hash-ref (hash-ref ep 'object) 'affordance) ""))
       (define valid-time (hash-ref ep 'valid_time_start))
       (define policy-grant (hash-ref ep 'policy_grant))
       (define ok? (ep:verify-episode D ep))
       (printf "Episode ~a:~n" i)
       (printf "  actor:           ~a (~a)~n" (short actor) actor)
       (printf "  invoked:         ~a~n" affordance)
       (printf "  at:              ~a (valid_time)~n" valid-time)
       (printf "  authority:       ~a~n" policy-grant)
       (printf "  KEL anchor:      seq=~a (post-rotation)~n" seq)
       (printf "  signature chain: ~a~n" (if ok? "VERIFIED" "INVALID"))
       (printf "~n")
       (unless ok?
         (error 'audit "Episode ~a failed verification" i)))
     (printf "All ~a Episode~a verified.~n"
             (length episodes)
             (if (= 1 (length episodes)) "" "s"))]))

(run-audit)
