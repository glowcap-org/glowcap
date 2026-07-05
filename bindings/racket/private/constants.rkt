#lang racket/base

;; Private ABI constants for the Racket pancake binding.

(provide OK WOULD-BLOCK FRAME-SHAPE-BYTE
         PROJECTION-DELIVER PROJECTION-RESOLVE PROJECTION-FRAME
         NODE-ACTION-DIAL NODE-ACTION-FLUSH NODE-ACTION-SETTLE
         NODE-ACTION-FAIL NODE-ACTION-NEED-GIFT-ID
         REDEEM-OUTCOME-FAR REDEEM-OUTCOME-BROKEN REDEEM-OUTCOME-NOT-CAPABILITY
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
         REDEEMED-TOKEN-BASE
         ERR-UNSUPPORTED-VALUE ERR-BROKEN ERR-CLOSED ERR-INVALID-ARGUMENT)

(define OK 0)
(define WOULD-BLOCK -7)
(define FRAME-SHAPE-BYTE 0)
;; PancakeAnyEvent.projection: which arm of a polled event is live; mirrors
;; PANCAKE_PROJECTION_* in pancake_ocapn.h.
(define PROJECTION-DELIVER 1)
(define PROJECTION-RESOLVE 2)
(define PROJECTION-FRAME 3)
;; PancakeNodeAction.kind: what the host must do next for the node's serve
;; step; mirrors PANCAKE_NODE_ACTION_* in pancake_ocapn.h.
(define NODE-ACTION-DIAL 1) (define NODE-ACTION-FLUSH 2) (define NODE-ACTION-SETTLE 3)
(define NODE-ACTION-FAIL 4) (define NODE-ACTION-NEED-GIFT-ID 5)
;; pancake_node_claim_resolve outcome; mirrors PANCAKE_REDEEM_OUTCOME_* in
;; pancake_ocapn.h.
(define REDEEM-OUTCOME-FAR 0) (define REDEEM-OUTCOME-BROKEN 1) (define REDEEM-OUTCOME-NOT-CAPABILITY 2)
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
;; The reserved redeemed-handoff-token far-id range (ADR-0066): far ids at or
;; above this are node-minted tokens, never wire imports; mirrors
;; PANCAKE_REDEEMED_TOKEN_BASE in pancake_ocapn.h.
(define REDEEMED-TOKEN-BASE 1152921504606846976)
(define ERR-UNSUPPORTED-VALUE -13)
(define ERR-BROKEN -14)
(define ERR-CLOSED -8)
(define ERR-INVALID-ARGUMENT -3)
