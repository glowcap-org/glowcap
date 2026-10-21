#lang racket/base
;; log.rkt: Sigstore-shaped local transparency log.
;;
;; Append-only file at .data/transparency.log holding Blake3 leaf hashes of
;; each Episode's signed bytes. Merkle root is recomputed on every append so
;; verifiers can check inclusion via a path of sibling hashes. Sigstore-shaped
;; in spirit (transparency log of signed leaves), not Sigstore-conformant,
;; upstream Sigstore service integration is deferred to a later step.

(require racket/contract
         racket/file
         (only-in racket/list last)
         json
         (prefix-in id: "identity.rkt"))

(provide
 (contract-out
  ;; Append a leaf to the log; returns the leaf index (0-based).
  [log-append! (-> path-string? bytes? exact-nonnegative-integer?)]
  ;; Read all leaves in order.
  [log-leaves (-> path-string? (listof bytes?))]
  ;; Compute the Merkle root over all leaves in the log.
  [log-root (-> path-string? bytes?)]
  ;; Inclusion proof for a given leaf index, list of (sibling-bytes, side).
  [log-inclusion-proof (-> path-string? exact-nonnegative-integer?
                           (listof (cons/c bytes? symbol?)))]
  ;; Verify an inclusion proof.
  [log-verify-inclusion (-> bytes? exact-nonnegative-integer? bytes?
                            (listof (cons/c bytes? symbol?)) boolean?)]))

;; Layout: .data/transparency.log is JSON-lines, one record per leaf:
;;   { "i": 0, "h": "<hex-blake3-of-leaf>" }
;; A small companion file .data/transparency.root holds the latest Merkle root
;; in hex so audit can quickly check the head without recomputation.

(define (log-file data-dir)
  (build-path data-dir "transparency.log"))

(define (root-file data-dir)
  (build-path data-dir "transparency.root"))

(define (bytes->hex bs)
  (define out (open-output-string))
  (for ([b (in-bytes bs)])
    (define s (number->string b 16))
    (when (= (string-length s) 1) (write-string "0" out))
    (write-string s out))
  (get-output-string out))

(define (hex->bytes hex)
  (define n (quotient (string-length hex) 2))
  (define bs (make-bytes n))
  (for ([i (in-range n)])
    (define byte (string->number (substring hex (* 2 i) (+ 2 (* 2 i))) 16))
    (bytes-set! bs i byte))
  bs)

(define (read-log-records data-dir)
  (define f (log-file data-dir))
  (cond
    [(not (file-exists? f)) '()]
    [else
     (for/list ([line (in-list (file->lines f))]
                #:when (not (zero? (string-length line))))
       (string->jsexpr line))]))

(define (log-leaves data-dir)
  (for/list ([rec (in-list (read-log-records data-dir))])
    (hex->bytes (hash-ref rec 'h))))

(define (log-append! data-dir leaf-bytes)
  (define leaf-hash (id:blake3-256 leaf-bytes))
  (define index (length (read-log-records data-dir)))
  (define rec (hasheq 'i index 'h (bytes->hex leaf-hash)))
  (call-with-output-file (log-file data-dir)
    #:exists 'append
    (lambda (out)
      (write-string (jsexpr->string rec) out)
      (newline out)))
  ;; Update root.
  (define new-leaves (append (log-leaves data-dir) '()))
  (define root (compute-merkle-root new-leaves))
  (call-with-output-file (root-file data-dir)
    #:exists 'replace
    (lambda (out)
      (write-string (bytes->hex root) out)))
  index)

;; ============================================================================
;; Merkle tree (RFC 6962 / Certificate Transparency style)
;; ============================================================================

;; Hash an internal node: H(0x01 || left || right).
(define (mt-hash-node left right)
  (id:blake3-256 (bytes-append #"\x01" left right)))

;; Compute Merkle root over a list of leaf bytes (leaves are pre-hashed leaf-data).
;; Empty tree is empty bytes.
(define (compute-merkle-root leaves)
  (cond
    [(null? leaves) #""]
    [(null? (cdr leaves)) (car leaves)]
    [else
     (define n (length leaves))
     (define k (largest-power-of-2-leq n))
     (define left-leaves (take leaves k))
     (define right-leaves (list-tail leaves k))
     (mt-hash-node (compute-merkle-root left-leaves)
                   (compute-merkle-root right-leaves))]))

(define (take lst n)
  (cond [(or (zero? n) (null? lst)) '()]
        [else (cons (car lst) (take (cdr lst) (- n 1)))]))

(define (largest-power-of-2-leq n)
  (cond [(<= n 1) 1]
        [else
         (let loop ([k 1])
           (cond [(> (* k 2) (- n 1)) k]
                 [else (loop (* k 2))]))]))

(define (log-root data-dir)
  (compute-merkle-root (log-leaves data-dir)))

;; Inclusion proof: list of (sibling-hash, 'left | 'right) pairs from leaf to root.
(define (compute-inclusion-proof leaves index)
  (cond
    [(<= (length leaves) 1) '()]
    [else
     (define n (length leaves))
     (define k (largest-power-of-2-leq n))
     (cond
       [(< index k)
        ;; Index in left subtree.
        (define right-root (compute-merkle-root (list-tail leaves k)))
        (define left-leaves (take leaves k))
        (append (compute-inclusion-proof left-leaves index)
                (list (cons right-root 'right)))]
       [else
        ;; Index in right subtree.
        (define left-root (compute-merkle-root (take leaves k)))
        (define right-leaves (list-tail leaves k))
        (append (compute-inclusion-proof right-leaves (- index k))
                (list (cons left-root 'left)))])]))

(define (log-inclusion-proof data-dir index)
  (compute-inclusion-proof (log-leaves data-dir) index))

(define (log-verify-inclusion expected-root index leaf-hash proof)
  (let loop ([h leaf-hash] [path proof])
    (cond
      [(null? path) (bytes=? h expected-root)]
      [else
       (define sib (car (car path)))
       (define side (cdr (car path)))
       (define h*
         (case side
           [(left) (mt-hash-node sib h)]
           [(right) (mt-hash-node h sib)]
           [else (error 'log-verify-inclusion "bad side: ~a" side)]))
       (loop h* (cdr path))])))
