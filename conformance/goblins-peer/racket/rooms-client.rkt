#lang racket/base
;; rooms-client.rkt: the rooms chat, spoken by a real Spritely Goblins vat.
;;
;; The rooms fleet is written in glowcap and advertises its private CapTP
;; profile, `glowcap-next` over Cap'n Proto. A Goblins vat speaks the OCapN v1.0
;; baseline over Syrup and sends no glowcap-private preference. Under ADR-0001,
;; an absent preference means baseline-only, so the pair settles on the baseline
;; while glowcap members on the same server keep the glowcap profile among
;; themselves. The vat still joins the room as an ordinary member.
;;
;; This module is the wire protocol of `apps/rooms/lib/protocol.ts` in Goblins
;; terms, and nothing else: dial the server, reach the directory, enter or open a
;; room, and spawn the inbox the room calls back. Its two callers are the
;; one-shot `rooms-member.rkt`, which the `goblins-rooms` build step runs, and
;; the interactive `rooms-chat.rkt`, which a person types in.
;;
;; A rooms server announces a locator and the locator says which transport
;; reaches it, so this module reads the transport off the locator and spawns the
;; netlayer that speaks it: `tcp-netlayer.rkt` for a cleartext socket,
;; `iroh-netlayer.rkt` for an encrypted QUIC endpoint. Nothing above
;; `connect-directory` knows which one it got, because the rooms protocol is the
;; same conversation either way.
;;
;; Everything here that touches a capability must be called from inside a vat
;; turn, `(vat 'run …)` or a handler, because that is where Goblins lets an
;; actor be spawned or a message be sent.

(require goblins
         goblins/ocapn
         goblins/ocapn/structs-urls
         (submod goblins/ocapn/structs-urls marshall)
         goblins/actor-lib/methods
         "tcp-netlayer.rkt"
         "iroh-netlayer.rkt"
         (only-in "../../../bindings/racket/glowcap-iroh.rkt" IROH-REACH-DIRECT)
         net/uri-codec
         net/url
         racket/list
         racket/string)

(provide locator->node
         node->locator
         node-hints
         local-port-argument
         connect-directory
         enter-or-open
         spawn-inbox
         room-error-code)

