#lang racket/base
;; identity.rkt — minimum-subset KERI in plain Racket.
;;
;; Implements the KERI primitives the kernel touches: AID inception, one
;; rotation, sign, verify. Uses Ed25519 via libsodium FFI; Blake3-256 via
;; libb3 FFI. CESR primitive encoding (B-prefix verkeys, D-prefix transferable
;; verkeys, E-prefix Blake3 SAIDs, 0B-prefix Ed25519 signatures). KEL events
;; serialized as keripy-compatible JSON with version string + SAID derivation
;; per spec.
;;
;; Conformance is verified externally by the keripy oracle at
;; reference/tests/keri-conformance/oracle/verify.py — driven via
;; reference/tests/keri-conformance/run.sh.

(require racket/string
         racket/file
         racket/format
         racket/match
         (prefix-in b64: net/base64)
         json
         ffi/unsafe
         ffi/unsafe/define)

;; Public API. Contracts are skipped at the kernel scope because `->` from
;; `racket/contract` collides with the `->` arrow used inside `_fun` syntax
;; from `ffi/unsafe`. Re-add contracts on the boundary if/when the FFI
;; primitives move to a separate sub-module.
(provide
 make-aid
 rotate-aid
 aid-sign
 aid-verify
 load-kel
 aid-current-verkey
 aid-ephemeral-keypair
 ephemeral-sign
 verify-with-verkey
 cesr-encode-32
 cesr-encode-64
 cesr-decode-32
 cesr-decode-64
 blake3-256
 cesr-sig->bytes)

;; ============================================================================
;; FFI: libsodium for Ed25519
;; ============================================================================

