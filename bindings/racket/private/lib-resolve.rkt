#lang racket/base
;; Internal: publishable C-ABI archive resolve + open (ADR-0077).
;;
;; Language-native cascade: PANCAKE_LIB_DIR → abi-versioned cache → zig-out →
;; bare name (Windows refuses bare DLLs). Mirror of
;; bindings/python/pancake/_lib_resolve.py. The shared cstruct vocabulary stays
;; in ffi-shared.rkt — this module owns path resolution and ffi-lib only.
(require ffi/unsafe
         json
         racket/file
         racket/path
         racket/port
         racket/runtime-path
         racket/string
         racket/system)
(provide open-pancake-archive)

;; Package-local contract (ADR-0077). Ships with the binding; not the monorepo.
(define-runtime-path resolve-contract "c-abi-resolve.json")
;; Dev-only: walk to a pancake checkout when present (dogfoods / in-tree).
(define-runtime-path package-private-dir ".")

(define (env-truthy? name)
  (define v (getenv name))
  (and v (member (string-downcase (string-trim v)) '("1" "true" "yes"))))

(define (soft-fail! msg)
  (cond
    [(env-truthy? "PANCAKE_STRICT")
     (error 'pancake msg)]
    [else
     (eprintf "pancake: ~a (soft-fail)\n" msg)
     #f]))

;; Hygiene/security failures always fail closed (never gated on STRICT).
(struct exn:fail:pancake-hard exn:fail ())
(define (hard-fail! msg)
  (raise (exn:fail:pancake-hard
          (string-append "pancake: " msg)
          (current-continuation-marks))))

(define (load-contract)
  (define c (call-with-input-file resolve-contract read-json))
  (unless (eq? (hash-ref c 'require_https #f) #t)
    (error 'pancake "c-abi-resolve.json: require_https must be true"))
  (unless (eq? (hash-ref c 'require_checksum #f) #t)
    (error 'pancake "c-abi-resolve.json: require_checksum must be true"))
  (define releases-published (hash-ref c 'releases_published 'missing))
  (unless (boolean? releases-published)
    (error 'pancake "c-abi-resolve.json: releases_published must be a bool"))
  c)

;; Cold-cache network gate from contract releases_published.
(define (want-release-fetch? contract)
  (if (hash-ref contract 'releases_published)
      (not (env-truthy? "PANCAKE_SKIP_DOWNLOAD"))
      (env-truthy? "PANCAKE_DOWNLOAD")))

(define (apply-contract-template tmpl version target #:cache-base [cache-base ""])
  (string-replace
   (string-replace
    (string-replace tmpl "{version}" version #:all? #t)
    "{target}" target #:all? #t)
   "{cache_base}" cache-base #:all? #t))

(define (find-dev-root)
  (let loop ([dir (simplify-path package-private-dir #f)])
    (cond
      [(and (file-exists? (build-path dir "build.zig"))
            (file-exists? (build-path dir "include" "pancake_ocapn.h")))
       dir]
      [else
       (define parent (simplify-path (build-path dir 'up) #f))
       (if (equal? parent dir) #f (loop parent))])))

(define (resolve-abi-version contract [root (find-dev-root)])
  (cond
    [root
     (define header-rel (hash-ref contract 'version_header))
     (define header (build-path root header-rel))
     (define text (with-handlers ([exn:fail? (λ (_) #f)])
                    (file->string header)))
     (cond
       [(not text) (hash-ref contract 'abi_version)]
       [else
        (define (macro name default)
          (define rx (pregexp (format "#define\\s+~a\\s+(\\d+)" name)))
          (define m (regexp-match rx text))
          (if m (string->number (cadr m)) default))
        (format "~a.~a.~a"
                (macro "PANCAKE_VERSION_MAJOR" 0)
                (macro "PANCAKE_VERSION_MINOR" 1)
                (macro "PANCAKE_VERSION_PATCH" 0))])]
    [else (hash-ref contract 'abi_version)]))

;; All host aliases from tools/c-abi/c-abi-host-aliases.json (meta_check per-port presence).
(define host-alias-corpus
  '("x86_64" "amd64" "x64"
    "aarch64" "arm64"
    "macos" "darwin" "macosx" "Darwin"
    "linux" "Linux"
    "windows" "win32"))

(define (host-target-triple)
  ;; Normalize host aliases to zig build release-pack triples
  ;; (`tools/c-abi/c-abi-host-aliases.json`). Rust uses CARGO_CFG_* which
  ;; already emit those names. Corpus kept in host-alias-corpus.
  (define arch
    (case (system-type 'arch)
      [(x86_64 amd64 x64) "x86_64"]
      [(aarch64 arm64) "aarch64"]
      [else (symbol->string (system-type 'arch))]))
  (define zig-os
    (case (system-type 'os*)
      [(macosx darwin) "macos"]
      [(linux) "linux"]
      [(windows win32) "windows"]
      [else (symbol->string (system-type 'os*))]))
  ;; Touch corpus so the binding keeps every alias string (incl. Darwin/Linux).
  (void host-alias-corpus)
  (string-append arch "-" zig-os))

(define (ocapn-shared-marker [contract (load-contract)])
  ;; Load-time bindings open shared libs; marker matches Python/TS, not Rust's .a.
  (define stem (hash-ref contract 'marker_shared_stem))
  (case (system-type)
    [(macosx) (string-append "lib" stem ".dylib")]
    [(windows) (string-append stem ".dll")]
    [else (string-append "lib" stem ".so")]))

(define (cache-base contract)
  (or (getenv "PANCAKE_CACHE_DIR")
      (let ([xdg (getenv "XDG_CACHE_HOME")])
        (and xdg (build-path xdg "pancake" "c-abi")))
      (let ([home (or (getenv "HOME") (getenv "USERPROFILE"))])
        (if home
            (build-path home ".cache" "pancake" "c-abi")
            (build-path (find-system-path 'temp-dir)
                        (hash-ref contract 'fallback_cache_name))))))

(define (cache-lib-dir contract version target)
  (define base (cache-base contract))
  (define layout (hash-ref contract 'cache_layout))
  (string->path
   (apply-contract-template layout version target
                   #:cache-base (path->string (simplify-path base #f)))))

(define (require-https? base)
  (or (string-prefix? base "https://")
      (env-truthy? "PANCAKE_ALLOW_INSECURE")
      (hard-fail! (format "refusing non-HTTPS release base URL: ~a" base))))

(define (curl-tls-args url)
  (if (and (env-truthy? "PANCAKE_ALLOW_INSECURE")
           (not (string-prefix? url "https://")))
      '()
      '("--proto" "=https" "--tlsv1.2")))

(define (curl-download curl url dest ua max-bytes)
  (apply system* curl "-fsSL"
         (append (curl-tls-args url)
                 (list "--max-filesize" (number->string max-bytes)
                       "-A" ua
                       "-o" (path->string dest) url))))

(define (tar-tv-name line)
  (define without-link (car (string-split line " -> ")))
  (define parts (string-split without-link))
  (cond
    [(>= (length parts) 8) (string-join (list-tail parts 7) " ")]
    [(pair? parts) (car (reverse parts))]
    [else ""]))

;; List members, reject traversal/links under extract_prefix, then extract.
;; Refuse/link hard-fail; tar list failure soft-fails (tooling).
(define (safe-extract-prefix! tar tarball-path stage extract-prefix)
  (define-values (sp stdout stdin stderr)
    (subprocess #f #f 'stdout tar "-tvzf" (path->string tarball-path)))
  (define listing (port->string stdout))
  (close-input-port stdout)
  (close-output-port stdin)
  (subprocess-wait sp)
  (cond
    [(not (zero? (subprocess-status sp)))
     (soft-fail! "tar list failed")
     #f]
    [else
     (define prefix-slash (string-append extract-prefix "/"))
     (define ok?
       (let loop ([lines (string-split listing "\n")])
         (cond
           [(null? lines) #t]
           [(zero? (string-length (car lines))) (loop (cdr lines))]
           [else
            (define line (car lines))
            (define kind (string-ref line 0))
            (define name (tar-tv-name line))
            (cond
              [(and (not (equal? name extract-prefix))
                    (not (string-prefix? name prefix-slash)))
               (loop (cdr lines))]
              [(or (string-prefix? name "/")
                   (member ".." (string-split name "/")))
               (hard-fail! (format "refusing unsafe tar member: ~a" name))]
              [(or (char=? kind #\l) (char=? kind #\h))
               (hard-fail! (format "refusing link tar member: ~a" name))]
              [else (loop (cdr lines))])])))
     (and ok?
          (or (system* tar "-xzf" (path->string tarball-path)
                       "-C" (path->string stage)
                       "--no-same-owner" extract-prefix)
              (hard-fail! "tar extract failed")))]))

(define (sha256-hex path)
  (define sha (or (find-executable-path "sha256sum")
                  (find-executable-path "shasum")))
  (and sha
       (let ([args (if (regexp-match? #rx"shasum" (path->string sha))
                       (list "-a" "256" (path->string path))
                       (list (path->string path)))])
         (define-values (sp stdout stdin stderr)
           (apply subprocess #f #f 'stdout sha args))
         (define out (port->string stdout))
         (close-input-port stdout)
         (close-output-port stdin)
         (subprocess-wait sp)
         (and (zero? (subprocess-status sp))
              (let ([toks (string-split out)])
                (and (pair? toks) (string-downcase (car toks))))))))

(define (sums-expect-for sums-path tarball)
  (let loop ([lines (file->lines sums-path)])
    (cond
      [(null? lines) #f]
      [else
       (define parts (string-split (car lines)))
       (define name (and (>= (length parts) 2) (cadr parts)))
       (define name* (and name
                          (if (string-prefix? name "*")
                              (substring name 1)
                              name)))
       (if (and name* (equal? name* tarball))
           (string-downcase (car parts))
           (loop (cdr lines)))])))

;; Language-native download (curl+tar). HTTPS-only, required SHA256SUMS, extract
;; only extract_prefix/. Ships with the package; does not need the monorepo
;; operator shell helper. Callers pass version/target/cache-lib once — no
;; second walk.
(define (try-download-into-cache! contract version target cache-lib)
  (define base (or (getenv "PANCAKE_RELEASE_BASE_URL")
                   (hash-ref contract 'default_release_base_url)))
  (define tag (apply-contract-template
               (hash-ref contract 'release_tag_template)
               version target))
  (define tarball (apply-contract-template
                   (hash-ref contract 'tarball_template)
                   version target))
  (define extract-prefix (hash-ref contract 'extract_prefix))
  (define url (format "~a/~a/~a" base tag tarball))
  (define cache-root (path-only cache-lib))
  (define curl (find-executable-path "curl"))
  (define tar (find-executable-path "tar"))
  (define ua (hash-ref contract 'user_agent))
  (define max-bytes (hash-ref contract 'max_tarball_bytes))
  (define max-sums (hash-ref contract 'max_sums_bytes))
  (define (swallow-or-raise e)
    (cond
      [(exn:fail:pancake-hard? e) (raise e)]
      [(env-truthy? "PANCAKE_STRICT") (raise e)]
      [else (void)]))
  (define (under-lock!)
    (define marker (build-path cache-lib (ocapn-shared-marker contract)))
    (unless (file-exists? marker)
      (define tarball-path (build-path cache-root tarball))
      (eprintf "pancake: downloading ~a\n" url)
      (unless (curl-download curl url tarball-path ua max-bytes)
        (when (file-exists? tarball-path) (delete-file tarball-path))
        (soft-fail! (format "download failed: ~a" url)))
      (when (file-exists? tarball-path)
        (define sums-path (build-path cache-root "SHA256SUMS"))
        (define sums-url (format "~a/~a/SHA256SUMS" base tag))
        (unless (curl-download curl sums-url sums-path ua max-sums)
          (when (file-exists? tarball-path) (delete-file tarball-path))
          (when (file-exists? sums-path) (delete-file sums-path))
          (hard-fail! "checksum required before extract: SHA256SUMS download failed"))
        (when (file-exists? sums-path)
          (define expect (sums-expect-for sums-path tarball))
          (define got (sha256-hex tarball-path))
          (cond
            [(not expect)
             (when (file-exists? tarball-path) (delete-file tarball-path))
             (hard-fail! (format "SHA256SUMS has no entry for ~a" tarball))]
            [(not got)
             (when (file-exists? tarball-path) (delete-file tarball-path))
             (soft-fail! "sha256sum/shasum not on PATH; cannot verify C ABI tarball")]
            [(not (equal? got expect))
             (when (file-exists? tarball-path) (delete-file tarball-path))
             (hard-fail! (format "SHA256 mismatch for ~a" tarball))]
            [else
             (define stage (build-path cache-root (format "stage.~a" (current-seconds))))
             (when (directory-exists? stage)
               (delete-directory/files stage #:must-exist? #f))
             (make-directory* stage)
             (define untar-ok
               (safe-extract-prefix! tar tarball-path stage extract-prefix))
             (define extracted (build-path stage extract-prefix))
             (cond
               [(not untar-ok)
                ;; tar list soft-failed inside safe-extract-prefix!
                (void)]
               [(not (directory-exists? extracted))
                (hard-fail! (format "tarball missing ~a/" extract-prefix))]
               [else
                (when (directory-exists? cache-lib)
                  (delete-directory/files cache-lib #:must-exist? #f))
                (rename-file-or-directory extracted cache-lib)
                (when (directory-exists? stage)
                  (delete-directory/files stage #:must-exist? #f))])])))))
  (unless curl
    (soft-fail! "curl not on PATH; cannot download C ABI archives"))
  (unless tar
    (soft-fail! "tar not on PATH; cannot extract C ABI archives"))
  (when (and curl tar cache-root (require-https? base))
    (with-handlers ([exn:fail? swallow-or-raise])
      (make-directory* cache-root)
      (define lock-dir (build-path cache-root ".lock"))
      (let lock-loop ([n 0])
        (cond
          [(with-handlers ([exn:fail? (λ (_) #f)])
             (make-directory lock-dir) #t)
           (with-handlers ([exn:fail? swallow-or-raise])
             (under-lock!))
           (when (directory-exists? lock-dir)
             (delete-directory/files lock-dir #:must-exist? #f))]
          [(>= n 300)
           (soft-fail! (format "timed out waiting for cache lock at ~a" lock-dir))]
          [else (sleep 0.1) (lock-loop (add1 n))])))))

(define (zig-out-lib)
  ;; In-tree dogfood rung: discoverable pancake checkout → zig-out/lib.
  (define root (find-dev-root))
  (and root (build-path root "zig-out" "lib")))

(define (resolve-cache-lib! zig-out-dir)
  ;; Soft-fail download when the cache is cold (or when PANCAKE_DOWNLOAD=1
  ;; refreshes even with zig-out present, including when releases_published is
  ;; false). Returns the cache lib path when the shared-lib marker is present
  ;; afterwards, else #f.
  (define contract (load-contract))
  (define root (find-dev-root))
  (define version (resolve-abi-version contract root))
  (define target (host-target-triple))
  (define cache-lib (cache-lib-dir contract version target))
  (define marker (build-path cache-lib (ocapn-shared-marker contract)))
  (define zig-marker
    (and zig-out-dir (build-path zig-out-dir (ocapn-shared-marker contract))))
  (cond
    [(file-exists? marker) cache-lib]
    [(and zig-marker (file-exists? zig-marker) (env-truthy? "PANCAKE_DOWNLOAD"))
     (try-download-into-cache! contract version target cache-lib)
     (and (file-exists? marker) cache-lib)]
    [(or (not zig-marker) (not (file-exists? zig-marker)))
     (when (want-release-fetch? contract)
       (try-download-into-cache! contract version target cache-lib))
     (and (file-exists? marker) cache-lib)]
    [else #f]))

;; Publishable cascade (ADR-0077): configure first (never downloads), then
;; abi-versioned cache, then optional in-tree zig-out (find-dev-root), then bare
;; name. On Windows the shared archive is `{stem}.dll` (no `lib` prefix); refuse
;; bare DLL names (search-order plant risk), matching Python/TS.
(define (open-pancake-archive stem #:fail [fail #f])
  (define (try spec) (ffi-lib spec #:fail (lambda () #f)))
  (define name
    (case (system-type)
      [(windows) stem]
      [else (string-append "lib" stem)]))
  (define zig-out (zig-out-lib))
  (or (let ([dir (getenv "PANCAKE_LIB_DIR")])
        (and dir (try (build-path dir name))))
      (let ([cache-dir (resolve-cache-lib! zig-out)])
        (and cache-dir (try (build-path cache-dir name))))
      (and zig-out (try (build-path zig-out name)))
      (cond
        [(eq? (system-type) 'windows)
         (error 'pancake
                "could not resolve an absolute path for ~a; set PANCAKE_LIB_DIR or populate the abi-versioned cache (Windows refuses bare DLL names to avoid search-order plants)"
                name)]
        [else
         (eprintf "pancake: warning: loading bare ~a via the OS search path\n" name)
         (ffi-lib name #:fail
                  (or fail
                      (lambda ()
                        (error 'pancake
                               "could not load ~a from PANCAKE_LIB_DIR, the abi-versioned cache, zig-out/lib, or the system library path"
                               name))))])))
