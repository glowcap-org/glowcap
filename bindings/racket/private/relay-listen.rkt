#lang racket/base
;; Managed relay listeners over the generic driver loop: register a durable
;; key at the relay and accept sessions through the native driver. The
;; provider registers as the listener opens, so a ready listener means the
;; relay answered and holds this peer's sockets. The driver's provider
;; registry holds one relay configuration per loop: a second listen naming
;; the same routes rides the installed provider, and one naming different
;; routes is refused. The setup path is `listen-loop.rkt`'s, the same one the
;; TCP listeners walk; this module owns only the relay provider install.

(require racket/lazy-require
         "constants.rkt"
         "listen-loop.rkt"
         "server-verbs.rkt")

(lazy-require
 ["relay-provider.rkt" (driver-loop-add-relay!)])

(provide (all-from-out "server-verbs.rkt")
         listen-keyed-relay
         listen-noise-relay)

;; Both relay profiles are key-designated, so every listener keeps a durable
;; identity: the caller's seed, else the supplied Host's, else fresh entropy.
(define (listen-relay-profile who transport relay-url register-url
                              seed codec captp-version features options
                              shared-host trust-pem)
  (listen-loop-profile who transport ""
                       #:identity? #t
                       #:seed seed #:codec codec #:captp-version captp-version
                       #:features features #:options options
                       #:host shared-host #:time-travel? #f
                       #:install (lambda (lp)
                                   (driver-loop-add-relay! lp relay-url register-url
                                                           #:trust-pem trust-pem))))

;; Register the identity-addressed cleartext relay profile. The locator is
;; still identity-addressed; the relay path is not sealed.
;;
;; Every keyword is honored exactly or refused, as the TCP listeners do.
;; `#:codec`, `#:captp-version`, and `#:features` default to the supplied
;; Host's profile, else the generated default; a value that differs from a
;; supplied Host's is refused. `#:options` reaches the relay provider for this
;; one listen, and the relay package defines no per-listen options: it accepts
;; only an empty value and refuses any other as an invalid argument when the
;; listener opens, so a TCP options value cannot be silently dropped here.
(define (listen-keyed-relay relay-url register-url
                            #:seed [seed #f] #:codec [codec #f]
                            #:captp-version [captp-version #f]
                            #:features [features #f]
                            #:host [host #f]
                            #:trust-pem [trust-pem #f]
                            #:options [options #f])
  (listen-relay-profile 'listen-keyed-relay TRANSPORT-KEYED-RELAY
                        relay-url register-url seed codec captp-version features
                        options host trust-pem))

;; Register this listener's durable key at the relay and accept
;; Noise_XK-sealed sessions. The keywords are `listen-keyed-relay`'s.
(define (listen-noise-relay relay-url register-url
                            #:seed [seed #f] #:codec [codec #f]
                            #:captp-version [captp-version #f]
                            #:features [features #f]
                            #:host [host #f]
                            #:trust-pem [trust-pem #f]
                            #:options [options #f])
  (listen-relay-profile 'listen-noise-relay TRANSPORT-NOISE-RELAY
                        relay-url register-url seed codec captp-version features
                        options host trust-pem))
