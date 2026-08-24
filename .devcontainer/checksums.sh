# shellcheck shell=bash
# Per-arch SHA-256 for pinned toolchain downloads. Versions live in pins.sh.
# Call only after pins.sh is sourced (racket_tarball_and_sha256 uses RACKET_VERSION).
#
# Single-value functions select through lib.sh's pancake_pick_by_arch: x86_64 first,
# then aarch64. Zig keys on OS-arch instead, and Racket returns a
# tarball-and-hash pair, so each keeps its own case.

# Keyed on OS-arch, not arch alone: the release workflow installs the same
# pinned Zig on macOS runners through image/zig.sh, so the macOS tarballs
# are pinned here beside the Linux ones.
zig_sha256() {
    case "$(uname -s)-$(uname -m)" in
        Linux-x86_64) echo "0825e4a55baf4a6647c3ce3077a7236c9ffec5b17e1ca0102a930fe33d631bc6" ;;
        Linux-aarch64) echo "fc1899b14953c8561b0dc0be57c846e27723981b49446dbe32d74c342bb93764" ;;
        Darwin-arm64) echo "7f8b084a7fd776a93bb45df36ee966402d260c955f2ea567ba7bde6f38e94ad1" ;;
        Darwin-x86_64) echo "90468141517363cfb93c9aea18c3733ad4534f5abf71188bf8a10f42bff4e3bd" ;;
        *)
            echo "zig_sha256: unsupported platform: $(uname -s)-$(uname -m)" >&2
            return 1
            ;;
    esac
}

deno_sha256() {
    pancake_pick_by_arch deno_sha256 \
        "8b010a3b1a4a0188a67cdb8a7a27348b2a501af78aec7fc74f2ace167368d530" \
        "6b7cae3a8fc4385a59dea3146fcb8bad7fea4230e0ad36a8c692afacbc254be0"
}

node_sha256() {
    pancake_pick_by_arch node_sha256 \
        "982aa24dd8be4c889c6a8ab337ddff3b0896645b20f4239356e80552c16277ee" \
        "afc7a004018485092ac8985b817b0d5684472bd9472e0b57d2ab88737e50090d"
}

bun_sha256() {
    pancake_pick_by_arch bun_sha256 \
        "2d03fb5fb83ac8b567aca0a281b2ce1a1a19d488f56c2968d88c3f25e92fe452" \
        "4b1a332ee861983eb93bcfe6f770fff94e3e31b2c388bdaea3c8ed35e58eed0e"
}

# Published beside each rustup-init binary as its .sha256 file, e.g.
# https://static.rust-lang.org/rustup/archive/<ver>/x86_64-unknown-linux-gnu/rustup-init.sha256
rustup_init_sha256() {
    pancake_pick_by_arch rustup_init_sha256 \
        "4acc9acc76d5079515b46346a485974457b5a79893cfb01112423c89aeb5aa10" \
        "9732d6c5e2a098d3521fca8145d826ae0aaa067ef2385ead08e6feac88fa5792"
}

opencode_sha256() {
    pancake_pick_by_arch opencode_sha256 \
        "d910c3ed7613bb5791a328904615d41cc25b7d3a6b470e3199ab0426a995b38a" \
        "d30d2cba74617f4e7b96e25563c9572ffe453f9eae70fc0df16286813537ee72"
}

cursor_agent_sha256() {
    pancake_pick_by_arch cursor_agent_sha256 \
        "bfff4bf6f4e9dd30c1d0ef0a70b6077b074015dd2948e4c50685d53afdcfce5a" \
        "ea13f92e295f523a99ce8d8f57d6894d21e5d1e2d030ffad718ccd5955ca2eed"
}

uv_sha256() {
    pancake_pick_by_arch uv_sha256 \
        "68a509da24b06b4223a1c0175fb5eb5bc79342b76cbeff0cfe51ac3f5b17b6b2" \
        "9bf43b4d1a07665bf64d4c4e710930b382321a785e0eb10aac07f46471f86a31"
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
