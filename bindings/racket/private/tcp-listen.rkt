#lang racket/base
;; Native TCP-provider listener surface. The driver owns provider sockets,
;; admission, handshakes, events, session release, and canonical locator
;; metadata. `tcp`, `keyed-tcp`, and `noise-tcp` share one server shape and one
;; setup path; only their locator profile differs.

(require racket/lazy-require
         racket/random
         racket/string
         "constants.rkt"
         "abi-value.rkt"
         "errors.rkt"
         "locator.rkt"
         "socket-address.rkt"
         "tcp-config.rkt"
         "host/state.rkt")

(lazy-require
 ["loop.rkt"
  (open-driver-loop
   driver-loop-start!
   driver-loop-abort!
   loop-listen!
   loop-listener-ready!
   loop-listener-locator
   loop-listener-advertise!
   loop-listener-select!
   loop-listener-close!
   make-loop-server
   loop-server?
   loop-server-locator
   loop-server-host
   loop-server-accept
   loop-server-close!)]
 ["tcp-provider.rkt" (driver-loop-add-tcp!)])

(provide server?
         server-host
         server-locator
         server-uri
         server-port
         server-close!
         accept
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
    (raise-pancake who ERR-INVALID-ARGUMENT
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
                  (raise-pancake who ERR-INVALID-ARGUMENT
                                 "listener locator has no direct-addresses hint")))))

(define (listen-tcp-profile who transport bind-host port seed codec captp-version
                            features advertised-host time-travel? shared-host config options)
  (when (and shared-host codec (not (eq? codec (host-codec shared-host))))
    (raise-pancake who ERR-INVALID-ARGUMENT
                   "the supplied Host codec conflicts with #:codec"))
  (when (and seed shared-host (not (bytes=? seed (host-seed shared-host))))
    (raise-pancake who ERR-INVALID-ARGUMENT
                   "the seed conflicts with the supplied Host"))
  (define durable
    (and (identity-profile? transport)
         (or seed (and shared-host (host-seed shared-host))
             (crypto-random-bytes 32))))
  (when (and durable (not (= (bytes-length durable) 32)))
    (raise-pancake who ERR-INVALID-ARGUMENT "seed must be 32 bytes"))
  (define-values (lp owns-loop?)
    (if (and shared-host (host-loop-of shared-host))
        (values (host-loop-of shared-host) #f)
        (values
         (if durable
             (open-driver-loop #:host shared-host #:seed durable
                               #:codec (or codec
                                           (and shared-host (host-codec shared-host))
                                           DEFAULT-CODEC-SYMBOL)
                               #:captp-version captp-version #:features features)
             (open-driver-loop #:host shared-host
                               #:codec (or codec
                                           (and shared-host (host-codec shared-host))
                                           DEFAULT-CODEC-SYMBOL)
                               #:captp-version captp-version #:features features))
         #t)))
  (define listener #f)
  (with-handlers ([(lambda (_) #t)
                   (lambda (e)
                     (when listener (loop-listener-close! lp listener))
                     (when (and owns-loop? (not shared-host))
                       (driver-loop-abort! lp))
                     (raise e))])
    (driver-loop-add-tcp! lp config)
    (set! listener
          (loop-listen! lp transport (format "~a:~a" bind-host port) options))
    (driver-loop-start! lp)
    (set! listener (loop-listener-ready! listener))
    (define loc (loop-listener-locator lp listener))
    (define direct (locator-direct-address who loc))
    (define-values (bound-host bound-port) (split-designator who direct))
    (when (and (wildcard-address? bound-host) (not advertised-host))
      (raise-pancake who ERR-INVALID-ARGUMENT
                     "a wildcard bind has no dialable address; provide #:advertised-host"))
    (when (and advertised-host (wildcard-address? advertised-host))
      (raise-pancake who ERR-INVALID-ARGUMENT
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
      (loop-listener-advertise! lp listener locator-uri))
    (loop-listener-select! lp listener)
    (make-loop-server lp listener time-travel? (not shared-host))))

(define (listen bind-host [port 0] #:codec [codec #f]
                #:captp-version [captp-version DEFAULT-CAPTP-VERSION-SYMBOL]
                #:features [features DEFAULT-FEATURES-SYMBOL]
                #:advertised-host [advertised-host #f]
                #:time-travel? [time-travel? #f]
                #:host [shared-host #f]
                #:config [config (make-tcp-config)]
                #:options [options #f])
  (listen-tcp-profile 'listen TRANSPORT-TCP bind-host port #f codec
                      captp-version features advertised-host time-travel?
                      shared-host config options))

(define (listen-keyed-tcp bind-host [port 0] #:seed [seed #f] #:codec [codec #f]
                          #:captp-version [captp-version DEFAULT-CAPTP-VERSION-SYMBOL]
                          #:features [features DEFAULT-FEATURES-SYMBOL]
                          #:advertised-host [advertised-host #f]
                          #:time-travel? [time-travel? #f]
                          #:host [shared-host #f]
                          #:config [config (make-tcp-config)]
                          #:options [options #f])
  (listen-tcp-profile 'listen-keyed-tcp TRANSPORT-KEYED-TCP bind-host port seed codec
                      captp-version features advertised-host time-travel?
                      shared-host config options))

(define (listen-noise-tcp bind-host [port 0] #:seed [seed #f] #:codec [codec #f]
                          #:captp-version [captp-version DEFAULT-CAPTP-VERSION-SYMBOL]
                          #:features [features DEFAULT-FEATURES-SYMBOL]
                          #:advertised-host [advertised-host #f]
                          #:time-travel? [time-travel? #f]
                          #:host [shared-host #f]
                          #:config [config (make-tcp-config)]
                          #:options [options #f])
  (listen-tcp-profile 'listen-noise-tcp TRANSPORT-NOISE-TCP bind-host port seed codec
                      captp-version features advertised-host time-travel?
                      shared-host config options))

(define server? loop-server?)
(define server-host loop-server-host)
(define server-locator loop-server-locator)
(define (server-uri s) (format-locator-uri (server-locator s)))
(define (server-port s)
  (define-values (_host port)
    (split-designator 'server-port
                      (locator-direct-address 'server-port (server-locator s))))
  port)
(define accept loop-server-accept)
(define server-close! loop-server-close!)
