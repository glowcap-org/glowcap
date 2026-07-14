# Per-arch SHA-256 for pinned toolchain downloads. Versions live in pins.sh.
# Call only after pins.sh is sourced (racket_tarball_and_sha256 uses RACKET_VERSION).

zig_sha256() {
    case "$(uname -m)" in
        x86_64) echo "70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00" ;;
        aarch64) echo "ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17" ;;
        *)
            echo "zig_sha256: unsupported architecture: $(uname -m)" >&2
            return 1
            ;;
    esac
}

zls_sha256() {
    case "$(uname -m)" in
        x86_64) echo "ded6d562a0b86ee878b1ddf70ffab2797ce3cdca3b02d6077548f9d56dff96b6" ;;
        aarch64) echo "430cd293d201eb70ae2519dbc96c854bf8791b8df7fc9392e8d2dc9680a2bed7" ;;
        *)
            echo "zls_sha256: unsupported architecture: $(uname -m)" >&2
            return 1
            ;;
    esac
}

deno_sha256() {
    case "$(uname -m)" in
        x86_64) echo "934d1bd5cb09eaed7f2e4a4fc58208d04a3c5c0fcde9f319d93d735265c67a4a" ;;
        aarch64) echo "310b8f48e59964ff18890d35e64f64fb90e8b1cc5d9ebff8c818327d5afb16d2" ;;
        *)
            echo "deno_sha256: unsupported architecture: $(uname -m)" >&2
            return 1
            ;;
    esac
}

node_sha256() {
    case "$(uname -m)" in
        x86_64) echo "9f619528f1db5ddc41dccf54211066fb42228d69a156733c69cb9d6cc92e358c" ;;
        aarch64) echo "036df0b49662ebb350eb56f1cac603699b1e9ed1e2603ee129fefda473479030" ;;
        *)
            echo "node_sha256: unsupported architecture: $(uname -m)" >&2
            return 1
            ;;
    esac
}

bun_sha256() {
    case "$(uname -m)" in
        x86_64) echo "951ee2aee855f08595aeec6225226a298d3fea83a3dcd6465c09cbccdf7e848f" ;;
        aarch64) echo "a27ffb63a8310375836e0d6f668ae17fa8d8d18b88c37c821c65331973a19a3b" ;;
        *)
            echo "bun_sha256: unsupported architecture: $(uname -m)" >&2
            return 1
            ;;
    esac
}

uv_sha256() {
    case "$(uname -m)" in
        x86_64) echo "e490a6464492183c5d4534a5527fb4440f7f2bb2f228162ad7e4afe076dc0224" ;;
        aarch64) echo "03e9fe0a81b0718d0bc84625de3885df6cc3f89a8b6af6121d6b9f6113fb6533" ;;
        *)
            echo "uv_sha256: unsupported architecture: $(uname -m)" >&2
            return 1
            ;;
    esac
}

racket_tarball_and_sha256() {
    case "$(uname -m)" in
        x86_64)
            echo "racket-minimal-${RACKET_VERSION}-x86_64-linux-buster-cs.tgz"
            echo "84d2c34c0ba7b4f206b5b4f0ce9e8127c153a55f65b0dbd2bdd9b1e2091b6822"
            ;;
        aarch64)
            echo "racket-minimal-${RACKET_VERSION}-aarch64-linux-buster-cs.tgz"
            echo "0e572088e3d5e1b51b198d602bd25380e176a03921e22a02828ad3df71bdd1ce"
            ;;
        *)
            echo "racket_tarball_and_sha256: unsupported architecture: $(uname -m)" >&2
            return 1
            ;;
    esac
}
