#lang racket/base
;; One family of the Racket binding's test suite, loadable on its own: how a
;; Host is built and what open-runtime accepts beside an adopted one.

(require "../../glowcap.rkt"
         "../../glowcap-tcp.rkt"
         "../../private/locator.rkt"
         (combine-in "../../private/host.rkt" "../../private/host/state.rkt")
         "../../private/errors.rkt"
         "../../private/constants.rkt"
         "support.rkt")

(for ([invalid-seed (list (make-bytes 31) (make-bytes 33))])
  (define refused
    (with-handlers ([exn:fail:glowcap? values])
      (make-host invalid-seed)
      #f))
  (expect (and (exn:fail:glowcap? refused)
               (= ERR-INVALID-ARGUMENT (exn:fail:glowcap-code refused)))
          "Host must reject a seed that is not 32 bytes"))

(define caller-seed (make-bytes 32 7))
(define owned-seed-host (make-host caller-seed))
(bytes-set! caller-seed 0 8)
(expect (immutable? (host-seed owned-seed-host))
        "Host must expose an immutable seed")
(expect (= 7 (bytes-ref (host-seed owned-seed-host) 0))
        "Host must retain an owned seed copy")
(host-close! owned-seed-host)

(define locator-host (make-fresh-host))
(host-set-advertised-locator!
 locator-host
 (locator "tcp" "127.0.0.1:7441" (hash) 'map))
(host-remove-advertised-locator! locator-host "tcp")
(host-close! locator-host)

(define profile-host (make-fresh-host))
(define profile-conflict
  (with-handlers ([exn:fail:glowcap? values])
    (open-test-session (tcp-locator "127.0.0.1" 1)
             #:adopt-host profile-host
             #:captp-version 'next)
    #f))
(expect (and (exn:fail:glowcap? profile-conflict)
             (= ERR-INVALID-ARGUMENT (exn:fail:glowcap-code profile-conflict)))
        "connect: an adopted Host refuses a Host option")
(host-close! profile-host)

;; An adopted Host keeps its own profile, so open-runtime refuses every Host
;; option beside it, even one that would match.
(define adopt-options-host (make-fresh-host))
(define adopt-options-refusal
  (with-handlers ([exn:fail:glowcap? values])
    (open-test-session (tcp-locator "127.0.0.1" 1)
                       #:adopt-host adopt-options-host
                       #:codec (host-codec adopt-options-host))
    #f))
(expect (and (exn:fail:glowcap? adopt-options-refusal)
             (= ERR-INVALID-ARGUMENT (exn:fail:glowcap-code adopt-options-refusal))
             (regexp-match? #rx"#:adopt-host cannot be combined with Host options \\(#:codec\\)"
                            (exn-message adopt-options-refusal)))
        "open-runtime: an adopted Host refuses a matching #:codec by name")
(host-close! adopt-options-host)

;; A minted Host takes #:local-turn-budget through the same open-runtime call.
(define budget-runtime
  (open-runtime #:providers (list (tcp-provider)) #:local-turn-budget 8))
(expect (host? (runtime-host budget-runtime))
        "open-runtime: #:local-turn-budget opens a minted Host")
(runtime-close! budget-runtime)
(printf "racket test OK: Host construction and open-runtime refuse what they must\n")