;; The swiss-num the rooms server publishes its directory under (`DIRECTORY` in
;; the rooms protocol). ASCII, so the sturdyref is built from the struct
;; constructor rather than parsed out of a URL.
(define directory-swiss #"directory")

;; The contracted `ocapn-node` constructor admits only #f-or-string hints, while
;; the draft's hints are a mapping and the wire unmarshaller builds nodes through
;; the raw constructor. A hinted location has to be exactly what a decoded hello
;; would hold, so it is built through that same constructor.
(define make-wire-ocapn-node (cdr unmarshall::ocapn-node))

;; The rooms locator, as the OCapN peer a netlayer dials.
;;
;; A rooms server announces itself as `ocapn://<designator>.<transport>?<hints>`,
;; and a TCP one as the bare `host:port` shorthand the demos print. Both forms
;; answer with an `ocapn-node`, so everything downstream reads the transport off
;; the locator instead of assuming one.
;;
;; The shorthand is not a convenience over the URI form for TCP, it is the only
;; spelling of it: a URL parser reads what follows the colon in
;; `ocapn://127.0.0.1:9099.tcp` as a port number and refuses it, so a TCP peer's
;; address cannot travel through the URI form at all.
;;
;; Goblins parses the URI form: `string->url` splits the scheme, the host and the
;; percent-encoded query, and `url->ocapn-node` splits that host into a transport
;; symbol and a designator. What it cannot express is the hints, it builds every
;; node with `#f` there, and its contracted constructor would refuse the mapping
;; the draft carries anyway, so the query is folded into a mapping here and the
;; hinted node is built through the wire constructor above.
(define (locator->node locator)
  (if (string-prefix? locator "ocapn:")
      (uri->node locator)
      (host:port->node locator)))

;; The `ocapn://…` form. An unparseable one is refused by name: it reaches here
;; only because it announced itself as an OCapN URI, so failing with Goblins's
;; own contract error would name a URL struct rather than what was typed.
;;
;; `string->url` lowercases the host, so the designator it yields is lowercase.
;; That is safe for the two transports this client speaks and only those: an
;; `iroh` designator is 64 lowercase hex digits already, and a `tcp` one is a
;; host name or an address, neither of which is case-sensitive. A transport whose
;; designator is base32 or base64 would need its case back before this could
;; carry it.
(define (uri->node locator)
  (define url
    (with-handlers ([exn:fail? (lambda (_) (bad-locator locator))])
      (string->url locator)))
  (define bare
    (with-handlers ([exn:fail? (lambda (_) (bad-locator locator))])
      (url->ocapn-node url)))
  ;; Goblins leaves percent escapes in the designator. Decode the TCP socket
  ;; address and validate it through the same admission as the shorthand.
  (define designator
    (if (eq? (ocapn-node-transport bare) 'tcp)
        (ocapn-node-designator
         (host:port->node (uri-decode (ocapn-node-designator bare))))
        (ocapn-node-designator bare)))
  (define hints (query->hints (url-query url)))
  (make-wire-ocapn-node (ocapn-node-transport bare) designator hints))

;; The query of an OCapN URI as the hint mapping a decoded hello carries, or #f
;; when it has none. `url-query` has already percent-decoded each value, so an
;; `iroh` locator's `direct-addresses` arrives with its `:` separators and its
;; bracketed IPv6 address intact. The keys are strings because that is what the
;; wire carries and what a netlayer looks them up by; a valueless key is dropped,
;; since a hint with nothing in it is advice nobody can follow.
(define (query->hints query)
  (define pairs
    (for/list ([entry (in-list query)] #:when (string? (cdr entry)))
      (cons (symbol->string (car entry)) (cdr entry))))
  (and (pair? pairs) (make-immutable-hash pairs)))

;; The hints of a node, read the way a netlayer reads them. The contracted
;; accessor admits only #f-or-string while the draft's hints are a mapping, and
;; the wire unmarshaller builds nodes through the raw constructor, so the field
;; is read off the transparent struct instead.
(define (node-hints node) (vector-ref (struct->vector node) 3))

;; The locator string a peer reaches `node` by, the string `locator->node`
;; reads back.
;;
;; A TCP node without hints answers the bare `host:port` shorthand. Hinted nodes
;; use the URI form, with TCP address delimiters encoded in the designator.
;; A node's hints become the query. The values are percent-encoded, so an iroh locator's
;; `direct-addresses` arrives at the far side with its `:` separators and its
;; bracketed IPv6 address intact.
;;
;; The keys are sorted, so one node always renders as one string. A hint carrying
;; bytes renders as those bytes read back as text, which is how the wire carried
;; them.
(define (node->locator node)
  (define transport (ocapn-node-transport node))
  (define designator (ocapn-node-designator node))
  (define hints (node-hints node))
  (cond
    [(and (eq? transport 'tcp) (not hints)) designator]
    [else
     (define pairs
       (if (hash? hints)
           (sort (for/list ([(key value) (in-hash hints)])
                   (cons (string->symbol (hint-text key)) (hint-text value)))
                 string<?
                 #:key (lambda (pair) (symbol->string (car pair))))
           '()))
     (string-append "ocapn://" (if (eq? transport 'tcp) (uri-encode designator) designator)
                    "." (symbol->string transport)
                    (if (null? pairs)
                        ""
                        (string-append "?" (alist->form-urlencoded pairs))))]))

;; A hint key or value as text. Both travel as bytes on the wire and as strings
;; in a node this module builds, and a locator is text either way.
(define (hint-text value) (if (bytes? value) (bytes->string/utf-8 value) value))

;; The bare `host:port` shorthand, which names a TCP peer and nothing else.
(define (host:port->node locator)
  ;; The host is either one nonempty colon-free name or a bracketed IPv6
  ;; literal. Restrict the port capture to decimal digits before converting it,
  ;; then apply the socket API's u16 range here rather than letting a malformed
  ;; designator fail later in Goblins networking.
  (define match
    (regexp-match #px"^(?:\\[[^\\]]+\\]|[^:\\[\\]]+):([0-9]+)$" locator))
  (define port (and match (string->number (cadr match))))
  (unless (and (exact-nonnegative-integer? port) (< port 65536))
    (bad-locator locator))
  (ocapn-node 'tcp locator #f))

(define (bad-locator locator)
  (error 'rooms-client
         "expected a host:port or ocapn://<designator>.<transport> rooms locator, got ~v"
         locator))

;; Read a command line's local-port argument. Absent means an ephemeral port,
;; which is the ordinary case; anything that is not a port is refused here,
;; naming what was typed, rather than travelling on as #f and failing at the
;; dial. Both scripts that take the argument read it through this.
(define (local-port-argument raw)
  (cond
    [(or (not raw) (string=? raw "")) 0]
    [(let ([n (string->number raw)])
       (and (exact-nonnegative-integer? n) (< n 65536) n))]
    [else
     (error 'rooms-client
            "expected a local port number, got ~v (the trace endpoint is the GLOWCAP_ROOMS_TRACE_URL environment variable, not an argument)"
            raw)]))

;; The netlayer that reaches `node`, spawned. Which one it is comes from the
;; locator's own transport symbol; nothing here assumes a transport.
;;
;; `local-port` is the port this vat's own netlayer binds. It is a TCP fact: an
;; iroh endpoint is reached by its Ed25519 key rather than by an address, so
;; there is no port to name, and a port typed alongside an iroh locator is
;; refused rather than quietly ignored. 0 asks for an ephemeral port and is the
;; ordinary choice on both, since nothing in the rooms protocol dials a member
;; back.
;;
;; `session-trace` is the sink the netlayer reports its CapTP sessions to, or #f
;; to report nothing. Both netlayers take the same sink and report the same
;; facts; what differs is the transport they name and what a session over them
;; can accurately claim to have proved.
(define (spawn-netlayer-for node local-port session-trace)
  (case (ocapn-node-transport node)
    [(tcp)
     (spawn ^tcp-netlayer "127.0.0.1" local-port #:session-trace session-trace)]
    [(iroh)
     (unless (zero? local-port)
       (error 'rooms-client
              "an iroh locator has no local port to bind, got ~v (drop the local-port argument; an iroh vat is reached by its endpoint key, not by an address)"
              local-port))
     ;; Direct reachability: the rooms fleet announces `direct-addresses`, so a
     ;; dialer needs no discovery service to find the endpoint the hints name.
     (spawn ^iroh-netlayer IROH-REACH-DIRECT #:session-trace session-trace)]
    [else
     (error 'rooms-client
            "no netlayer for a ~a rooms locator; this client speaks tcp and iroh"
            (ocapn-node-transport node))]))

;; Dial the rooms server and answer two things: a vow on its directory, and the
;; locator other peers reach *this* vat by.
;;
;; Both come out of one act, which is why they arrive together. The netlayer
;; spawned to reach the server is also the one that answers a peer dialing this
;; vat, so the address it announces is exactly the member locator `register`
;; carries and a direct message is redeemed against. A caller that only joins a
;; room ignores the second value.
(define (connect-directory locator
                           #:local-port [local-port 0]
                           #:session-trace [session-trace #f])
  (unless (exact-nonnegative-integer? local-port)
    (error 'rooms-client "expected a local port number, got ~v" local-port))
  (define node (locator->node locator))
  (define netlayer (spawn-netlayer-for node local-port session-trace))
  (define mycapn (spawn-mycapn netlayer))
  (values (<- mycapn 'enliven (ocapn-sturdyref node directory-swiss))
          (node->locator ($ netlayer 'our-location))))

;; Enter `name`, opening it when there is no such room yet. Another peer may
;; open the room after our failed enter, so an open collision retries enter.
;; Both verbs answer with a live reference to that room; `on-error` hears the
;; reason when none of the three attempts works.
(define (enter-or-open directory name on-room on-error)
  (on (<- directory 'enter name)
      on-room
      #:catch
      (lambda (err)
        (if (no-such-room-error? err)
            (on (<- directory 'open name)
                on-room
                #:catch
                (lambda (open-err)
                  (if (equal? (room-error-code open-err) "room-exists")
                      (on (<- directory 'enter name) on-room #:catch on-error)
                      (on-error open-err))))
            (on-error err)))))

(define (no-such-room-error? err)
  (equal? (room-error-code err) "no-such-room"))

;; The failures a rooms peer branches on, as the room server spells them
;; (`apps/rooms/lib/errors.ts`). A broken OCapN promise carries a string reason,
;; so the code rides at the front of it and a peer reads the code rather than the
;; prose, which is free to change.
(define room-error-codes
  '("nick-taken"
    "no-such-room"
    "room-exists"
    "peer-offline"
    "introduction-pending"
    "not-registered"
    "nick-too-long"
    "not-your-locator"))

;; The code a broken send carries, or #f when the failure is an anonymous one
;; nobody branches on. Goblins hands a `#:catch` handler whatever broke the
;; promise, and the binding on the way may have said something of its own first,
;; so the code is looked for across the colon-separated segments rather than only
;; at the front.
(define (room-error-code err)
  (define text (if (exn? err) (exn-message err) (format "~a" err)))
  (for/first ([part (in-list (string-split text ": "))]
              #:when (member part room-error-codes))
    part))

;; Spawn the inbox a room calls back on. The room sends `notify(from, text)` for
;; every line anyone posts, and a system line may carry structured presence after
;; the text, so `on-line` receives the speaker, the line, and whatever else came
;; with it.
(define (spawn-inbox on-line)
  (spawn
   (lambda (_bcom)
     (methods
      [(notify from text . rest) (on-line from text rest)]))))

(module+ test
  ;; What is checked here is the reading of a locator, which is pure and needs
  ;; no vat. Which netlayer `connect-directory` then spawns is not: it takes a
  ;; vat turn and, for iroh, a bound endpoint, so a live step is what covers it
  ;; and a green run here says nothing about it.
  (require rackunit)

  ;; The bare shorthand names a TCP peer by the address a dialer connects to.
  (let ([node (locator->node "127.0.0.1:9099")])
    (check-equal? (ocapn-node-transport node) 'tcp)
    (check-equal? (ocapn-node-designator node) "127.0.0.1:9099")
    (check-false (node-hints node)))
  (let ([node (locator->node "[::1]:9099")])
    (check-equal? (ocapn-node-transport node) 'tcp)
    (check-equal? (ocapn-node-designator node) "[::1]:9099")
    (check-false (node-hints node)))

  ;; TCP URIs encode their address delimiter; literal colons are URL port
  ;; syntax, and a designator without a socket port still refuses.
  (check-exn #rx"rooms locator" (lambda () (locator->node "ocapn://127.0.0.1.tcp")))
  (check-exn #rx"rooms locator" (lambda () (locator->node "ocapn://127.0.0.1:9099.tcp")))
  (let ([node (locator->node "ocapn://127.0.0.1%3A9099.tcp?glowcap%2Fcaptp-version=glowcap-next")])
    (check-equal? (ocapn-node-designator node) "127.0.0.1:9099")
    (check-equal? (node-hints node) (hash "glowcap/captp-version" "glowcap-next"))
    (check-equal? (locator->node (node->locator node)) node))
  (let ([node (locator->node "ocapn://%5B%3A%3A1%5D%3A9099.tcp")])
    (check-equal? (ocapn-node-designator node) "[::1]:9099"))

  ;; An iroh locator as a rooms server announces one: the designator is the
  ;; endpoint's Ed25519 key and the addresses ride percent-encoded in the query.
  ;; Every `:` in the list arrives as `%3A`, and a bracketed IPv6 address arrives
  ;; as `%5B%3A%3A1%5D`, so decoding is the whole of what this has to get right,
  ;; a dialer handed the encoded spelling has nothing it can connect to.
  (let* ([designator (make-string 64 #\a)]
         [node (locator->node
                (string-append
                 "ocapn://" designator ".iroh?direct-addresses="
                 "127.0.0.1%3A53049,172.19.0.4%3A53049,%5B%3A%3A1%5D%3A55306"))])
    (check-equal? (ocapn-node-transport node) 'iroh)
    (check-equal? (ocapn-node-designator node) designator)
    (check-equal? (node-hints node)
                  (hash "direct-addresses"
                        "127.0.0.1:53049,172.19.0.4:53049,[::1]:55306")))

  ;; A discovery-posture server announces its endpoint id and nothing else, and
  ;; a node with no hints carries #f there, which is the empty spelling the wire
  ;; unmarshaller produces and every reader in this directory expects.
  (let ([node (locator->node (string-append "ocapn://" (make-string 64 #\b) ".iroh"))])
    (check-equal? (ocapn-node-transport node) 'iroh)
    (check-false (node-hints node)))

  ;; Several hints keep their own keys, and a valueless one is dropped: a hint
  ;; with nothing in it is advice nobody can follow.
  (let ([node (locator->node
               (string-append "ocapn://" (make-string 64 #\c)
                              ".iroh?direct-addresses=127.0.0.1%3A1&reachable"))])
    (check-equal? (node-hints node) (hash "direct-addresses" "127.0.0.1:1")))

  ;; Anything that is neither form is refused naming what was typed, rather than
  ;; travelling on to fail at the dial.
  (check-exn #rx"rooms locator" (lambda () (locator->node "127.0.0.1")))
  (check-exn #rx"rooms locator" (lambda () (locator->node "127.0.0.1:not-a-port")))
  (check-exn #rx"rooms locator" (lambda () (locator->node "127.0.0.1:1.5")))
  (check-exn #rx"rooms locator" (lambda () (locator->node "127.0.0.1:65536")))
  (check-exn #rx"rooms locator" (lambda () (locator->node "127.0.0.1:0x10")))
  (check-exn #rx"rooms locator" (lambda () (locator->node "::1:9099")))
  (check-exn #rx"rooms locator" (lambda () (locator->node "ocapn://no-transport-here")))

  ;; A member registers by the locator other peers reach it at, so rendering a
  ;; node back to text is as essential as reading one: what this produces is
  ;; what a browser redeems an introduction against.
  ;;
  ;; A TCP node renders as the shorthand, the only spelling that carries an
  ;; address, and reads back as the same node.
  (let ([node (locator->node "127.0.0.1:9099")])
    (check-equal? (node->locator node) "127.0.0.1:9099")
    (check-equal? (locator->node (node->locator node)) node))

  ;; An iroh node renders as the URI form with its hints as the query, and every
  ;; separator inside a value is encoded, so the round trip is exact.
  (let* ([designator (make-string 64 #\a)]
         [node (make-wire-ocapn-node
                'iroh designator
                (hash "direct-addresses" "127.0.0.1:53049,[::1]:55306"))])
    (check-equal? (node->locator node)
                  (string-append "ocapn://" designator ".iroh"
                                 "?direct-addresses=127.0.0.1%3A53049%2C%5B%3A%3A1%5D%3A55306"))
    (check-equal? (node-hints (locator->node (node->locator node)))
                  (hash "direct-addresses" "127.0.0.1:53049,[::1]:55306")))

  ;; A discovery-posture node has no hints, so it renders with no query at all.
  (let ([node (ocapn-node 'iroh (make-string 64 #\b) #f)])
    (check-equal? (node->locator node)
                  (string-append "ocapn://" (make-string 64 #\b) ".iroh"))
    (check-false (node-hints (locator->node (node->locator node)))))

  ;; Several hints render in one fixed order, so a node has one spelling rather
  ;; than one per hash iteration.
  (let ([node (make-wire-ocapn-node 'iroh "cc" (hash "zeta" "1" "alpha" "2"))])
    (check-equal? (node->locator node) "ocapn://cc.iroh?alpha=2&zeta=1"))

  ;; The wire may carry a hint as bytes; a locator is text either way.
  (let ([node (make-wire-ocapn-node 'iroh "dd" (hash #"direct-addresses" #"127.0.0.1:1"))])
    (check-equal? (node->locator node) "ocapn://dd.iroh?direct-addresses=127.0.0.1%3A1"))

  ;; The local-port argument, which both scripts read their command line through.
  (check-equal? (local-port-argument #f) 0)
  (check-equal? (local-port-argument "") 0)
  (check-equal? (local-port-argument "9099") 9099)
  (check-exn #rx"local port number" (lambda () (local-port-argument "70000")))
  (check-exn #rx"local port number" (lambda () (local-port-argument "ws://127.0.0.1:9300/")))

  ;; A refusal a peer acts on is read by its code. The room writes the code at
  ;; the front, and a binding may prefix a line of its own, so both spellings
  ;; have to reach the same answer.
  (check-equal? (room-error-code "introduction-pending: \"bob\" has been asked")
                "introduction-pending")
  (check-equal? (room-error-code "glowcap error -14: peer-offline: no member named \"bob\"")
                "peer-offline")
  (check-equal? (room-error-code (make-exn:fail "not-registered: register first"
                                                (current-continuation-marks)))
                "not-registered")
  (check-true (no-such-room-error? "no-such-room: no room named lobby"))
  (check-false (no-such-room-error? "not-registered: register first"))
  ;; A failure carrying no known code is nobody's branch.
  (check-false (room-error-code "directory has no method wat"))
  (check-false (room-error-code "")))
