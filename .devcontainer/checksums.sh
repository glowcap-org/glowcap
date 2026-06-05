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
        x86_64) echo "184da7a5267ab649bc08821b3bc3ce6805d8e6985fb82707cb8d5e9fd6535362" ;;
        aarch64) echo "48647189aee6454ed9b9852fa700a77f92b39465c04c625901d165bc8e937afc" ;;
        *)
            echo "deno_sha256: unsupported architecture: $(uname -m)" >&2
            return 1
            ;;
    esac
}

node_sha256() {
    case "$(uname -m)" in
        x86_64) echo "0ce210831380ab75a5fec0d3fb6b5af0958898016b2cae51cc2fa11057d2f77e" ;;
        aarch64) echo "392f291d00c74644f35ec0325cd03d9d4f5a627c926213fbd05167c0cba9f977" ;;
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
        x86_64) echo "7035608168e106375b36d0c818d537a889c51a8625fe7f8f7cad5e62b947c368" ;;
        aarch64) echo "83b13ab184a45b7d9a3b0e4b10eaebd50ad41e66cb16dcce8e60aa7be13ae399" ;;
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
