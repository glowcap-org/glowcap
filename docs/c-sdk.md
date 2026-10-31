---
type: static
audience: human
description: Extract the C SDK and compile a program against its headers and libraries.
sources:
  - resource: /include/glowcap_ocapn.h
  - resource: /tools/build/release.zig
---

# Use the C SDK

The `glowcap-c-vVERSION-ARCH-OS.tar.gz` download contains C headers and
libraries for applications and language bindings. For the command line,
Rooms, browser assets, and agent skills, choose the `glowcap-vVERSION-ARCH-OS.tar.gz`
product instead. Both are on the [release page](https://github.com/glowcap-org/glowcap/releases).

Choose the archive for your operating system and processor. `aarch64-macos`
is Apple Silicon, and `x86_64-macos` is Intel. The Linux archives need glibc
2.39 or newer, and the macOS archives need macOS 15 or newer.
Verify the download using the checksum and attestation instructions on its
release page, then extract it into an empty directory named `glowcap-sdk`.

The extracted SDK contains:

| Path | Contents |
| --- | --- |
| `include/` | Public C headers |
| `lib/` | Static archives and shared libraries |
| `share/glowcap/release.json` | Version, target, minimum runtime, and source revision |
| `PROVENANCE.md`, `LICENSE-*` | Project provenance and license terms |

## Compile a program

You need a C compiler. Set `sdk` to the absolute path of the extracted SDK:

```sh
sdk="$PWD/glowcap-sdk"
cat > version.c <<'C'
#include <stdint.h>
#include <stdio.h>
#include "glowcap_ocapn.h"

int main(void) {
    uint32_t major, minor, patch;
    glowcap_abi_version(&major, &minor, &patch);
    printf("%u.%u.%u\n", major, minor, patch);
    return 0;
}
C
cc -I"$sdk/include" version.c -L"$sdk/lib" \
  -Wl,-rpath,"$sdk/lib" -lglowcap_ocapn -o version
./version
```

The program prints the SDK's ABI version. The rpath lets the operating
system find the shared library at the SDK's absolute path. If you move or ship
your application, arrange a library path for that installation.

Each archive has its own header. Link the libraries your application uses.
The [C ABI guide](https://github.com/glowcap-org/glowcap/blob/main/docs/consuming-from-c.md)
explains ownership and calling conventions, and the
[C examples](https://github.com/glowcap-org/glowcap/tree/main/examples/c)
show complete conversations.

## Use a language binding

Point `GLOWCAP_LIB_DIR` at this SDK's absolute `lib` directory, then follow
your language's [binding guide](https://github.com/glowcap-org/glowcap/tree/main/bindings).
For Rust, this selects libraries at build time. Shared iroh and WebRTC
libraries also need the operating system's runtime library search configured.

See the [packaging guide](https://github.com/glowcap-org/glowcap/blob/main/bindings/PACKAGING.md)
for download behavior and library resolution.
