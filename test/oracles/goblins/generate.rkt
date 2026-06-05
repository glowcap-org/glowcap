#lang racket/base
;; generate.rkt — Regenerate cross-implementation Syrup byte fixtures.
;;
;; Encodes the seven canonical pancake-codec-syrup wire vectors using
;; the upstream Racket Syrup encoder
;; (reference/implementations/syrup/upstream/impls/racket/syrup/) and
;; writes one .bin file per vector to the directory passed on the
;; command line.
;;
;; The record structure each builder constructs mirrors what
;; pancake-codec-syrup's encoder produces for the corresponding
;; pancake_model::Message value (see
;; crates/codec/pancake-codec-syrup/src/wire_vectors.rs for the side-by-side
;; mapping). The Syrup grammar is small and unambiguous; encoding the
;; same record structure through the Racket reference encoder must
;; produce byte-identical output to the Python reference encoder under
;; reference/tests/syrup-byte-fixtures/.
;;
;; Usage (inside the devcontainer — see
;; reference/tests/syrup-byte-fixtures-goblins/run.sh):
;;
;;   racket generate.rkt <out-dir>
;;
;; The upstream Racket Syrup module is resolved via PLTCOLLECTS, which
;; the sibling pixi task points at
;; `reference/implementations/syrup/upstream/impls/racket/` so
;; `(require syrup/syrup)` finds the submodule's encoder without
;; bind-mounts or path edits.

(require racket/cmdline
         racket/file
         racket/set
         syrup/syrup)

;; ── record builders ────────────────────────────────────────────────

