#lang racket/base
;; pancake-iroh — the iroh transport companion for the pancake Racket binding.
;;
;; Mirrors the à-la-carte archive split (ADR-0059): `pancake.rkt` is the core
;; (libpancake_ocapn), and each transport is its own composable module —
;; `pancake-tcp.rkt`, `pancake-inproc.rkt`, and this one. This module is
;; libpancake_net_transport_iroh's binding, the optional encrypted-QUIC netlayer.
;; Its private loader (`private/ffi-iroh.rkt`) opens ONLY the iroh companion
;; (`zig build iroh-abi`, needs cargo) — which exports only `pancake_iroh_*` —
;; and builds an `async-transport` over it through the transport seam
;; (`private/seam.rkt`); the core calls come from there. Everything above the
;; pump — vat, session-* verbs, events — is the core's; only the transport differs.
;;
;; `connect` in the core dials an iroh locator by loading this transport lazily,
;; so a TCP-only program never needs the iroh library. Hosting (`listen-iroh` and
;; the `iroh-server-*` surface) is reached through this module directly.
;;
;; Below that sits the raw byte surface: an `iroh-endpoint` accepts and dials
;; connections with no CapTP over them, and a `byte-channel` moves their bytes.
;; The keyed server is that endpoint plus a CapTP host, and a consumer with a
;; protocol of its own — a byte-transparent relay, or a netlayer written for a
;; foreign CapTP — takes the endpoint alone.
;;
;; This file is the application surface and nothing else. The implementation is
;; `private/iroh.rkt`, which also holds the binding-internal `connect-iroh/node`
;; that the core's dial reaches. Keeping that function in the private tree, and
;; out of the list below, is what makes it binding-internal; it is not a
;; submodule, because Racket's compile manager does not manage submodule
;; requests and a program running against compiled bytecode could not reach one
;; without re-expanding the whole module.
(require "private/iroh.rkt")

(provide listen-iroh
         make-iroh-config (struct-out iroh-config)
         IROH-REACH-DIRECT IROH-REACH-DISCOVERY IROH-REACH-DISCOVERY-NO-RELAY IROH-REACH-LOCAL-DISCOVERY
         iroh-server-node-id iroh-server-direct-addresses
         iroh-server-host iroh-server-accept iroh-server-close!
         dial-locator-for-relay
         ;; The raw byte-channel surface: an iroh connection with no CapTP over
         ;; it, for a consumer that runs its own protocol on the bytes. A
         ;; byte-transparent relay dials one; a netlayer written for a foreign
         ;; CapTP both dials and accepts.
         open-iroh-endpoint
         iroh-endpoint-node-id iroh-endpoint-direct-addresses
         iroh-endpoint-accept iroh-endpoint-dial iroh-endpoint-close!
         (struct-out byte-channel))