(define-ffi-definer define-sodium
  (ffi-lib "libsodium" '("23" "26" "")))

(define-sodium sodium_init (_fun -> _int))
(define-sodium crypto_sign_keypair
  (_fun [pk : (_bytes o 32)]
        [sk : (_bytes o 64)]
        -> [r : _int]
        -> (values pk sk)))
(define-sodium crypto_sign_detached
  (_fun [sig : (_bytes o 64)]
        [siglen : _pointer = #f]
        [msg : _bytes]
        [msglen : _ulong = (bytes-length msg)]
        [sk : _bytes]
        -> [r : _int]
        -> (if (zero? r) sig (error 'crypto_sign_detached "failed: ~a" r))))
(define-sodium crypto_sign_verify_detached
  (_fun [sig : _bytes]
        [msg : _bytes]
        [msglen : _ulong = (bytes-length msg)]
        [pk : _bytes]
        -> _int))

(define _sodium-init-result (sodium_init))
(unless (>= _sodium-init-result 0)
  (error 'identity "libsodium init failed: ~a" _sodium-init-result))

;; ============================================================================
;; FFI: libblake3 for Blake3-256
;; ============================================================================
;; libb3 is the BLAKE3 reference C library. The hasher is a 1912-byte struct
;; in the upstream layout; we allocate a generous buffer.

(define-ffi-definer define-blake3
  (ffi-lib "libblake3" '("0" "1" "")
           #:fail
           (lambda ()
             ;; Fallback: try libb3 (Debian package name).
             (ffi-lib "libb3" '("0" "")))))

(define BLAKE3_HASHER_SIZE 2048) ;; upstream is ~1912 bytes; round up.

(define-blake3 blake3_hasher_init
  (_fun _pointer -> _void))
(define-blake3 blake3_hasher_update
  (_fun _pointer _bytes _ulong -> _void))
(define-blake3 blake3_hasher_finalize
  (_fun _pointer [out : (_bytes o 32)] [outlen : _ulong = 32]
        -> _void
        -> out))

(define (blake3-256 data)
  (define hasher (make-bytes BLAKE3_HASHER_SIZE 0))
  (blake3_hasher_init hasher)
  (blake3_hasher_update hasher data (bytes-length data))
  (blake3_hasher_finalize hasher))

;; ============================================================================
;; CESR encoding
;; ============================================================================
;; 1-char prefix codes (B/D/E/etc): payload-32-bytes prepended with 1 NUL byte
;; → 33 bytes → base64url 44 chars; first char ('A') replaced with prefix code.
;;
;; 2-char prefix codes (0B/0C/etc): payload-64-bytes prepended with 2 NUL bytes
;; → 66 bytes → base64url 88 chars; first 2 chars ('AA') replaced with prefix.
;;
;; Base64url uses '-_' instead of '+/' and no padding.

(define (b64url-encode bs)
  ;; net/base64 produces standard base64 with '+/' and possible '=' padding;
  ;; transform to url-safe and strip padding.
  (define std (bytes->string/latin-1 (b64:base64-encode bs #"")))
  (define translated
    (regexp-replaces std
                     '([#rx"\\+" "-"]
                       [#rx"/" "_"]
                       [#rx"=+$" ""])))
  translated)

(define (b64url-decode str)
  ;; Reverse: pad to multiple-of-4, swap '-_' back to '+/'.
  (define swapped (regexp-replaces str '([#rx"-" "+"] [#rx"_" "/"])))
  (define pad-needed (modulo (- 4 (modulo (string-length swapped) 4)) 4))
  (define padded (string-append swapped (make-string pad-needed #\=)))
  (b64:base64-decode (string->bytes/latin-1 padded)))

(define (cesr-encode-32 prefix-char payload)
  (unless (= 32 (bytes-length payload))
    (error 'cesr-encode-32 "payload must be 32 bytes, got ~a" (bytes-length payload)))
  (define prepended (bytes-append #"\0" payload))
  (define encoded (b64url-encode prepended))
  (string-append (string prefix-char) (substring encoded 1)))

(define (cesr-decode-32 cesr-str)
  (unless (= 44 (string-length cesr-str))
    (error 'cesr-decode-32 "expected 44 chars, got ~a (~s)" (string-length cesr-str) cesr-str))
  (define swapped (string-append "A" (substring cesr-str 1)))
  (define decoded (b64url-decode swapped))
  (subbytes decoded 1)) ;; strip leading NUL byte

(define (cesr-encode-64 prefix-2 payload)
  (unless (= 64 (bytes-length payload))
    (error 'cesr-encode-64 "payload must be 64 bytes, got ~a" (bytes-length payload)))
  (unless (= 2 (string-length prefix-2))
    (error 'cesr-encode-64 "prefix must be 2 chars, got ~s" prefix-2))
  (define prepended (bytes-append #"\0\0" payload))
  (define encoded (b64url-encode prepended))
  (string-append prefix-2 (substring encoded 2)))

(define (cesr-decode-64 cesr-str)
  (unless (= 88 (string-length cesr-str))
    (error 'cesr-decode-64 "expected 88 chars, got ~a" (string-length cesr-str)))
  (define swapped (string-append "AA" (substring cesr-str 2)))
  (define decoded (b64url-decode swapped))
  (subbytes decoded 2))

(define (cesr-sig->bytes cesr-str)
  (cesr-decode-64 cesr-str))

;; ============================================================================
;; Deterministic JSON serialization
;; ============================================================================
;; keripy uses `json.dumps(d, separators=(",",":"))` — compact JSON, no spaces.
;; Racket's hashes don't preserve insertion order on `hash-keys`, and KERI
;; events have a CANONICAL FIELD ORDER (v, t, d, i, s, p, kt, k, nt, n, bt,
;; b, br, ba, c, a) that matters for SAID derivation. We render KERI events
;; in the canonical order; non-event hashes are sorted alphabetically (which
;; matches Python's parse-then-reserialize behavior for Episodes).

(define KERI-EVENT-FIELD-ORDER
  '(v t d i s p kt k nt n bt b br ba c a))

(define (sort-symbols syms)
  (sort syms symbol<?))

(define (hash-keys-canonical h)
  ;; If this hash looks like a KERI event (contains 'v 't 'd) emit in KERI
  ;; canonical field order, then any unknown extra keys sorted alphabetically
  ;; (matches verify.py's keri_canonical for forward-compatibility with future
  ;; event types). Non-event hashes sort alphabetically (deterministic; matches
  ;; Python's behavior when re-serializing parsed JSON dicts).
  (cond
    [(and (hash-has-key? h 'v) (hash-has-key? h 't) (hash-has-key? h 'd))
     (define present-canonical
       (filter (lambda (k) (hash-has-key? h k)) KERI-EVENT-FIELD-ORDER))
     (define extras
       (sort-symbols
        (filter (lambda (k) (not (member k KERI-EVENT-FIELD-ORDER)))
                (hash-keys h))))
     (append present-canonical extras)]
    [else
     (sort-symbols (hash-keys h))]))

(define (jswrite-compact je)
  (cond
    [(hash? je)
     (string-append
      "{"
      (string-join
       (for/list ([k (in-list (hash-keys-canonical je))])
         (string-append (jswrite-compact (symbol->string k))
                        ":"
                        (jswrite-compact (hash-ref je k))))
       ",")
      "}")]
    [(list? je)
     (string-append
      "["
      (string-join (map jswrite-compact je) ",")
      "]")]
    [(string? je)
     ;; JSON-escape minimal set; KEL events use only ASCII.
     (define escaped
       (regexp-replaces je
                        '([#rx"\\\\" "\\\\\\\\"]
                          [#rx"\"" "\\\\\""])))
     (string-append "\"" escaped "\"")]
    [(exact-integer? je) (number->string je)]
    [(real? je) (number->string je)]
    [(eq? je #t) "true"]
    [(eq? je #f) "false"]
    [(eq? je 'null) "null"]
    [else (error 'jswrite-compact "unsupported: ~v" je)]))

;; ============================================================================
;; KERI event construction
;; ============================================================================
;; Version string format: "KERI10JSON{size:06x}_" where size is total event
;; serialization length in bytes (including the version string itself).
;; SAID derivation: set v with placeholder zeros, set d (and i for icp) with
;; 44-char "############################################" placeholder; serialize;
;; replace placeholder with v=actual-size; serialize again; that serialization's
;; Blake3 hash, CESR-encoded with E prefix, IS the SAID. Then substitute SAID
;; into d (and i) and reserialize for storage.

(define SAID-PLACEHOLDER (make-string 44 #\#))
(define V-PREFIX "KERI10JSON")
(define V-SUFFIX "_")
(define V-SIZE-WIDTH 6)

(define (make-version-string size)
  (string-append V-PREFIX
                 (~r size #:base 16 #:min-width V-SIZE-WIDTH #:pad-string "0")
                 V-SUFFIX))

(define (size-of-serialized-event evt-hash)
  (bytes-length (string->bytes/utf-8 (jswrite-compact evt-hash))))

(define (saidify evt-hash icp?)
  ;; evt-hash must already have d (and i if icp) set to placeholder, v set to placeholder.
  (define stage1 (hash-set evt-hash 'v (make-version-string 0)))
  (define size (size-of-serialized-event stage1))
  (define stage2 (hash-set evt-hash 'v (make-version-string size)))
  (define ser-bytes (string->bytes/utf-8 (jswrite-compact stage2)))
  (define said-bytes (blake3-256 ser-bytes))
  (define said-cesr (cesr-encode-32 #\E said-bytes))
  (define stage3 (hash-set stage2 'd said-cesr))
  (define final
    (if icp?
        (hash-set stage3 'i said-cesr)
        stage3))
  (values final said-cesr))

(define (build-icp-event verkey-cesr next-key-digest-cesr)
  ;; Inception event. Both 'd' (event SAID) and 'i' (controller AID) become
  ;; the same SAID for icp.
  (define base
    (hasheq 'v (make-version-string 0)
            't "icp"
            'd SAID-PLACEHOLDER
            'i SAID-PLACEHOLDER
            's "0"
            'kt "1"
            'k (list verkey-cesr)
            'nt "1"
            'n (list next-key-digest-cesr)
            'bt "0"
            'b '()
            'c '()
            'a '()))
  (saidify base #t))

(define (build-rot-event aid-cesr seq-hex prior-said-cesr verkey-cesr next-key-digest-cesr)
  (define base
    (hasheq 'v (make-version-string 0)
            't "rot"
            'd SAID-PLACEHOLDER
            'i aid-cesr
            's seq-hex
            'p prior-said-cesr
            'kt "1"
            'k (list verkey-cesr)
            'nt "1"
            'n (list next-key-digest-cesr)
            'bt "0"
            'br '()
            'ba '()
            'a '()))
  (saidify base #f))

;; ============================================================================
;; KEL persistence
;; ============================================================================
;; Each AID gets its own JSON-lines file: one event per line, plus a trailing
;; signature record per event. Format chosen to be simple and round-trippable;
;; keripy oracle reads the events + reconstructs CESR signature attachments.

(define (kel-path data-dir aid)
  (define kel-dir (build-path data-dir "kel"))
  (make-directory* kel-dir)
  (build-path kel-dir (format "~a.kel.jsonl" aid)))

(define (signing-key-path data-dir aid seq-hex)
  ;; Stored signing keys (for the kernel only — production would use OS keystore).
  (define keys-dir (build-path data-dir "keys"))
  (make-directory* keys-dir)
  (build-path keys-dir (format "~a-~a.sk" aid seq-hex)))

(define (next-key-path data-dir aid seq-hex)
  ;; Pre-generated next signing key, committed as digest in current event.
  (define keys-dir (build-path data-dir "keys"))
  (make-directory* keys-dir)
  (build-path keys-dir (format "~a-next-~a.sk" aid seq-hex)))

(define (write-bytes-to-file path bs)
  (call-with-output-file path
    #:exists 'replace
    #:permissions #o600
    (lambda (out) (write-bytes bs out))))

(define (read-bytes-from-file path)
  (call-with-input-file path
    (lambda (in)
      (port->bytes in))))

(define (port->bytes in)
  (define buf (make-bytes 0))
  (let loop ([acc buf])
    (define chunk (make-bytes 4096))
    (define n (read-bytes-avail! chunk in))
    (cond
      [(eof-object? n) acc]
      [else (loop (bytes-append acc (subbytes chunk 0 n)))])))

(define (append-kel-line! kel-file rec)
  (call-with-output-file kel-file
    #:exists 'append
    (lambda (out)
      (write-string (jswrite-compact rec) out)
      (newline out))))

(define (read-kel-lines kel-file)
  (cond
    [(not (file-exists? kel-file)) '()]
    [else
     (for/list ([line (in-list (file->lines kel-file))]
                #:when (not (zero? (string-length line))))
       (string->jsexpr line))]))

;; ============================================================================
;; AID lifecycle
;; ============================================================================

(define (gen-keypair)
  (define-values (pk sk) (crypto_sign_keypair))
  (values pk sk))

(define (verkey-cesr pk-bytes)
  ;; Use D-prefix (Ed25519 transferable) since the kernel demonstrates rotation.
  (cesr-encode-32 #\D pk-bytes))

(define (next-key-digest pk-bytes)
  ;; The next-key COMMITMENT is the Blake3 digest of the CESR-encoded next verkey.
  ;; This is the standard KERI pre-rotation form.
  (define next-vk-cesr (verkey-cesr pk-bytes))
  (define digest-bytes (blake3-256 (string->bytes/utf-8 next-vk-cesr)))
  (cesr-encode-32 #\E digest-bytes))

(define (sign-event-bytes evt-bytes sk-bytes)
  (crypto_sign_detached evt-bytes sk-bytes))

(define (verify-event-bytes evt-bytes sig-bytes pk-bytes)
  (zero? (crypto_sign_verify_detached sig-bytes evt-bytes pk-bytes)))

(define (make-aid data-dir)
  (define-values (pk sk) (gen-keypair))
  (define-values (next-pk next-sk) (gen-keypair))
  (define vk-cesr (verkey-cesr pk))
  (define next-digest (next-key-digest next-pk))
  (define-values (icp-evt aid) (build-icp-event vk-cesr next-digest))
  (define evt-bytes (string->bytes/utf-8 (jswrite-compact icp-evt)))
  (define sig-bytes (sign-event-bytes evt-bytes sk))
  (define sig-cesr (cesr-encode-64 "0B" sig-bytes))
  ;; Persist event + signature record + private keys.
  (define kel-file (kel-path data-dir aid))
  (append-kel-line! kel-file (hasheq 'event icp-evt 'sigs (list sig-cesr)))
  (write-bytes-to-file (signing-key-path data-dir aid "0") sk)
  (write-bytes-to-file (next-key-path data-dir aid "0") next-sk)
  (values aid kel-file))

(define (kel-last-event data-dir aid)
  (define lines (read-kel-lines (kel-path data-dir aid)))
  (when (null? lines)
    (error 'kel-last-event "empty KEL for ~a" aid))
  (last lines))

(define (last lst)
  (cond [(null? (cdr lst)) (car lst)]
        [else (last (cdr lst))]))

(define (rotate-aid data-dir aid)
  (define last-rec (kel-last-event data-dir aid))
  (define prior-evt (hash-ref last-rec 'event))
  (define prior-said (hash-ref prior-evt 'd))
  (define prior-seq-hex (hash-ref prior-evt 's))
  (define new-seq-hex (~r (+ 1 (string->number prior-seq-hex 16)) #:base 16))
  ;; KERI rotation invariant: the rot event is signed by the PRIOR event's
  ;; signing key (the OLD key that's rotating out). The previously-committed
  ;; next-key becomes the new active key in rot.k[0]; the rotation itself
  ;; is authorized by the old key per pre-rotation discipline.
  (define old-signing-sk (read-bytes-from-file (signing-key-path data-dir aid prior-seq-hex)))
  (define new-active-sk (read-bytes-from-file (next-key-path data-dir aid prior-seq-hex)))
  (define new-active-pk (subbytes new-active-sk 32 64)) ;; libsodium stores pk in last 32 bytes of sk
  (define vk-cesr (verkey-cesr new-active-pk))
  (define-values (next-pk next-sk) (gen-keypair))
  (define next-digest (next-key-digest next-pk))
  (define-values (rot-evt rot-said) (build-rot-event aid new-seq-hex prior-said vk-cesr next-digest))
  (define evt-bytes (string->bytes/utf-8 (jswrite-compact rot-evt)))
  (define sig-bytes (sign-event-bytes evt-bytes old-signing-sk))
  (define sig-cesr (cesr-encode-64 "0B" sig-bytes))
  (append-kel-line! (kel-path data-dir aid)
                    (hasheq 'event rot-evt 'sigs (list sig-cesr)))
  (write-bytes-to-file (signing-key-path data-dir aid new-seq-hex) new-active-sk)
  (write-bytes-to-file (next-key-path data-dir aid new-seq-hex) next-sk)
  rot-said)

(define (aid-current-verkey data-dir aid)
  (define last-rec (kel-last-event data-dir aid))
  (define evt (hash-ref last-rec 'event))
  (car (hash-ref evt 'k)))

(define (aid-current-sk data-dir aid)
  (define last-rec (kel-last-event data-dir aid))
  (define seq-hex (hash-ref (hash-ref last-rec 'event) 's))
  (read-bytes-from-file (signing-key-path data-dir aid seq-hex)))

(define (aid-sign data-dir aid msg-bytes)
  (define sk (aid-current-sk data-dir aid))
  (sign-event-bytes msg-bytes sk))

(define (aid-verify data-dir aid seq-hex msg-bytes sig-bytes)
  (define lines (read-kel-lines (kel-path data-dir aid)))
  (define evt-rec (findf (lambda (rec)
                           (define evt (hash-ref rec 'event))
                           (string=? seq-hex (hash-ref evt 's)))
                         lines))
  (cond
    [(not evt-rec) #f]
    [else
     (define vk-cesr (car (hash-ref (hash-ref evt-rec 'event) 'k)))
     (define vk-bytes (cesr-decode-32 vk-cesr))
     (verify-event-bytes msg-bytes sig-bytes vk-bytes)]))

(define (load-kel data-dir aid)
  (read-kel-lines (kel-path data-dir aid)))

(define (aid-ephemeral-keypair data-dir aid)
  ;; Sigstore-shaped: an ephemeral keypair generated fresh per use, then
  ;; countersigned by the AID's current rotation key (caller's responsibility
  ;; to invoke aid-sign on the ephemeral pubkey bytes).
  (define-values (eph-pk eph-sk) (gen-keypair))
  (values eph-pk eph-sk (verkey-cesr eph-pk)))

(define (ephemeral-sign sk-bytes msg-bytes)
  (sign-event-bytes msg-bytes sk-bytes))

(define (verify-with-verkey pk-bytes msg-bytes sig-bytes)
  (verify-event-bytes msg-bytes sig-bytes pk-bytes))

(define (findf pred lst)
  (cond [(null? lst) #f]
        [(pred (car lst)) (car lst)]
        [else (findf pred (cdr lst))]))
