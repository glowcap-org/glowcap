#lang racket/base

;; Private ABI constants for the Racket pancake binding.

(provide OK WOULD-BLOCK FRAME-SHAPE-BYTE
         HOST-ACTION-DIAL HOST-ACTION-FLUSH HOST-ACTION-NEED-GIFT-ID
         HOST-ACTION-SETTLE HOST-ACTION-FAIL HOST-ACTION-CLOSE
         REF-NEAR REF-FAR REF-PROMISE REF-STURDY REF-BROKEN
         REF-OBJECT REF-PROMISE-KIND
         ARG-INTEGER ARG-FLOAT64 ARG-BOOLEAN ARG-BYTES
         ARG-STRING ARG-SYMBOL ARG-VOID ARG-REFERENCE ARG-LIST
         ARG-SET ARG-TAGGED ARG-KEYWORD ARG-BIG-INTEGER
         CODEC-SYRUP CODEC-CAPNP
         ABORT-DOMAIN-CODEC ABORT-DOMAIN-SESSION ABORT-DOMAIN-FOREIGN
         REDEEMED-TOKEN-BASE
         ERR-UNSUPPORTED-VALUE ERR-BROKEN ERR-CLOSED ERR-INVALID-ARGUMENT)

(define OK 0)
(define WOULD-BLOCK -7)
(define FRAME-SHAPE-BYTE 0)
;; PancakeHostAction.kind: what the embedder must do next for the byte-fed
;; host; mirrors PANCAKE_HOST_ACTION_* in pancake_driver.h.
(define HOST-ACTION-DIAL 0) (define HOST-ACTION-FLUSH 1) (define HOST-ACTION-NEED-GIFT-ID 2)
(define HOST-ACTION-SETTLE 3) (define HOST-ACTION-FAIL 4) (define HOST-ACTION-CLOSE 5)
(define REF-NEAR 0) (define REF-FAR 1) (define REF-PROMISE 2)
(define REF-STURDY 3) (define REF-BROKEN 4)
(define REF-OBJECT 0) (define REF-PROMISE-KIND 1)
(define ARG-INTEGER 0) (define ARG-FLOAT64 1) (define ARG-BOOLEAN 2) (define ARG-BYTES 3)
(define ARG-STRING 4) (define ARG-SYMBOL 5) (define ARG-VOID 6) (define ARG-REFERENCE 7) (define ARG-LIST 8)
(define ARG-SET 9) (define ARG-TAGGED 10) (define ARG-KEYWORD 11)
(define ARG-BIG-INTEGER 12)
;; `codec` for the transport endpoints; mirrors PANCAKE_CODEC_* in
;; pancake_ocapn.h.
(define CODEC-SYRUP 0) (define CODEC-CAPNP 1)
;; PancakeLastAbort.domain; mirrors PANCAKE_ABORT_DOMAIN_* in pancake_ocapn.h.
(define ABORT-DOMAIN-CODEC 0) (define ABORT-DOMAIN-SESSION 1) (define ABORT-DOMAIN-FOREIGN 2)
;; The reserved redeemed-handoff-token far-id range (ADR-0066): far ids at or
;; above this are node-minted tokens (a fetched capability's node-unique
;; identity, released through pancake_host_gc_release), never wire imports;
;; mirrors PANCAKE_REDEEMED_TOKEN_BASE in pancake_ocapn.h.
(define REDEEMED-TOKEN-BASE 1152921504606846976)
(define ERR-UNSUPPORTED-VALUE -13)
(define ERR-BROKEN -14)
(define ERR-CLOSED -8)
(define ERR-INVALID-ARGUMENT -3)
