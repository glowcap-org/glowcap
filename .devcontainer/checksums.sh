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
        Linux-x86_64) echo "a303125386ca689512de4a001cc8c140468e97e300d8d10ffae1587ec5c08933" ;;
        Linux-aarch64) echo "fe804b078f68ed531764193a9b5b705ee9a4d9feba0ed5c1bca978df2c1b6b57" ;;
        Darwin-arm64) echo "2c01d07e0c5c7f761ab9cedbfe8f75f5769679f8317d82817fc927d0c63f37e7" ;;
        Darwin-x86_64) echo "a77996335301fb304070e35cab0a06e3908485ec4b4d289ae3a8c3412a1404c5" ;;
        *)
            echo "zig_sha256: unsupported platform: $(uname -s)-$(uname -m)" >&2
            return 1
            ;;
    esac
}

deno_sha256() {
    glowcap_pick_by_arch deno_sha256 \
        "c6527f24f4b16031d3ae4fa9f658d5f11534c8d84ce7dc8502420280919c3490" \
        "c832298b1ad4422481334855f6003e0f54145762c5a134f20a489511d2f65bbf"
}

node_sha256() {
    glowcap_pick_by_arch node_sha256 \
        "ca70e9e349de048b9522abb3adc05b3bd6f43c5ffd3ec57916c7da292f59f022" \
        "7a6353f63eb3d04765004b4adf172616243e4522434635cb1d26288658b04ab5"
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
        "3046e0404fdc60fb80307e7a47824ba07477364178a4d09baa8548496dd6d43b" \
        "568461b7d4d8c19865c97e9a1102e613049c6039d01fe772154de873c1865840"
}

cursor_agent_sha256() {
    glowcap_pick_by_arch cursor_agent_sha256 \
        "740dd9d6eb5aec36ca90eaedf9fd5e2c489cd674d69b5147b3c2670f02d9776d" \
        "38d1482c945172926e780206fce8cc51c67dd4f96162bcec680903aa70d80417"
}

uv_sha256() {
    glowcap_pick_by_arch uv_sha256 \
        "23bf5552d220e0842b65c862097b2ebaeba0064b74eda5e565e77fd25969d8c8" \
        "0804e9b164c64b6914182d5920c08551958a095986f10a3731056df701126436"
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
