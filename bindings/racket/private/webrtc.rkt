#lang racket/base
;; Private facade for the WebRTC companion.
;;
;; The public `../glowcap-webrtc.rkt` barrel consumes this surface. The
;; signaling exchanges live in `webrtc/runtime.rkt`, the netlayer handle in
;; `webrtc/netlayer.rkt`, and application composition in `webrtc/surface.rkt`.

(require "webrtc/surface.rkt")

(provide (all-from-out "webrtc/surface.rkt"))
