#lang racket/base
;; Idiomatic Racket API for glowcap, an OCapN/CapTP host you drive.
;;
;; The raw `ffi/unsafe` layer lives in the internal `private/` loaders; this
;; module is just the public surface over it, and that surface is one tier:
;; the `session` — one CapTP partner over the byte-fed host archive
;; (libglowcap_host, ADR-0072 / ADR-0079) that bundles an adapter-local Racket
;; vat, a pump, and the shared Host's routing/redeem authority, constructed by
;; `connect`/`listen`/`accept`.
;; The host owns an `engine.Node` (sans-io router); Goblins `mycapn` is two
;; roles — product maps to Host, router tables map to `engine.Node`. Everything
;; three-party — gift origination, transparent redemption, cross-session
;; routing — happens inside the library; the binding moves bytes and answers
;; the host's action queue. `GlowcapHost` is the sole C CapTP application
;; surface; the native Zig engine peer is not mirrored into the ABI.
(require "private/ffi-ocapn.rkt"
         "private/errors.rkt"
         "private/value.rkt"
         "private/abi-value.rkt"
         "private/vat.rkt"
         "private/locator.rkt"
         "private/async.rkt"
         "private/host.rkt"
         "private/host/state.rkt"
         "private/promise.rkt"
         "private/gc.rkt"
         "private/session.rkt"
         "private/session/state.rkt"
         "private/session/identity.rkt"
         "private/session/profile.rkt"
         "private/session/establish.rkt"
         "private/session/close.rkt"
         "private/trace.rkt"
         "private/finalizer-diagnostics.rkt"
         "private/dial.rkt"
         "private/constants.rkt"
         "private/carrier-failure.rkt"
         "private/transport.rkt")

(provide ref? ref-id ref-released? (struct-out sym)
         (struct-out driver-provider) (struct-out byte-connector)
         make-driver-provider make-byte-connector
         (struct-out kw) (struct-out error-arg) (struct-out pset) (struct-out tagged-arg) (struct-out struct-arg)
         (struct-out abort-info)
         (struct-out partner-identity)
         (struct-out settled-profile)
         abi-version last-error
         exn:fail:glowcap? exn:fail:glowcap-code exn:fail:glowcap-abort
         exn:fail:glowcap-carrier-failure (struct-out carrier-failure)
         session-flush!)

(provide methods
         (struct-out actor-ref) (struct-out local-vow)
         current-vat make-vat with-vat vat-run
         vat-snapshot vat-restore!
         spawn $ <- <-np on
         drive break-far-vows!)

;; ── Session: the CapTP partner application surface ───────────────────────────
;; One object an application holds. It bundles the pump, an adapter-local Racket
;; vat, and the shared native Host, so a consumer never wires them by hand. The
;; native Host owns the callback actors and their cross-Port lifetime; the
;; Racket vat supplies the language's local actor verbs. `connect`/`listen`/`accept`
;; construct a session; the operations on one are `session-` prefixed
;; (`session-fetch`/`session-publish`/`session-spawn`/`session-send`/`session-tell`/`session-serve`),
;; since Racket has no method-receiver syntax to carry the verb. `session-close!`
;; keeps the full prefix so the application-surface close reads distinctly from
;; the netlayer's `connection-release!`. The Goblins verbs (`spawn`, `$`, `<-`, `on`, `bcom`, `methods`)
;; are unchanged, you use them through the session's vat.
(provide open-runtime runtime? runtime-host runtime-connect runtime-close!
         HANDSHAKE-TIMEOUT-MS
         make-host make-fresh-host
         host-publish-giftable
         host-unpublish-giftable
         host-publish-durable
         host-remove-durable
         host-defer-turn resolver?
         resolver-fulfill! resolver-break!
         host-enliven
         host-fetch-at
         (struct-out failure-event) host-take-failures! take-runtime-failures!
         enable-trace!
         parse-locator parse-sturdyref format-locator-uri format-peer-uri format-sturdyref
         (struct-out locator) (struct-out sturdyref)
         encode-peer-locator designator-host-port session-set-exporter-locator!
         host-redeem-reachability-value set-host-redeem-reachability!
         designator-from-seed
         session-partner-identity partner-identity-durable-authenticated?
         session-profile session-transport-name
         session-bind-verified-channel-key!
         session-vat session-async session-host session-spawn session-publish session-published-ref
         session-fetch session-enliven session-send session-listen session-send-redeeming
         session-send-promise session-await
         session-index session-untag session-get session-serve session-tell session-close!
         session-annotate!
         session-with-gc! session-release! session-caretaker session-attenuate session-revoke!
         ;; Closing a session closes that connection; this is the Host-wide
         ;; close barrier over every session the host holds, including the ones
         ;; it dialed to redeem handoffs, and it releases the handle last.
         host-close!
         TRANSPORT-TCP TRANSPORT-ONION TRANSPORT-ID TRANSPORT-KEYED-TCP TRANSPORT-NOISE-TCP
         TRANSPORT-INPROC TRANSPORT-IROH TRANSPORT-KEYED-RELAY TRANSPORT-WEBRTC TRANSPORT-NOISE-RELAY
         HINT-ALT-LOCATORS
         HINT-DIRECT-ADDRESSES
         HINT-VIA)

(provide FEATURE-MINIMUM FEATURE-BASELINE FEATURE-PIPELINING FEATURE-HANDOFF
         FEATURE-WIRE-DELTA FEATURE-STURDYREF FEATURE-UNTAG
         FEATURE-MULTI-LOCATION FEATURE-FULL)

;; ── Transport seam ───────────────────────────────────────────────────────────
;; The binding-internal surface every transport companion builds on, mirroring
;; the à-la-carte archive split (ADR-0059). It lives in a `seam` submodule that
;; only `private/seam.rkt` re-provides, so `check`, the raw cstructs, and the
;; managed-frame release never ride this module's public provide: an application
;; reaches a transport through its companion module's own surface, and the raw
;; FFI stays private to the binding. The companion that drives a live session
;; (iroh) constructs an `async-transport` over its own FFI and hands it to
;; `establish-dialed-locator-session` / `accept-next-session`, which mint
;; the host session, drive the keyed handshake byte-fed, and return a ready
;; `session`; both bound that handshake at `HANDSHAKE-TIMEOUT-MS` unless the
;; companion hands them its own budget. A hosting companion goes through
;; `accept-next-session` so it inherits the one accept rule (bounded handshake,
;; skip a bad partner) rather than calling `establish-accepted-session` itself.
;; The explicit netlayer companions (tcp, inproc) reuse
;; `check-with` to raise the same typed `exn:fail:glowcap` from their own
;; last-error reader, `pin-immobile` to pin borrowed byte inputs, and
;; `codec-id` to spell a codec symbol. The cstruct and managed-frame release
;; bindings are the shared frame ABI all the archives speak by layout.
(module* seam #f
  (provide (struct-out async-transport) make-fresh-host make-host
           establish-dialed-locator-session
           establish-accepted-session accept-next-session HANDSHAKE-TIMEOUT-MS
           host-set-advertised-locator!
           host-set-session-limits! format-peer-uri
           check check-with read-last-error raise-glowcap
           retain-cleanup-failure raise-retained-failures bytes<-c codec-id
           pin-immobile
           _GlowcapFrame _GlowcapFrame-pointer make-GlowcapFrame
           _GlowcapManagedFrame _GlowcapManagedFrame-pointer make-GlowcapManagedFrame
           GlowcapManagedFrame-bytes GlowcapManagedFrame-len
           glowcap_managed_frame_release))
