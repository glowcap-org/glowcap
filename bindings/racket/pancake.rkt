#lang racket/base
;; Idiomatic Racket API for pancake, an OCapN/CapTP node you drive.
;;
;; The raw `ffi/unsafe` layer lives in the internal `private/` loaders; this
;; module is just the public surface over it, and that surface is one tier:
;; the `connection` — one object over the byte-fed host archive
;; (libpancake_driver, ADR-0072) that bundles a vat, a pump, and the node's
;; routing/redeem authority, constructed by `connect`/`listen`/`accept`.
;; Everything three-party — gift origination, transparent redemption,
;; cross-connection routing — happens inside the library; the binding moves
;; bytes and answers the host's action queue. The raw `pancake_peer_*` family
;; has no Racket wrapper: it stays a C-consumer surface, covered by the Zig
;; C-ABI tests and the C examples.
(require "private/ffi-ocapn.rkt"
         "private/errors.rkt"
         "private/value.rkt"
         "private/codec.rkt"
         "private/vat.rkt"
         "private/locator.rkt"
         "private/connection.rkt")

(provide (struct-out near-ref) (struct-out far-ref) (struct-out promise-ref)
         (struct-out sturdy) (struct-out broken) (struct-out sym)
         (struct-out kw) (struct-out pset) (struct-out tagged-arg)
         near far
         (struct-out abort-info)
         abi-version last-error
         exn:fail:pancake? exn:fail:pancake-code exn:fail:pancake-abort
         (struct-out async-connection)
         conn-flush!)

(provide methods
         (struct-out actor-ref) (struct-out local-vow)
         current-vat make-vat with-vat vat-run
         vat-snapshot vat-restore!
         spawn $ <- <-np on
         drive break-far-vows!)

;; ── Connection: the application surface ──────────────────────────────────────
;; One object an application holds. It bundles the pump, a vat, and the node's
;; host, so a consumer never wires them by hand. `connect`/`listen`/`accept`
;; construct a connection; the operations on one are `conn-` prefixed
;; (`conn-fetch`/`conn-publish`/`conn-spawn`/`conn-send`/`conn-tell`/`conn-serve`),
;; since Racket has no method-receiver syntax to carry the verb. `connection-close!`
;; keeps the full prefix so the application-surface close reads distinctly from
;; the netlayer's `endpoint-release!`. The Goblins verbs (`spawn`, `$`, `<-`, `on`, `bcom`, `methods`)
;; are unchanged, you use them through the connection's vat.
(provide (struct-out connection)
         connect listen accept server-port server-close! server-node
         node-publish-giftable
         tcp-locator parse-locator format-peer-uri (struct-out locator)
         encode-peer-locator conn-set-exporter-locator!
         node-redeem-reachability-value set-node-redeem-reachability!
         conn-vat conn-async conn-spawn conn-publish
         conn-fetch conn-enliven conn-send conn-send-promise conn-await
         conn-index conn-untag conn-serve conn-tell connection-close!
         conn-with-gc! conn-caretaker conn-attenuate conn-revoke!)

;; ── Transport seam ───────────────────────────────────────────────────────────
;; The binding-internal surface every transport companion builds on, mirroring
;; the à-la-carte archive split (ADR-0059). It lives in a `seam` submodule that
;; only `private/seam.rkt` re-provides, so `check`, the raw cstructs, and the
;; managed-frame release never ride this module's public provide: an application
;; reaches a transport through its companion module's own surface, and the raw
;; FFI stays private to the binding. The companion that drives a live session
;; (iroh) constructs an `async-transport` over its own FFI and hands it to
;; `establish-dialed-connection` / `establish-accepted-connection`, which mint
;; the host connection, drive the keyed handshake byte-fed, and return a ready
;; `connection`. The explicit netlayer companions (tcp, inproc) reuse
;; `check-with` to raise the same typed `exn:fail:pancake` from their own
;; last-error reader, `pin-immobile` to pin borrowed byte inputs, and
;; `codec-id` to spell a codec symbol. The cstruct and managed-frame release
;; bindings are the shared frame ABI all the archives speak by layout.
(module* seam #f
  (provide (struct-out async-transport) make-fresh-node
           establish-dialed-connection establish-accepted-connection
           node-set-self-designator! format-peer-uri
           check check-with read-last-error raise-pancake bytes<-c codec-id
           pin-immobile
           _PancakeFrame _PancakeFrame-pointer make-PancakeFrame
           _PancakeManagedFrame _PancakeManagedFrame-pointer make-PancakeManagedFrame
           PancakeManagedFrame-bytes PancakeManagedFrame-len
           pancake_managed_frame_release))
