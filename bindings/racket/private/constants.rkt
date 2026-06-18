#lang racket/base

;; Private ABI constants for the Racket pancake binding.

(provide OK WOULD-BLOCK FRAME-SHAPE-BYTE EVENT-DELIVER EVENT-RESOLVE
         REF-NEAR REF-FAR REF-PROMISE REF-STURDY REF-BROKEN
         REF-OBJECT REF-PROMISE-KIND
         ARG-INTEGER ARG-FLOAT64 ARG-BOOLEAN ARG-BYTES
         ARG-STRING ARG-SYMBOL ARG-VOID ARG-REFERENCE ARG-LIST
         ARG-SET ARG-TAGGED ARG-KEYWORD ARG-BIG-INTEGER
         RESOLUTION-FULFILL RESOLUTION-BREAK RESOLUTION-HANDOFF
         HINTS-EMPTY-MAP HINTS-EMPTY-FALSE
         CAPTP-VERSION-V1-0 CAPTP-VERSION-PRE-SPEC
         CODEC-SYRUP CODEC-CAPNP
         ABORT-DOMAIN-CODEC ABORT-DOMAIN-SESSION ABORT-DOMAIN-FOREIGN
         ENLIVEN-FRESH ENLIVEN-CACHED ENLIVEN-IN-FLIGHT
         ENLIVEN-OUTCOME-FULFILLED ENLIVEN-OUTCOME-BROKEN
         ERR-UNSUPPORTED-VALUE ERR-BROKEN ERR-CLOSED ERR-INVALID-ARGUMENT)

(define OK 0)
(define WOULD-BLOCK -7)
(define FRAME-SHAPE-BYTE 0)
(define EVENT-DELIVER 1)
(define EVENT-RESOLVE 2)
(define REF-NEAR 0) (define REF-FAR 1) (define REF-PROMISE 2)
(define REF-STURDY 3) (define REF-BROKEN 4)
(define REF-OBJECT 0) (define REF-PROMISE-KIND 1)
(define ARG-INTEGER 0) (define ARG-FLOAT64 1) (define ARG-BOOLEAN 2) (define ARG-BYTES 3)
(define ARG-STRING 4) (define ARG-SYMBOL 5) (define ARG-VOID 6) (define ARG-REFERENCE 7) (define ARG-LIST 8)
(define ARG-SET 9) (define ARG-TAGGED 10) (define ARG-KEYWORD 11)
(define ARG-BIG-INTEGER 12)
(define RESOLUTION-FULFILL 0) (define RESOLUTION-BREAK 1) (define RESOLUTION-HANDOFF 2)
;; Wire spelling of the empty locator hints in pancake_peer_start_session;
;; mirrors PANCAKE_HINTS_EMPTY_MAP / PANCAKE_HINTS_EMPTY_FALSE in pancake_ocapn.h.
(define HINTS-EMPTY-MAP 0) (define HINTS-EMPTY-FALSE 1)
;; `captp_version` for pancake_peer_new_negotiated; mirrors
;; PANCAKE_CAPTP_VERSION_* in pancake_ocapn.h.
(define CAPTP-VERSION-V1-0 0) (define CAPTP-VERSION-PRE-SPEC 1)
;; `codec` for pancake_peer_new_negotiated and the tcp endpoints; mirrors
;; PANCAKE_CODEC_* in pancake_ocapn.h.
(define CODEC-SYRUP 0) (define CODEC-CAPNP 1)
;; PancakeLastAbort.domain; mirrors PANCAKE_ABORT_DOMAIN_* in pancake_ocapn.h.
(define ABORT-DOMAIN-CODEC 0) (define ABORT-DOMAIN-SESSION 1) (define ABORT-DOMAIN-FOREIGN 2)
;; PancakeEnlivenStart.status / pancake_peer_record_enlivenment outcome; mirrors
;; PANCAKE_ENLIVEN_* in pancake_ocapn.h.
(define ENLIVEN-FRESH 0) (define ENLIVEN-CACHED 1) (define ENLIVEN-IN-FLIGHT 2)
(define ENLIVEN-OUTCOME-FULFILLED 0) (define ENLIVEN-OUTCOME-BROKEN 1)
(define ERR-UNSUPPORTED-VALUE -13)
(define ERR-BROKEN -14)
(define ERR-CLOSED -8)
(define ERR-INVALID-ARGUMENT -3)
