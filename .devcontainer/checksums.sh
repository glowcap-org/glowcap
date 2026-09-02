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
        Linux-x86_64) echo "d9202688fc47f931fd64cc77b198412b070b21a3669d00ec469b58df35501e7d" ;;
        Linux-aarch64) echo "39a83fad0c86ddfb947c597b5d0fb72536254f06772b8f6b4464c22cfb94a047" ;;
        Darwin-arm64) echo "bde1e44e56610410142d6fcf45925bf94ea31000c5c3a7b6ee95839e7d26c44e" ;;
        Darwin-x86_64) echo "d2279bff3e09e19473877a96906295145ce237db25278ac53896d279d25cd6e4" ;;
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
        "3e301118d7df53d563b7e96c1617545f26e2f76f9724be668d6cab65c15dda5d" \
        "23c1b4d19e2f12a7d06fe8aa3d6e0e4923cf77a47e13c5ccdf32fadaa33960f2"
}

bun_sha256() {
    glowcap_pick_by_arch bun_sha256 \
        "2d03fb5fb83ac8b567aca0a281b2ce1a1a19d488f56c2968d88c3f25e92fe452" \
        "4b1a332ee861983eb93bcfe6f770fff94e3e31b2c388bdaea3c8ed35e58eed0e"
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
        "7c20c1ffa91bcca0ac903752260bcc36307dff656833baead2f5ef3b224b16c6" \
        "90b99cc2356fea188d67352418ad7223559841178142f719848ca2c88a689c3e"
}

cursor_agent_sha256() {
    glowcap_pick_by_arch cursor_agent_sha256 \
        "7e306db5750219a99c00ed517fe8b235d3c54e4ca5f77e2ff160cc97ce707798" \
        "cf5db6b5047b3280d8a49471cfd41beb1d5e475774177df5df2851857ab6514a"
}

uv_sha256() {
    glowcap_pick_by_arch uv_sha256 \
        "ec7a99cd05e0cd7f80243f135ce1361c76835cb0ee60055d14d20eba8eba1460" \
        "c36fe17937ff6bd16dc42fc13854b5465999fcab2efe0af559381e945e3c6001"
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
