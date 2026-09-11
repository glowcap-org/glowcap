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
        Linux-x86_64) echo "e07d5330e46420c56bf6c725fa4aed655292dcce3286d6d77c64e6bdaf90e307" ;;
        Linux-aarch64) echo "6a8c495c2ade9ad50c825bcdd4af97858e901b297f3a02d62db1e06fa4707298" ;;
        Darwin-arm64) echo "b3cfd2744a79c35860e6c0994804b5f21e882a644ccd92a4988c0b7cbe04641f" ;;
        Darwin-x86_64) echo "7d5cf0363c2e921f41e8cb5e28f5406f70ece8d16b91ed53ab759769f4ad488b" ;;
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
        "0d7a11dd01b652b8b92d05cc14f769fbc5a3442b786cd8b636041f189ab81f1e" \
        "153ae182db90814748d544f2a26abc073e4e4e5df0b867abfd69def0ff77aa71"
}

uv_sha256() {
    glowcap_pick_by_arch uv_sha256 \
        "ab9b309d4586403f024e100abaceb396616e178a553e2500c36087d180f09509" \
        "fe08db50cc1b56cd1da7801065ed1103d27ed3f9571cd122386cfc7faf1b8df5"
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
