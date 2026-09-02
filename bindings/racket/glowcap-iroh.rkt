#lang racket/base
;; glowcap-iroh — the iroh transport companion for the glowcap Racket binding.
;;
;; Mirrors the à-la-carte archive split (ADR-0059): `glowcap.rkt` is the core
;; (libglowcap_ocapn), and each transport is its own composable module —
;; `glowcap-tcp.rkt`, `glowcap-inproc.rkt`, and this one. This module is
;; libglowcap_net_transport_iroh's binding, the optional encrypted-QUIC netlayer.
;; Its private loader (`private/ffi-iroh.rkt`) opens ONLY the iroh companion
;; (`zig build iroh-abi`, needs cargo) — which exports only `glowcap_iroh_*` —
;; and builds an `async-transport` over it through the transport seam
;; (`private/seam.rkt`); the core calls come from there. Everything above the
;; pump — vat, session-* verbs, events — is the core's; only the transport differs.
;;
;; `iroh-provider` and `iroh-connector` compose iroh into a Runtime explicitly,
;; so a TCP-only program never needs the iroh library. Hosting (`listen-iroh` and
;; the `iroh-server-*` surface) is reached through this module directly.
;;
;; Below that sits the raw byte surface: an `iroh-endpoint` accepts and dials
;; connections with no CapTP over them, and a `byte-channel` moves their bytes.
;; The native iroh server owns CapTP admission through the driver, while a
;; consumer with a protocol of its own — a byte-transparent relay, or a
;; netlayer written for a foreign CapTP — takes the raw endpoint alone.
;;
;; This file is the application surface and nothing else. `private/iroh.rkt` is
;; the stable facade; its `iroh/runtime.rkt` and `iroh/surface.rkt` subjects own
;; the native resident/raw endpoint and application composition respectively.
(require "private/iroh.rkt")

(provide iroh-locator iroh-provider iroh-connector listen-iroh
         make-iroh-config (struct-out iroh-config)
         IROH-REACH-DIRECT IROH-REACH-DISCOVERY IROH-REACH-DISCOVERY-NO-RELAY IROH-REACH-LOCAL-DISCOVERY
         iroh-server-locator iroh-server-uri iroh-server-node-id iroh-server-direct-addresses
         iroh-server-host iroh-server-accept iroh-server-close!
         dial-locator-for-relay
         ;; The raw byte-channel surface: an iroh connection with no CapTP over
         ;; it, for a consumer that runs its own protocol on the bytes. A
         ;; byte-transparent relay dials one; a netlayer written for a foreign
         ;; CapTP both dials and accepts.
         open-iroh-endpoint
         iroh-endpoint-node-id iroh-endpoint-direct-addresses
         iroh-endpoint-accept iroh-endpoint-dial iroh-endpoint-close!
         (struct-out failure-event) take-runtime-failures!
         (struct-out byte-channel))
