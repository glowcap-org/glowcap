#lang racket/base
;; glowcap-webrtc: the WebRTC transport companion for the glowcap Racket binding.
;;
;; `glowcap.rkt` is the core (libglowcap_ocapn) and each transport is a
;; composable module. This one is libglowcap_net_transport_webrtc's binding.
;; Its private loader (`private/ffi-webrtc.rkt`) opens the library only when a
;; WebRTC netlayer is first built (`zig build webrtc-abi`, needs cargo), so a
;; program that never dials a `webrtc` locator never opens it.
;;
;; A WebRTC dial or accept is one signaling exchange the application carries
;; itself. `make-webrtc-signaling` takes four procedures, and each takes the
;; exchange id first, the exact integer the library minted. Signaling routes by
;; exchange id, so a dial to a peer and that peer's own offer run side by side
;; as two exchanges. `#:offer`, `#:answer`, and `#:on-candidate` also take a
;; `webrtc-target` after the id. A target names the peer one exchange is with. Its
;; `designator` is the peer's designator. Its `introducer` is the designator of
;; the session that handed over the reference a dial follows, so the
;; application can carry signaling through the party that knows the peer. It is
;; `#f` for a dial the application started itself or whose introducing session
;; signed no designator, and for every accept. `#:offer` takes the target and an
;; SDP offer and returns the SDP answer. `#:answer` takes the target and the
;; SDP answer to an inbound offer and carries it to the offerer, and raising
;; refuses that offer. `#:candidate` takes only the id and one local ICE
;; candidate as JSON text. `#:on-candidate` takes the target and a sink, calls
;; the sink with each of the exchange's far candidates as JSON text, and returns a
;; thunk that ends the subscription.
;; Each dial runs `#:on-candidate` and then `#:offer` on one thread of its own,
;; so `#:on-candidate` returns promptly and the offer may wait. `#:answer` runs
;; inside `webrtc-server-provide-offer!` in atomic mode, so it returns without
;; waiting. `#:candidate` runs on a thread per local candidate, so its calls may
;; overlap and arrive in any order. A procedure that raises records its error on
;; the Host and fails that exchange.
;;
;; `webrtc-provider` composes WebRTC into a Runtime explicitly, so a program
;; that dials only TCP never needs the library. `listen-webrtc` composes it into
;; a Host that answers: the application hands each inbound offer to
;; `webrtc-server-provide-offer!`, and `webrtc-server-accept` returns the
;; session once the channel opens. This file is the application surface and
;; nothing else.
(require "private/webrtc.rkt")

(provide webrtc-locator webrtc-provider
         webrtc-config webrtc-config?
         webrtc-ice-server webrtc-ice-server?
         make-webrtc-signaling webrtc-signaling?
         (struct-out webrtc-target)
         listen-webrtc webrtc-server?
         webrtc-server-host webrtc-server-locator webrtc-server-uri
         webrtc-server-designator webrtc-server-accept webrtc-server-close!
         webrtc-server-provide-offer! webrtc-server-fail-exchange!)
