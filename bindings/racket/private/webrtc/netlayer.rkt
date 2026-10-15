#lang racket/base
;; The WebRTC netlayer handle and its fallible C-ABI operations. This module
;; owns the archive-specific handle, the configuration record handed to
;; `glowcap_webrtc_netlayer_new`, the verbs that hand the far peer's offer,
;; answer, and candidates in and give an exchange up, and the package lease.
;; `runtime.rkt` owns the signaling exchanges that call them.

(require ffi/unsafe
         "../constants.rkt"
         "../ffi-webrtc.rkt"
         "../seam.rkt")

(provide (struct-out ice-server)
         (struct-out webrtc-netlayer)
         check/webrtc
         webrtc-netlayer-new
         webrtc-netlayer-provide-offer!
         webrtc-netlayer-provide-answer!
         webrtc-netlayer-provide-candidate!
         webrtc-netlayer-fail-exchange!
         webrtc-loop-provider-parts
         webrtc-netlayer-release!)

;; The diagnostic slot belongs to the WebRTC archive, not the core archive.
(define (webrtc-last-error) (read-last-error (webrtc-fn 'last-error)))
(define (check/webrtc code) (check-with code webrtc-last-error))

;; One STUN or TURN server: URL strings, plus a username and credential that
;; are both empty or both set.
(struct ice-server (urls username credential) #:transparent)

;; Nulling `handle` before release makes explicit close idempotent. `raw` is
;; the same pointer, kept for the exchange verbs: the caller runs them only
;; while the driver still holds its lease on the netlayer. `callbacks` holds the four function pointers the C
;; side keeps, so the collector never frees one it can still call.
(struct webrtc-netlayer (raw callbacks [handle #:mutable]))

(define (string-view text)
  (define bs (string->bytes/utf-8 text))
  (define pinned (pin-immobile bs))
  (values (make-GlowcapWebrtcStringView pinned (bytes-length bs)) pinned))

;; Build the ICE server array in raw memory the call borrows, run `proc` on
;; the array pointer and count, and free every block afterward.
(define (call-with-ice-servers servers proc)
  (define count (length servers))
  (define blocks '())
  (define (raw! ctype n)
    (define block (malloc (max n 1) ctype 'raw))
    (set! blocks (cons block blocks))
    block)
  (dynamic-wind
   void
   (lambda ()
     (define array (raw! _GlowcapWebrtcIceServer count))
     (define keep '())
     (for ([server (in-list servers)] [index (in-naturals)])
       (define urls (ice-server-urls server))
       (define url-array (raw! _GlowcapWebrtcStringView (length urls)))
       (for ([url (in-list urls)] [at (in-naturals)])
         (define-values (view bs) (string-view url))
         (set! keep (cons bs keep))
         (ptr-set! url-array _GlowcapWebrtcStringView at view))
       (define-values (user user-bs) (string-view (ice-server-username server)))
       (define-values (cred cred-bs) (string-view (ice-server-credential server)))
       (set! keep (list* user-bs cred-bs keep))
       (ptr-set! array _GlowcapWebrtcIceServer index
                 (make-GlowcapWebrtcIceServer url-array (length urls) user cred)))
     (begin0 (proc (and (positive? count) array) count)
             (void/reference-sink keep)))
   (lambda () (for ([block (in-list blocks)]) (free block)))))

;; `signaling` is the four function pointers this binding carries (offer,
;; answer, candidate, done). They are zero-context: the Racket closures carry
;; their own state.
(define (webrtc-netlayer-new ice-servers loopback? send-offer send-answer send-candidate done)
  (define signaling (make-GlowcapWebrtcSignaling #f send-offer send-answer send-candidate done))
  (call-with-ice-servers
   ice-servers
   (lambda (array count)
     (define-values (rc handle)
       ((webrtc-fn 'netlayer-new)
        (make-GlowcapWebrtcConfig array count (if loopback? 1 0) 0 signaling)))
     (check/webrtc rc)
     (webrtc-netlayer handle (list send-offer send-answer send-candidate done) handle))))

;; An exchange that already ended answers `ERR-INVALID-ARGUMENT` with no
;; effect. That is a late arrival and not a failure, so only other codes raise.
(define (late-or-check code)
  (unless (= code ERR-INVALID-ARGUMENT)
    (check/webrtc code)))

(define (webrtc-netlayer-provide-answer! netlayer exchange sdp)
  (define bs (string->bytes/utf-8 sdp))
  (late-or-check
   ((webrtc-fn 'netlayer-provide-answer)
    (webrtc-netlayer-raw netlayer) exchange (pin-immobile bs) (bytes-length bs))))

(define (webrtc-netlayer-provide-candidate! netlayer exchange ice)
  (define bs (string->bytes/utf-8 ice))
  (late-or-check
   ((webrtc-fn 'netlayer-provide-candidate)
    (webrtc-netlayer-raw netlayer) exchange (pin-immobile bs) (bytes-length bs))))

;; Hand in an inbound offer from the peer `designator` names. The library
;; answers through `send_answer` before this returns. Returns the accept's
;; exchange id, and every refusal raises with no exchange started.
(define (webrtc-netlayer-provide-offer! netlayer designator sdp)
  (define peer (string->bytes/utf-8 designator))
  (define offer (string->bytes/utf-8 sdp))
  (define-values (rc exchange)
    ((webrtc-fn 'netlayer-provide-offer)
     (webrtc-netlayer-raw netlayer)
     (pin-immobile peer) (bytes-length peer)
     (pin-immobile offer) (bytes-length offer)))
  (check/webrtc rc)
  exchange)

;; Give an exchange up after its signaling broke, so a dial fails at the
;; driver's next step instead of at the handshake deadline and an accept ends
;; without a session. A refusal means no such exchange is signaling.
(define (webrtc-netlayer-fail-exchange! netlayer exchange)
  (check/webrtc
   ((webrtc-fn 'netlayer-fail-exchange) (webrtc-netlayer-raw netlayer) exchange)))

;; Construct one archive-owned provider package. The returned close procedure
;; remains the rollback owner until the generic driver adopts the package.
(define (webrtc-loop-provider-parts ice-servers loopback? send-offer send-answer send-candidate done)
  (define netlayer
    (webrtc-netlayer-new ice-servers loopback? send-offer send-answer send-candidate done))
  (define close! (lambda () (webrtc-netlayer-release! netlayer)))
  (define package (make-GlowcapTransportProvider 0 0 #f 0 #f #f #f #f))
  (with-handlers ([(lambda (_) #t)
                   (lambda (error)
                     (close!)
                     (raise error))])
    (check/webrtc
     ((webrtc-fn 'transport-provider) (webrtc-netlayer-handle netlayer) package)))
  (values netlayer package close!))

;; Release the constructor's reference, once. The archive has no separate
;; close verb. Before the driver adopts the package this is the rollback, and
;; after it the driver's own lease keeps the shared endpoint up.
(define (webrtc-netlayer-release! netlayer)
  (define handle (webrtc-netlayer-handle netlayer))
  (when handle
    (set-webrtc-netlayer-handle! netlayer #f)
    ((webrtc-fn 'netlayer-release) handle)))
