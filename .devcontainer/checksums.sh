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
        x86_64) echo "710c54d63477d1100844ef4818f19507ce0dbf40510903b1d883f19e394446a2" ;;
        aarch64) echo "0a60d079fa79635a59803074dbbfe86ccc35746dc2c4f8d73f2e50338b3283a9" ;;
        *)
            echo "deno_sha256: unsupported architecture: $(uname -m)" >&2
            return 1
            ;;
    esac
}

node_sha256() {
    case "$(uname -m)" in
        x86_64) echo "5c4286dcd5bbd5acb1ccc7eb0e088bd5eb1e3affad671ee9364004f8f6a4a431" ;;
        aarch64) echo "f6d8eedc52170667d45730ac2f413c4aa1e7cd2165c9cac5746ef3cb0f4ec45a" ;;
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
        x86_64) echo "6426a73c3837e6e2483ee344cbc00f36394d179afcba6183cb77437e67db4af0" ;;
        aarch64) echo "befa1a59c91e96eb601b0fd9a97c03dd666f17baba644b2b4db9c59a767e387e" ;;
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
