#lang racket/base
;; Idiomatic Racket API for pancake, an OCapN/CapTP host you drive.
;;
;; The raw `ffi/unsafe` layer lives in the internal `private/` loaders; this
;; module is just the public surface over it, and that surface is one tier:
;; the `session` — one CapTP partner over the byte-fed host archive
;; (libpancake_driver, ADR-0072 / ADR-0079) that bundles a vat, a pump, and the
;; host's routing/redeem authority, constructed by `connect`/`listen`/`accept`.
;; The host owns an `engine.Node` (sans-io router); Goblins `mycapn` is two
;; roles — endpoint ≈ host, router tables ≈ `engine.Node`. Everything
;; three-party — gift origination, transparent redemption, cross-session
;; routing — happens inside the library; the binding moves bytes and answers
;; the host's action queue. The raw `pancake_peer_*` family has no Racket
;; wrapper: it stays a C-consumer surface, covered by the Zig C-ABI tests and
;; the C examples.
(require "private/ffi-ocapn.rkt"
         "private/errors.rkt"
         "private/value.rkt"
         "private/codec.rkt"
         "private/vat.rkt"
         "private/locator.rkt"
         "private/async.rkt"
         "private/host.rkt"
         "private/promise.rkt"
         "private/gc.rkt"
         "private/session.rkt"
         "private/dial.rkt"
         "private/listen.rkt"
         "private/constants.rkt")

(provide (struct-out near-ref) (struct-out far-ref) (struct-out promise-ref)
         (struct-out sturdy) (struct-out broken) (struct-out sym)
         (struct-out kw) (struct-out pset) (struct-out tagged-arg)
         near far
         (struct-out abort-info)
         abi-version last-error
         exn:fail:pancake? exn:fail:pancake-code exn:fail:pancake-abort
         session-flush!)

(provide methods
         (struct-out actor-ref) (struct-out local-vow)
         current-vat make-vat with-vat vat-run
         vat-snapshot vat-restore!
         spawn $ <- <-np on
         drive break-far-vows!)

;; ── Session: the CapTP partner application surface ───────────────────────────
;; One object an application holds. It bundles the pump, a vat, and the host,
;; so a consumer never wires them by hand. `connect`/`listen`/`accept`
;; construct a session; the operations on one are `session-` prefixed
;; (`session-fetch`/`session-publish`/`session-spawn`/`session-send`/`session-tell`/`session-serve`),
;; since Racket has no method-receiver syntax to carry the verb. `session-close!`
;; keeps the full prefix so the application-surface close reads distinctly from
;; the netlayer's `endpoint-release!`. The Goblins verbs (`spawn`, `$`, `<-`, `on`, `bcom`, `methods`)
;; are unchanged, you use them through the session's vat.
(provide (struct-out session)
         (struct-out server)
         connect listen accept server-port server-close! server-host
         listen-keyed-tcp keyed-tcp-server-port keyed-tcp-server-uri
         keyed-tcp-server-accept keyed-tcp-server-close!
         keyed-tcp-server-host keyed-tcp-server-designator
         (struct-out keyed-tcp-server)
         make-host make-fresh-host
         host-publish-giftable
         tcp-locator keyed-tcp-locator parse-locator format-peer-uri (struct-out locator)
         encode-peer-locator designator-host-port socket-addr-designator session-set-exporter-locator!
         host-redeem-reachability-value set-host-redeem-reachability!
         designator-from-seed
         session-vat session-async session-host session-spawn session-publish
         session-fetch session-enliven session-send session-send-promise session-await
         session-index session-untag session-serve session-tell session-close!
         session-with-gc! session-caretaker session-attenuate session-revoke!
         TRANSPORT-TCP TRANSPORT-KEYED-TCP TRANSPORT-INPROC TRANSPORT-IROH
         HINT-DIRECT-ADDRESSES)

;; ── Transport seam ───────────────────────────────────────────────────────────
;; The binding-internal surface every transport companion builds on, mirroring
;; the à-la-carte archive split (ADR-0059). It lives in a `seam` submodule that
;; only `private/seam.rkt` re-provides, so `check`, the raw cstructs, and the
;; managed-frame release never ride this module's public provide: an application
;; reaches a transport through its companion module's own surface, and the raw
;; FFI stays private to the binding. The companion that drives a live session
;; (iroh) constructs an `async-transport` over its own FFI and hands it to
;; `establish-dialed-locator-session` / `establish-accepted-session`, which mint
;; the host session, drive the keyed handshake byte-fed, and return a ready
;; `session`. The explicit netlayer companions (tcp, inproc) reuse
;; `check-with` to raise the same typed `exn:fail:pancake` from their own
;; last-error reader, `pin-immobile` to pin borrowed byte inputs, and
;; `codec-id` to spell a codec symbol. The cstruct and managed-frame release
;; bindings are the shared frame ABI all the archives speak by layout.
(module* seam #f
  (provide (struct-out async-transport) make-fresh-host make-host
           establish-dialed-locator-session
           establish-accepted-session
           host-set-self-designator! host-set-session-limits! format-peer-uri
           check check-with read-last-error raise-pancake bytes<-c codec-id
           pin-immobile
           _PancakeFrame _PancakeFrame-pointer make-PancakeFrame
           _PancakeManagedFrame _PancakeManagedFrame-pointer make-PancakeManagedFrame
           PancakeManagedFrame-bytes PancakeManagedFrame-len
           pancake_managed_frame_release))
