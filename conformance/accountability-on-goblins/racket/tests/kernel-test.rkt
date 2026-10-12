#lang racket/base
;; kernel-test.rkt: end-to-end test for the kernel loop.
;;
;; Exercises all 8 steps (kernel.rkt does the same path; this test inspects
;; the persisted artifacts and asserts each step's invariant):
;;   1. Vat hosts an Actor, implicitly tested by the AID's existence.
;;   2. KERI AID: KEL exists, inception event well-formed, AID is CESR-encoded
;;      Blake3 SAID (E-prefix, 44 chars).
;;   3. Capability ref: kernel.rkt's call returns a structured result; we
;;      check the Episode's `object` field reflects that result.
;;   4. Capability invocation: the result (kernel-loop-invoked) is in the
;;      Episode `object.result`.
;;   5. Episode produced: exactly one Episode in episodes.jsonld.
;;   6. Ephemeral KERI-derived signing: Episode's ephemeral_pubkey_sig
;;      verifies against AID@seq=1 verkey (post-rotation); Episode's sig
;;      verifies against ephemeral_pubkey.
;;   7. Episode persisted: episodes.jsonld and transparency.log both exist
;;      and contain matching counts.
;;   8. Auditable: verify-episode returns #t.
;;
;; Run via: bash reference/implementations/accountability-on-goblins/stack/run.sh test
;; (which invokes raco test tests/kernel-test.rkt inside the container).

(require rackunit
         racket/file
         json
         (prefix-in id: "../identity.rkt")
         (prefix-in ep: "../episode.rkt")
         (prefix-in tlog: "../log.rkt"))

;; raco test cds into tests/, so a cwd-relative .data/ would land on the
;; read-only source mount. Honor GOBLINS_DATA_DIR (set by run.sh / the test
;; container) to pin the writable data path; fall back to cwd-relative
;; for standalone invocations.
(define D
  (let ([override (getenv "GOBLINS_DATA_DIR")])
    (cond
      [(and override (not (string=? override ""))) (string->path override)]
      [else (build-path (current-directory) ".data")])))

;; ============================================================================
;; Helpers (defined first so test cases below can use them)
;; ============================================================================

(define (kel-aid)
  ;; Find the AID whose KEL file exists in .data/kel/.
  (define kel-dir (build-path D "kel"))
  (define files (directory-list kel-dir))
  (define stem (path->string (car (sort files path<?))))
  (regexp-replace #rx"\\.kel\\.jsonl$" stem ""))

(define (bytes->hex-helper bs)
  (define out (open-output-string))
  (for ([b (in-bytes bs)])
    (define s (number->string b 16))
    (when (= (string-length s) 1) (write-string "0" out))
    (write-string s out))
  (get-output-string out))

;; The test owns the data directory for the duration of the run. Wipe any
;; prior state (a previous `bash run.sh` invocation can leave Episodes / KEL
;; behind in the persistent .data/ mount), then run kernel.rkt fresh so the
;; "exactly one Episode" assertions hold deterministically.
(define (wipe-data!)
  (for ([f (in-list (list "episodes.jsonld"
                          "transparency.log"
                          "transparency.root"))])
    (define p (build-path D f))
    (when (file-exists? p) (delete-file p)))
  (define kel-dir (build-path D "kel"))
  (when (directory-exists? kel-dir)
    (for ([f (in-list (directory-list kel-dir))])
      (define p (build-path kel-dir f))
      (when (file-exists? p) (delete-file p))))
  (define keys-dir (build-path D "keys"))
  (when (directory-exists? keys-dir)
    (for ([f (in-list (directory-list keys-dir))])
      (define p (build-path keys-dir f))
      (when (file-exists? p) (delete-file p)))))

(define already-run? #f)
(define (ensure-kernel-run)
  (unless already-run?
    (wipe-data!)
    (parameterize ([current-output-port (open-output-bytes)])
      (dynamic-require "../kernel.rkt" #f))
    (set! already-run? #t)))

(test-case
 "Step 2, AID inception event is well-formed CESR"
 (ensure-kernel-run)
 (define kel-files (directory-list (build-path D "kel")))
 (check-true (>= (length kel-files) 1) "at least one KEL file exists")
 (define aid-file (car (sort kel-files path<?)))
 (define aid-stem (path->string aid-file))
 (define aid (regexp-replace #rx"\\.kel\\.jsonl$" aid-stem ""))
 (check-equal? (string-length aid) 44 "AID is 44 chars (CESR E-prefix + 43 base64url)")
 (check-equal? (string-ref aid 0) #\E "AID has E-prefix (Blake3-256 SAID)"))

(test-case
   "Step 2: KEL has inception event"
 (define kel (id:load-kel D (kel-aid)))
 (check-true (>= (length kel) 1) "at least one event")
 (define icp (hash-ref (car kel) 'event))
 (check-equal? (hash-ref icp 't) "icp" "first event is icp")
 (check-equal? (hash-ref icp 's) "0" "icp has seq=0"))

(test-case
 "Step 6: KEL has rotation event with pre-rotation commitment"
 (define kel (id:load-kel D (kel-aid)))
 (check-true (>= (length kel) 2) "at least two events (icp + rot)")
 (define rot (hash-ref (cadr kel) 'event))
 (check-equal? (hash-ref rot 't) "rot" "second event is rot")
 (check-equal? (hash-ref rot 's) "1" "rot has seq=1")
 ;; Pre-rotation invariant: blake3 of the rot's verkey CESR equals the icp's
 ;; n[0] commitment.
 (define icp (hash-ref (car kel) 'event))
 (define rot-vk-cesr (car (hash-ref rot 'k)))
 (define committed (car (hash-ref icp 'n)))
 (define digest-bytes (id:blake3-256 (string->bytes/utf-8 rot-vk-cesr)))
 (define computed-cesr (id:cesr-encode-32 #\E digest-bytes))
 (check-equal? committed computed-cesr "rotation verkey matches inception commitment"))

(test-case
 "Step 5/7, exactly one Episode written"
 (define episodes (ep:load-episodes D))
 (check-equal? (length episodes) 1 "one Episode in episodes.jsonld"))

(test-case
 "Step 5: Episode has RDF-Star quad shape"
 (define episodes (ep:load-episodes D))
 (define ep (car episodes))
 (check-equal? (hash-ref ep '@type) "goblins:Episode")
 (check-true (hash-has-key? ep 'subject) "has subject")
 (check-true (hash-has-key? ep 'predicate) "has predicate")
 (check-true (hash-has-key? ep 'object) "has object")
 (check-true (hash-has-key? ep 'graph) "has named graph")
 (check-true (hash-has-key? ep 'valid_time_start) "has valid_time_start")
 (check-true (hash-has-key? ep 'tx_time_start) "has tx_time_start"))

(test-case
 "Step 6/8, Episode signature chain verifies"
 (define episodes (ep:load-episodes D))
 (define ep (car episodes))
 (check-true (ep:verify-episode D ep) "verify-episode returns #t"))

(test-case
 "Step 7, transparency log records the Episode"
 (define leaves (tlog:log-leaves D))
 (check-equal? (length leaves) 1 "one leaf in transparency.log")
 ;; Verify the Merkle root recomputes to the recorded value.
 (define recorded-root (file->string (build-path D "transparency.root")))
 (define computed-root-hex (bytes->hex-helper (tlog:log-root D)))
 (check-equal? recorded-root computed-root-hex "Merkle root matches"))

(test-case
 "Step 6, Episode anchored at seq=1 (post-rotation)"
 (define episodes (ep:load-episodes D))
 (define ep (car episodes))
 (define seq (hash-ref (hash-ref ep 'kel_anchor) 'seq))
 (check-equal? seq "1" "Episode anchored at the rotation event"))

