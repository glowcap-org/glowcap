#lang racket/base
;; Internal: the transport seam the companion modules build on.
;;
;; The binding-internal surface `glowcap-tcp.rkt`, `glowcap-inproc.rkt`, and
;; `glowcap-iroh.rkt` reach the shared core machinery through, mirroring the
;; à-la-carte archive split (ADR-0059). It re-provides the `seam` submodule of
;; `glowcap.rkt`: the typed-error raisers (`check`, `check-with`,
;; `raise-glowcap`), the pin/copy helpers (`pin-immobile`, `bytes<-c`),
;; `codec-id`, the session-construction seam (`async-transport`,
;; `establish-dialed-locator-session`,
;; `establish-accepted-session`, `accept-next-session`,
;; `make-fresh-host`, `make-host`,
;; `host-set-advertised-locator!`), the handshake
;; bound both halves default to (`HANDSHAKE-TIMEOUT-MS`), and the shared frame
;; cstructs with their managed-frame release. Not a public API: `glowcap.rkt`'s
;; public provide never exports these, and an application reaches a transport
;; through its companion module's own surface.
(require (submod "../glowcap.rkt" seam))
(provide (all-from-out (submod "../glowcap.rkt" seam)))