;; <op:abort "shutting down"> — Goblins-shape-aligned.
(define (op-abort-shutting-down)
  (record* 'op:abort "shutting down"))

;; <op:deliver <desc:export 7> [b"hello"] 42 #f>.
;;
;; Field 4 (resolve-me-desc) is pancake-shape divergent — pancake
;; always emits #f (Syrup wire compatibility).
(define (op-deliver-minimal)
  (record* 'op:deliver
           (record* 'desc:export 7)
           (list #"hello")
           42
           #f))

;; <op:resolve 42 <resolve:break <error "target unreachable">>>.
;;
;; The <op:resolve …> envelope is pancake-shape (Syrup wire compatibility).
;; The <error …> payload label is pancake-pinned pending upstream
;; ocapn/ocapn#142.
(define (op-resolve-break)
  (record* 'op:resolve
           42
           (record* 'resolve:break
                    (record* 'error "target unreachable"))))

;; <op:resolve 7 <resolve:fulfill <desc:export 5>>>.
(define (op-resolve-fulfill-far)
  (record* 'op:resolve
           7
           (record* 'resolve:fulfill
                    (record* 'desc:export 5))))

;; <op:resolve 7 <resolve:fulfill <desc:import-object 9>>>.
;;
;; The encoder side of the perspective flip — sender's Reference::Near
;; becomes <desc:import-object N> in payload position. Receiver decode
;; flips it to Reference::Far.
(define (op-resolve-fulfill-near)
  (record* 'op:resolve
           7
           (record* 'resolve:fulfill
                    (record* 'desc:import-object 9))))

;; <op:resolve 7 <resolve:fulfill <desc:answer 11>>>.
(define (op-resolve-fulfill-promise)
  (record* 'op:resolve
           7
           (record* 'resolve:fulfill
                    (record* 'desc:answer 11))))

;; <op:listen <desc:answer 7> <desc:import-object 9>>.
;;
;; Stage 1 op:listen wire-shape per ADR-0007 § Decision 4 — two
;; desc:* reference operands. `to-desc` may be `desc:answer`
;; (pipelining target case) or `desc:export` (local-export target
;; case). `listen-desc` is `desc:import-object` or
;; `desc:import-promise` per the spec; pancake's encoder emits
;; `desc:import-object` for `Reference::Near` listener arguments
;; via the standard payload-position perspective flip.
;;
;; Same shape on PreSpec and V1_0 — adding a new record is wire-
;; additive. The Stage 2 V1_0 Goblins-canonical 3-operand
;; `wants-partial?` extension lives in a separate fixture once the
;; Stage 2 Goblins-canonical wire profile lands.
(define (op-listen-promise-target)
  (record* 'op:listen
           (record* 'desc:answer 7)
           (record* 'desc:import-object 9)))

;; <op:listen <desc:export 5> <desc:import-object 9>>.
;;
;; Local-export listen target case per ADR-0007 § Decision 9 — the
;; listener fires immediately with the export as the `Fulfill`
;; argument when the receiver records the listen.
(define (op-listen-export-target)
  (record* 'op:listen
           (record* 'desc:export 5)
           (record* 'desc:import-object 9)))

;; <op:listen <desc:answer 7> <desc:import-object 9> #f>.
;;
;; V1_0 Goblins-canonical 3-operand `op:listen` with
;; `wants-partial? = #f` per ADR-0007 § Decision 4 / captp.rkt:86-88.
;; Spec-strict listener-fire behavior (fire once, on the
;; eventually-settled non-promise resolution).
(define (op-listen-v1-0-wants-partial-false)
  (record* 'op:listen
           (record* 'desc:answer 7)
           (record* 'desc:import-object 9)
           #f))

;; <op:listen <desc:answer 7> <desc:import-object 9> #t>.
;;
;; V1_0 Goblins-canonical 3-operand `op:listen` with
;; `wants-partial? = #t` — fire on each intermediate
;; `Fulfill(Promise(M))` step (Goblins core.rkt:1153-1199).
(define (op-listen-v1-0-wants-partial-true)
  (record* 'op:listen
           (record* 'desc:answer 7)
           (record* 'desc:import-object 9)
           #t))

;; <op:deliver <desc:export 7> [b"hello"] 42 <desc:import-object 99>>.
;;
;; V1_0 Goblins-canonical resolver-callback shape per
;; crates/core/pancake-model/src/argument.rs (ADR-0003) and
;; crates/codec/pancake-codec-syrup/src/lib.rs § "Versioned wire shapes":
;; the fourth `op:deliver` field carries the partner-installable
;; `<desc:import-object pos>` resolver descriptor (Goblins encodes
;; it via `marshall-local-refr!` in
;; reference/implementations/spritely-goblins/upstream/goblins/ocapn/captp.rkt).
;; A future `op:deliver` to that import carries the resolution
;; ('fulfill <ref>) or ('break <error>) — that callback `op:deliver`
;; is shape-identical to the existing `op_deliver.bin` fixture and is
;; not a separate vector.
(define (op-deliver-v1-0-with-resolve-me-desc)
  (record* 'op:deliver
           (record* 'desc:export 7)
           (list #"hello")
           42
           (record* 'desc:import-object 99)))

;; ── Stage 2 / ADR-0008 fixtures ────────────────────────────────────

;; <op:gc-exports [3 7] [1 2]> — Goblins-canonical op:gc-exports per
;; goblins/ocapn/captp.rkt:90-92: two parallel lists, the sender's
;; dropped position ids and the matching wire-deltas. Receiver
;; decrements export refcounts by the wire-delta per ADR-0008
;; § Wire-delta reference counting.
(define (op-gc-exports)
  (record* 'op:gc-exports (list 3 7) (list 1 2)))

;; <op:gc-answers [11 13]> — Goblins-canonical op:gc-answers per
;; goblins/ocapn/captp.rkt:94-96: a single list of answer-pos values
;; being released. No wire-delta — each answer-pos is single-reference
;; per ADR-0008 § Wire format: op:gc-answers.
(define (op-gc-answers)
  (record* 'op:gc-answers (list 11 13)))

;; <op:abort "VersionMismatch: peer requested 2.0">.
;;
;; Stage 2 / ADR-0008 typed-reason wire projection: pancake's
;; AbortReasonKind taxonomy emits the spec-strict single-string
;; op:abort with a "<KindName>: <message>" prefix on V1_0 syrup.
;; Goblins-canonical wire stays a single string; the typed-kind
;; round-trips on decode via AbortReason::parse_v1_0. Companion to
;; the existing op_abort.bin fixture (which exercises the prefix-
;; less Other kind).
(define (op-abort-typed)
  (record* 'op:abort "VersionMismatch: peer requested 2.0"))

;; <op:abort "ResourceExhausted: ImportTable cap hit">.
;;
;; Stage 4 / ADR-0025 typed-reason wire projection — same shape as
;; op-abort-typed but with the new ResourceExhausted kind that
;; ADR-0025 added (Stage 4 session table-cap hardening). Sibling
;; to the Python fixture; cross-impl byte parity on the typed
;; ResourceExhausted abort is the load-bearing check.
(define (op-abort-resource-exhausted)
  (record* 'op:abort "ResourceExhausted: ImportTable cap hit"))

;; <op:abort "CrossedHellos: byte-lower side closing">.
;;
;; ADR-0008 typed abort taxonomy. `CrossedHellos` is the abort kind
;; an adapter projects when it detects a concurrent inbound session
;; for the same partner; the no-I/O core carries the kind and its wire
;; projection but does not detect the condition.
(define (op-abort-crossed-hellos)
  (record* 'op:abort "CrossedHellos: byte-lower side closing"))

;; <op:abort "ConnectionLost: peer TCP RST">.
;;
;; ADR-0008 typed abort taxonomy. `ConnectionLost` is the abort kind
;; an adapter projects best-effort when its transport reports a lost
;; connection; partners observing this MAY retry.
(define (op-abort-connection-lost)
  (record* 'op:abort "ConnectionLost: peer TCP RST"))

;; <op:abort "GracefulShutdown: SIGTERM drain complete">.
;;
;; ADR-0008 typed abort taxonomy. `GracefulShutdown` is the abort kind
;; an adapter projects on a drain-to-completion shutdown; partners
;; SHOULD NOT retry. Distinct from `ConnectionLost` (retryable) and
;; `NormalShutdown` (no drain semantics).
(define (op-abort-graceful-shutdown)
  (record* 'op:abort "GracefulShutdown: SIGTERM drain complete"))

;; ── ADR-0021 widened-Argument fixtures ──────────────────
;;
;; `op:deliver to=<desc:export 7> args=[<arg>] answer-pos=42 #f`
;; shape for each new `Argument` variant ADR-0021 added. Mirrors the
;; sibling Python builders; pin direction is "both reference encoders
;; agree, pancake must match." A regression on a specific variant's
;; wire shape surfaces against its dedicated fixture.

(define (op-deliver-one-arg arg)
  (record* 'op:deliver
           (record* 'desc:export 7)
           (list arg)
           42
           #f))

;; <'void> — Goblins's (void) value per ADR-0021.
(define (op-deliver-arg-void)
  (op-deliver-one-arg (record* 'void)))

;; D<8 bytes BE IEEE 754> — Racket double 1.5 per ADR-0021.
(define (op-deliver-arg-float64)
  (op-deliver-one-arg 1.5))

;; <'user-record 'point (1 2)> — Goblins's user-record catch-all per
;; ADR-0021. Tagged.value is a Vec<Argument> so the model cell
;; matches the wire's record-args list verbatim; the 2-element
;; value list exercises the multi-arg shape.
(define (op-deliver-arg-tagged)
  (op-deliver-one-arg (record* 'user-record 'point (list 1 2))))

;; <'kw 'name> — Goblins keyword arg per ADR-0021.
(define (op-deliver-arg-keyword)
  (op-deliver-one-arg (record* 'kw 'name)))

;; #1 2 3 $ — Goblins (set 1 2 3) per ADR-0021. The Racket `set`
;; serializer canonical-sorts on emit (matching pancake's encoder).
(define (op-deliver-arg-set)
  (op-deliver-one-arg (set 1 2 3)))

;; ── Stage 2 / ADR-0009 handoff envelope fixtures ───────────────────

;; Encode an Ed25519 public key as the OCapN-canonical gcrypt
;; s-expression `['public-key ['ecc ['curve 'Ed25519] ['flags 'eddsa]
;; ['q q_value]]]` per the CapTP spec § Public Key. In Syrup the
;; s-expression renders as nested lists of symbols / a 32-byte
;; ByteArray for q_value.
(define (peer-key-sexp q-value)
  (list 'public-key
        (list 'ecc
              (list 'curve 'Ed25519)
              (list 'flags 'eddsa)
              (list 'q q-value))))

;; Encode a 64-byte Ed25519 signature as
;; `['sig-val ['eddsa ['r r_value] ['s s_value]]]` (RFC 8032 r||s).
(define (signature-sexp sig-64)
  (list 'sig-val
        (list 'eddsa
              (list 'r (subbytes sig-64 0 32))
              (list 's (subbytes sig-64 32 64)))))

;; <ocapn-peer transport designator hints> matching pancake's
;; `locator_to_syrup` output for empty hints. Empty hints emit an
;; empty hash table (matching the OCapN Python conformance suite and
;; pancake's own encoder); a prior revision used `#f` and diverged
;; from upstream, breaking `op:start-session` signature verification.
(define (ocapn-peer-no-hints transport designator)
  (record* 'ocapn-peer (string->symbol transport) designator (hash)))

(define (handoff-give-record)
  (record* 'desc:handoff-give
           (peer-key-sexp (make-bytes 32 #x42))
           (ocapn-peer-no-hints "memory" "exporter")
           (make-bytes 32 #xCC)   ; gifter-exporter session id
           (make-bytes 32 #x11)   ; gifter-side public identifier
           (make-bytes 32 #x01))) ; gift-id

;; <desc:sig-envelope <desc:handoff-give …> <sig-val …>>.
(define (op-handoff-give)
  (record* 'desc:sig-envelope
           (handoff-give-record)
           (signature-sexp (make-bytes 64 #xAA))))

;; <desc:sig-envelope <desc:handoff-receive receiving-session
;; receiving-side handoff-count <signed-give>> <sig-val …>>.
;;
;; The inner signed-give slot nests the same desc:sig-envelope
;; wrapping the 5-field desc:handoff-give certificate as the
;; op_handoff_give fixture above, but with a Gifter-signature
;; byte pattern of #xAA. The outer (Receiver) signature pattern
;; is #xBB.
(define (op-handoff-receive)
  (define nested-signed-give
    (record* 'desc:sig-envelope
             (handoff-give-record)
             (signature-sexp (make-bytes 64 #xAA))))
  (define inner-receive
    (record* 'desc:handoff-receive
             (make-bytes 32 #xDD)        ; receiving-session
             (make-bytes 32 #x22)        ; receiving-side
             1                            ; handoff-count
             nested-signed-give))
  (record* 'desc:sig-envelope
           inner-receive
           (signature-sexp (make-bytes 64 #xBB))))

;; <op:deliver <desc:export 0>
;;             [<symbol withdraw-gift>
;;              <desc:sig-envelope <desc:handoff-receive …>
;;                                 <sig-val …>>]
;;             99
;;             #f>.
;;
;; Stage 2 / ADR-0009 § Receiver side step 8 wire shape: the
;; Receiver invokes `withdraw-gift` on the Exporter's bootstrap
;; object (<desc:export 0>) carrying a desc:sig-envelope-wrapped
;; desc:handoff-receive certificate as the second op:deliver arg.
;; The argument is pancake's `Argument::Handoff` variant; on the
;; wire it is the spec-canonical envelope itself (no extra
;; wrapper). Inner field bytes match `op-handoff-receive` so a
;; single parity assertion covers both shapes' cross-impl bytes;
;; only the outer op:deliver envelope differs.
(define (op-deliver-withdraw-gift)
  (define nested-signed-give
    (record* 'desc:sig-envelope
             (handoff-give-record)
             (signature-sexp (make-bytes 64 #xAA))))
  (define inner-receive
    (record* 'desc:handoff-receive
             (make-bytes 32 #xDD)
             (make-bytes 32 #x22)
             1
             nested-signed-give))
  (define signed-receive
    (record* 'desc:sig-envelope
             inner-receive
             (signature-sexp (make-bytes 64 #xBB))))
  (define target (record* 'desc:export 0))
  (define args (list 'withdraw-gift signed-receive))
  (record* 'op:deliver target args 99 #f))

;; ── ADR-0011 / op:get + op:index fixtures ─────────────────────────
;;
;; Goblins's `(define-recordable-struct op:get (receiver-desc
;; field-name new-answer-pos))` and the parallel `op:index` at
;; `goblins/ocapn/captp.rkt:98-104`. Field-projection / list-index
;; carrying a fresh answer-pos for the result promise; pancake's
;; encoder produces the spec-canonical 3-operand shape.

;; <op:get <desc:export 7> 'name 11+>.
;;
;; receiver = sender's `Reference::Far(import_id=7)` → wire
;; `<desc:export 7>` (target-position perspective flip per
;; ADR-0010 § Decision 3). `field-name` is a Syrup symbol per
;; ADR-0011 § Decision 1 (the field name itself, not a string).
;; `new-answer-pos` is the result-promise answer id the sender
;; just allocated.
(define (op-get)
  (record* 'op:get
           (record* 'desc:export 7)
           'name
           11))

;; <op:index <desc:export 7> 5+ 11+>.
;;
;; receiver = sender's `Reference::Far(import_id=7)` → wire
;; `<desc:export 7>`. `index` is a Syrup positive integer per
;; ADR-0011 § Decision 1 (model field is `i64` with `0` admitted);
;; `new-answer-pos` is the result-promise answer id.
(define (op-index)
  (record* 'op:index
           (record* 'desc:export 7)
           5
           11))

;; ── ADR-0006 / op:start-session handshake fixture ──────────────────
;;
;; Goblins's `(define-recordable-struct op:start-session
;; (captp-version handoff-pubkey acceptable-location
;; acceptable-location-sig))` at `goblins/ocapn/captp.rkt:185-191`.
;; Four-field record carrying the V1_0 wire version string, the
;; per-session Ed25519 verifying key as a gcrypt s-expression
;; (`['public-key ['ecc ['curve 'Ed25519] ['flags 'eddsa] ['q q]]]`),
;; the locator the receiver would dial to reach this peer, and the
;; signature over `<my-location $acceptable-location>` as a gcrypt
;; sig-val s-expression. Pancake's `Message::StartSession` emits the
;; same shape via `peer_key_to_syrup` / `locator_to_syrup` /
;; `signature_to_syrup` — fixture confirms cross-impl byte parity.
;;
;; Per ADR-0015 the signature domain is the *wrapped* `<my-location
;; $loc>` Syrup-canonical bytes (Goblins's verification path at
;; `captp.rkt:1454-1457`). The signature byte pattern below
;; (`#xCC`) is a fixture placeholder — real handshake bytes are
;; generated by `pancake-session::handshake`'s per-session Ed25519
;; signer.
(define (op-start-session-v1-0)
  (record* 'op:start-session
           "1.0"
           (peer-key-sexp (make-bytes 32 #xAA))
           (ocapn-peer-no-hints "memory" "exporter")
           (signature-sexp (make-bytes 64 #xCC))))

;; ── primitive Syrup fixtures (E3) ──────────────────────────────────
;;
;; Primitive-level coverage so the byte-shape verification doesn't
;; stop at the OCapN record layer. Each builder returns a Racket
;; value the upstream `syrup-encode` accepts directly. Mirrors the
;; sibling Python generator at reference/tests/syrup-byte-fixtures/.

(define (prim-string-hello) "hello")
(define (prim-integer-pos-42) 42)
(define (prim-integer-neg-7) -7)
(define (prim-list-of-ints) (list 1 2 3))
(define (prim-set-of-ints) (set 1 2 3))
(define (prim-dict-str-to-int) (hash "a" 1 "b" 2))

;; Filename → record builder. Filenames match the wire-vector test
;; names in crates/codec/pancake-codec-syrup/src/wire_vectors.rs (CapTP-record
;; fixtures) and crates/codec/pancake-codec-syrup/tests/primitive_fixtures.rs
;; (primitive fixtures, prefixed `prim_`) and the Python scenario at
;; reference/tests/syrup-byte-fixtures/.
(define FIXTURES
  (list (cons "op_abort.bin"                                   op-abort-shutting-down)
        (cons "op_abort_typed.bin"                             op-abort-typed)
        (cons "op_deliver.bin"                                 op-deliver-minimal)
        (cons "op_resolve_break.bin"                           op-resolve-break)
        (cons "op_resolve_fulfill_far.bin"                     op-resolve-fulfill-far)
        (cons "op_resolve_fulfill_near.bin"                    op-resolve-fulfill-near)
        (cons "op_resolve_fulfill_promise.bin"                 op-resolve-fulfill-promise)
        (cons "op_listen_promise_target.bin"                   op-listen-promise-target)
        (cons "op_listen_export_target.bin"                    op-listen-export-target)
        (cons "op_listen_v1_0_wants_partial_false.bin"         op-listen-v1-0-wants-partial-false)
        (cons "op_listen_v1_0_wants_partial_true.bin"          op-listen-v1-0-wants-partial-true)
        (cons "op_deliver_v1_0_with_resolve_me_desc.bin"       op-deliver-v1-0-with-resolve-me-desc)
        (cons "op_gc_exports.bin"                              op-gc-exports)
        (cons "op_gc_answers.bin"                              op-gc-answers)
        (cons "op_handoff_give.bin"                            op-handoff-give)
        (cons "op_handoff_receive.bin"                         op-handoff-receive)
        (cons "op_deliver_withdraw_gift.bin"                   op-deliver-withdraw-gift)
        ;; ADR-0025 typed-abort wire kind
        (cons "op_abort_resource_exhausted.bin"                op-abort-resource-exhausted)
        ;; ADR-0008 adapter-projected typed-abort wire kinds
        (cons "op_abort_crossed_hellos.bin"                    op-abort-crossed-hellos)
        (cons "op_abort_connection_lost.bin"                   op-abort-connection-lost)
        (cons "op_abort_graceful_shutdown.bin"                 op-abort-graceful-shutdown)
        ;; ADR-0021 widened `Argument` arms (op:deliver one-arg shape)
        (cons "op_deliver_arg_void.bin"                        op-deliver-arg-void)
        (cons "op_deliver_arg_float64.bin"                     op-deliver-arg-float64)
        (cons "op_deliver_arg_tagged.bin"                      op-deliver-arg-tagged)
        (cons "op_deliver_arg_keyword.bin"                     op-deliver-arg-keyword)
        (cons "op_deliver_arg_set.bin"                         op-deliver-arg-set)
        ;; ADR-0011 op:get / op:index field-projection ops
        (cons "op_get.bin"                                     op-get)
        (cons "op_index.bin"                                   op-index)
        ;; ADR-0006 / ADR-0015 op:start-session handshake (V1_0)
        (cons "op_start_session_v1_0.bin"                      op-start-session-v1-0)
        (cons "prim_string_hello.bin"                          prim-string-hello)
        (cons "prim_integer_pos_42.bin"                        prim-integer-pos-42)
        (cons "prim_integer_neg_7.bin"                         prim-integer-neg-7)
        (cons "prim_list_of_ints.bin"                          prim-list-of-ints)
        (cons "prim_set_of_ints.bin"                           prim-set-of-ints)
        (cons "prim_dict_str_to_int.bin"                       prim-dict-str-to-int)))

(define (write-fixture out-dir name builder)
  (define bytes-out (syrup-encode (builder)))
  (define path (build-path out-dir name))
  (with-output-to-file path
    #:exists 'replace
    (lambda () (write-bytes bytes-out)))
  (printf "  wrote ~a (~a bytes)~n" name (bytes-length bytes-out)))

(define (main out-dir)
  (make-directory* out-dir)
  (for ([entry (in-list FIXTURES)])
    (write-fixture out-dir (car entry) (cdr entry))))

(command-line
 #:program "generate.rkt"
 #:args (out-dir)
 (main out-dir))
