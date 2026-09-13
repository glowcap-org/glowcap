# shellcheck shell=bash
# Per-arch SHA-256 for pinned toolchain downloads. Versions live in pins.sh.
# Call only after pins.sh is sourced (racket_tarball_and_sha256 uses RACKET_VERSION).
#
# Single-value functions select through lib.sh's glowcap_pick_by_arch: x86_64 first,
# then aarch64. Zig keys on OS-arch instead, and Racket returns a
# tarball-and-hash pair, so each keeps its own case.

# Keyed on OS-arch, not arch alone: the release workflow installs the same
# pinned Zig on macOS runners through image/zig.sh, so the macOS tarballs
# are pinned here beside the Linux ones.
zig_sha256() {
    case "$(uname -s)-$(uname -m)" in
        Linux-x86_64) echo "719f5612fddb58eefc33735696e3b53400f2794e2b5324796dc4f94e12fd5f05" ;;
        Linux-aarch64) echo "c53b05c16fca9c85558be58f541ae16f87f36715b902ed679bdd0dc60135036d" ;;
        Darwin-arm64) echo "5b8ed7c7cde2877db157ac2544170461ee0eaf38235a68f51907e9bc111182af" ;;
        Darwin-x86_64) echo "46e5c668d4a03feeb92f88476cc5aeb7a95a9902251ae5c70268907357df397b" ;;
        *)
            echo "zig_sha256: unsupported platform: $(uname -s)-$(uname -m)" >&2
            return 1
            ;;
    esac
}

deno_sha256() {
    glowcap_pick_by_arch deno_sha256 \
        "394f07f4da2bebe6ce6f1e7ce0fa16429b29b08c35e3fac3fe25972676dff4b2" \
        "9a46afc6c392c7cd2ff71a31558935545b46408d0e87f7a86908c712721c046e"
}

node_sha256() {
    glowcap_pick_by_arch node_sha256 \
        "40e1d3225c1c9ae9a2671c98ecb9857e4d5555026394f348645676798840d5c5" \
        "81d8f0fdea9dcd3bfdcfeafc5f8359c151f097e9880b0007c0645ca670d07971"
}

bun_sha256() {
    glowcap_pick_by_arch bun_sha256 \
        "36368faef7527875d5ffa52e53cd48021741f2a83eb6208a8dd64068d422a913" \
        "54328bbc2d9c8e0c9f892c544d66c57a83b84139e34909e5ee81758f1ac8fda7"
}

# Published beside each rustup-init binary as its .sha256 file, e.g.
# https://static.rust-lang.org/rustup/archive/<ver>/x86_64-unknown-linux-gnu/rustup-init.sha256
rustup_init_sha256() {
    glowcap_pick_by_arch rustup_init_sha256 \
        "dda7234360b7f578ca8b0ddcb80145646fa61a67c1720a5abc7051b35c9fcb71" \
        "15f6e4ce9f583b929c996c91562bad6d4454f3281de858b02cdfdef615fac433"
}

opencode_sha256() {
    glowcap_pick_by_arch opencode_sha256 \
        "55007246858165496ff85ba1c2b648f7421e8e2013bf4189a680c9ff8e699d17" \
        "4111a55c2a02c0fac314bd51e9a2330280e6d29d2b85b9554fff6d62612566ed"
}

cursor_agent_sha256() {
    glowcap_pick_by_arch cursor_agent_sha256 \
        "27997c8391ad853a5a732b1845db8ef82a8ba6afb0f7829cc739464f8966e96e" \
        "e0494438b01c37bc34848491d1f3478ef469494c56caf020de11796d146db64a"
}

uv_sha256() {
    glowcap_pick_by_arch uv_sha256 \
        "745765a3b6e360ad76743599ae5c42e9278c7edf8bbff9fc76d05bf2623a04dd" \
        "2eaa5d94f5db7b3a1a092156b9420459e42ab0217d917fe74a876309cef9b5e9"
}

racket_tarball_and_sha256() {
    case "$(uname -m)" in
        x86_64)
            echo "racket-minimal-${RACKET_VERSION}-x86_64-linux-buster-cs.tgz"
            echo "8f469b7e93645fc876594470d884775aafff7688f530fd38be873fb44c71ca6a"
            ;;
        aarch64)
            echo "racket-minimal-${RACKET_VERSION}-aarch64-linux-buster-cs.tgz"
            echo "221a1f77ba11ab090ec5ff77c5a95abfe1f72d3b8b879d694fc5d807567015be"
            ;;
        *)
            echo "racket_tarball_and_sha256: unsupported architecture: $(uname -m)" >&2
            return 1
            ;;
    esac
}
