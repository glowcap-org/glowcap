#lang racket/base
;; Native admission during close: cancellation is clean, while FINISH still
;; observes new sealed-channel failures. The shared Host owns both phases.

(require "../../glowcap.rkt"
         "../../private/session.rkt"
         "../../private/session/state.rkt"
         "../../private/session/close.rkt"
         "../../private/host.rkt"
         "../../private/host/state.rkt"
         "../../private/async.rkt"
         "../../private/pump.rkt"
         "../../private/constants.rkt"
         "../../private/errors.rkt"
         "support.rkt")

(for ([pending '(cancel finish)])
  (define m (make-fresh-host))
  (define remote (make-fresh-host))
  (host-set-advertised-locator! m
    (locator "noise-tcp" (designator-from-seed (host-seed m)) (hash) 'boolean-false))
  (define c
    (open-dialed-over m "noise-tcp" (designator-from-seed (host-seed remote))
                     (async-transport void void (lambda (_) eof) void)))
  (drain-host! m)
  (session-flush! c)
  ;; Admit close before the reader, without starting a rival close worker.
  (call-with-host m (lambda ()
    (begin-session-close/locked! c
      (close-options 'close-input pending
                     (if (eq? pending 'cancel) grace-unspecified #f)))))
  (define failure
    (with-handlers ([exn:fail:glowcap? values])
      ;; An all-zero responder handshake has an invalid identity element.
      (feed-bytes! c (make-bytes 144))
      #f))
  (case pending
    [(cancel)
     (expect (not failure) "cancelled ingress adds no wire failure")
     (session-close! c)]
    [(finish)
     (expect (and (exn:fail:glowcap? failure)
                  (= ERR-CLOSED (exn:fail:glowcap-code failure))
                  (regexp-match? #rx"IdentityElement" (exn-message failure)))
             "FINISH preserves the native sealed-channel failure")
     (define repeated (with-handlers ([exn:fail:glowcap? values]) (session-close! c) #f))
     (expect (eq? failure repeated) "close retains the exact refused-feed cause")])
  (with-handlers ([exn:fail:glowcap? void]) (host-close! m))
  (host-close! remote))

(printf "racket zig-smoke OK: close admission preserves new wire failures\n")
