#lang racket/base
;; FFI TCP-provider listener surface. The driver owns provider sockets,
;; admission, handshakes, events, session release, and canonical locator
;; metadata. `tcp`, `keyed-tcp`, and `noise-tcp` share one server shape and one
;; setup path; only their locator profile differs. The setup path itself is
;; `listen-loop.rkt`'s; this module owns the provider install and the bound
;; address a listener advertises.

(require racket/lazy-require
         racket/string
         "constants.rkt"
         "errors.rkt"
         "listen-loop.rkt"
         "locator.rkt"
         "server-verbs.rkt"
         "socket-address.rkt"
         "tcp-config.rkt")

(lazy-require
 ["loop.rkt"
  (loop-listener-locator
   loop-listener-advertise!)]
 ["tcp-provider.rkt" (driver-loop-add-tcp!)])

(provide (all-from-out "server-verbs.rkt")
         server-port
         listen
         listen-keyed-tcp
         listen-noise-tcp)

(define (wildcard-address? host)
  (define bare
    (if (and (string-prefix? host "[") (string-suffix? host "]"))
        (substring host 1 (sub1 (string-length host)))
        host))
  (or (string=? bare "0.0.0.0")
      (and (string-contains? bare ":")
           (for/and ([part (in-list (string-split bare ":" #:trim? #f))])
             (or (string=? part "") (regexp-match? #px"^0+$" part))))))

(define (split-designator who designator)
  (define match (regexp-match #px"^(.*):([0-9]+)$" designator))
  (unless match
    (raise-glowcap who ERR-INVALID-ARGUMENT
                   "listener designator is not host:port: ~a" designator))
  (values (cadr match) (string->number (caddr match))))

(define (identity-profile? transport)
  (or (string=? transport TRANSPORT-KEYED-TCP)
      (string=? transport TRANSPORT-NOISE-TCP)))

(define (locator-direct-address who loc)
  (if (string=? (locator-transport loc) TRANSPORT-TCP)
      (locator-designator loc)
      (hash-ref (locator-hints loc) HINT-DIRECT-ADDRESSES
                (lambda ()
                  (raise-glowcap who ERR-INVALID-ARGUMENT
                                 "listener locator has no direct-addresses hint")))))

;; The bound address is what the provider reports; the advertised address is
;; what partners dial. A wildcard bind is deployment policy with no dialable
;; form, so it needs an explicit advertised host, and only a differing
;; advertised address rewrites the listener's locator.
(define ((advertise-bound-address! who transport advertised-host) lp listener)
  (define loc (loop-listener-locator lp listener))
  (define direct (locator-direct-address who loc))
  (define-values (bound-host bound-port) (split-designator who direct))
  (when (and (wildcard-address? bound-host) (not advertised-host))
    (raise-glowcap who ERR-INVALID-ARGUMENT
                   "a wildcard bind has no dialable address; provide #:advertised-host"))
  (when (and advertised-host (wildcard-address? advertised-host))
    (raise-glowcap who ERR-INVALID-ARGUMENT
                   "an advertised host must be dialable"))
  (define advertised-direct
    (if advertised-host
        (tcp-address-designator advertised-host bound-port)
        direct))
  (unless (equal? direct advertised-direct)
    (define locator-uri
      (if (string=? transport TRANSPORT-TCP)
          (format-peer-uri transport advertised-direct)
          (format-peer-uri
           transport
           (locator-designator loc)
           (hash HINT-DIRECT-ADDRESSES advertised-direct))))
    (loop-listener-advertise! lp listener locator-uri)))

(define (listen-tcp-profile who transport bind-host port seed codec captp-version
                            features advertised-host time-travel? shared-host config options)
  (listen-loop-profile who transport (format "~a:~a" bind-host port)
                       #:identity? (identity-profile? transport)
                       #:seed seed #:codec codec #:captp-version captp-version
                       #:features features #:options options
                       #:host shared-host #:time-travel? time-travel?
                       #:install (lambda (lp) (driver-loop-add-tcp! lp config))
                       #:after-ready (advertise-bound-address! who transport advertised-host)))

;; Every keyword below is honored exactly or refused. `#:codec`,
;; `#:captp-version`, and `#:features` default to the supplied Host's profile,
;; else the generated default; a value that differs from a supplied Host's is
;; refused. `#:options` is the TCP operation options value (`make-tcp-options`)
;; for this one listen.
(define (listen bind-host [port 0] #:codec [codec #f]
                #:captp-version [captp-version #f]
                #:features [features #f]
                #:advertised-host [advertised-host #f]
                #:time-travel? [time-travel? #f]
                #:host [shared-host #f]
                #:config [config (make-tcp-config)]
                #:options [options #f])
  (listen-tcp-profile 'listen TRANSPORT-TCP bind-host port #f codec
                      captp-version features advertised-host time-travel?
                      shared-host config options))

(define (listen-keyed-tcp bind-host [port 0] #:seed [seed #f] #:codec [codec #f]
                          #:captp-version [captp-version #f]
                          #:features [features #f]
                          #:advertised-host [advertised-host #f]
                          #:time-travel? [time-travel? #f]
                          #:host [shared-host #f]
                          #:config [config (make-tcp-config)]
                          #:options [options #f])
  (listen-tcp-profile 'listen-keyed-tcp TRANSPORT-KEYED-TCP bind-host port seed codec
                      captp-version features advertised-host time-travel?
                      shared-host config options))

(define (listen-noise-tcp bind-host [port 0] #:seed [seed #f] #:codec [codec #f]
                          #:captp-version [captp-version #f]
                          #:features [features #f]
                          #:advertised-host [advertised-host #f]
                          #:time-travel? [time-travel? #f]
                          #:host [shared-host #f]
                          #:config [config (make-tcp-config)]
                          #:options [options #f])
  (listen-tcp-profile 'listen-noise-tcp TRANSPORT-NOISE-TCP bind-host port seed codec
                      captp-version features advertised-host time-travel?
                      shared-host config options))

(define (server-port s)
  (define-values (_host port)
    (split-designator 'server-port
                      (locator-direct-address 'server-port (server-locator s))))
  port)
