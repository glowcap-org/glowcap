#lang racket/base
;; ocapn-names.rkt — the two names CapTP derives from session keys.
;;
;; A **Public Identifier** names one end of a session. It is the double SHA256
;; of that end's session key written as the gcrypt s-expression
;; `[public-key [ecc [curve Ed25519] [flags eddsa] [q <key>]]]`, in Syrup.
;;
;; A **Session ID** names the session itself. It is the double SHA256 of the
;; bytes `prot0` followed by the two ends' Public Identifiers sorted
;; byte-ascending. The sort is why both ends reach the same value even though
;; one dialed and the other answered, and it is why neither end has to be told
;; the name: each derives it from the two keys the handshake already exchanged.
;;
;; Both names are spelled here so a trace this vat publishes calls a session
;; what every other OCapN implementation calls it. The test submodule holds that
;; against glowcap's own known answers.

(require crypto
         crypto/libcrypto
         syrup)

(provide public-identifier
         session-id
         session-id-hex)

;; Goblins's own CapTP installs this when nothing else has; a module that
;; derives the same names outside a Goblins session needs it too.
(when (null? (crypto-factories))
  (crypto-factories (list libcrypto-factory)))

(define (sha256d bs)
  (digest 'sha256 (digest 'sha256 bs)))

;; `encoded-key` is the gcrypt public key exactly as it travels in
;; `op:start-session`, so the bytes hashed here are the bytes the wire carried.
(define (public-identifier encoded-key)
  (sha256d (syrup-encode encoded-key)))

(define (session-id id-a id-b)
  (sha256d (apply bytes-append #"prot0" (sort (list id-a id-b) bytes<?))))

;; The Session ID of the session these two encoded keys are the ends of, as the
;; 64 lowercase hex digits a timeline record carries.
(define (session-id-hex our-key their-key)
  (bytes->hex-string
   (session-id (public-identifier our-key) (public-identifier their-key))))

(module+ test
  (require rackunit
           (only-in file/sha1 hex-string->bytes))

  ;; The two Ed25519 public keys glowcap's `test/foundation/crypto_test.zig`
  ;; pins, and the Public Identifier and Session ID it computes from them. The
  ;; names have to agree byte for byte or a session watched from both ends draws
  ;; as two.
  (define key-a
    (hex-string->bytes "ea4a6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea691446d22c"))
  (define key-b
    (hex-string->bytes "fd1724385aa0c75b64fb78cd602fa1d991fdebf76b13c58ed702eac835e9f618"))

  (define (gcrypt key)
    `(public-key (ecc (curve Ed25519) (flags eddsa) (q ,key))))

  (check-equal?
   (bytes->hex-string (public-identifier (gcrypt key-a)))
   "14ae19923f3db01381d0b288a271ed3a1486d4805e04c4f8a48142af3750c3bd")

  (check-equal?
   (session-id-hex (gcrypt key-a) (gcrypt key-b))
   "c82ee84990a789fa8e1f14d910d1c5cbfd245814dd3a32740bbe309e31f1c2ed")

  ;; Dial order does not enter the name.
  (check-equal? (session-id-hex (gcrypt key-a) (gcrypt key-b))
                (session-id-hex (gcrypt key-b) (gcrypt key-a))))
