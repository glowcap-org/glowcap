# Per-arch SHA-256 for pinned toolchain downloads. Versions live in pins.sh.
# Call only after pins.sh is sourced (racket_tarball_and_sha256 uses RACKET_VERSION).

# Keyed on OS-arch, not arch alone: the release workflow installs the same
# pinned Zig on macOS runners through install-zig.sh, so the macOS tarballs
# are pinned here beside the Linux ones.
zig_sha256() {
    case "$(uname -s)-$(uname -m)" in
        Linux-x86_64) echo "70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00" ;;
        Linux-aarch64) echo "ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17" ;;
        Darwin-arm64) echo "b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489" ;;
        Darwin-x86_64) echo "0387557ed1877bc6a2e1802c8391953baddba76081876301c522f52977b52ba7" ;;
        *)
            echo "zig_sha256: unsupported platform: $(uname -s)-$(uname -m)" >&2
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
        x86_64) echo "c24f955d9fbfe0ea5ae2b501c8e71ae76e31e4c9782390a54a284b3364fda725" ;;
        aarch64) echo "111da5c05c240cfdc4340f234a0e3539d39dbcb6755221f19dcd60bacc8be5aa" ;;
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
        x86_64) echo "aab924fd522efd06f1c5f3b93a243864fc453132c94b2dc49f1371b528a4b967" ;;
        aarch64) echo "4d4fa08d95b06642e5800df6a22bd71455f23f988269e18da2847971d8c0bf31" ;;
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
