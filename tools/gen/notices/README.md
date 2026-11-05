---
type: static
description: How release packages carry the notices for their selected Rust and JavaScript dependencies.
sources:
  - resource: /tools/gen/dependency_notices.py
  - resource: /tools/gen/notices/graphs.py
  - resource: /tools/build/release/stage.zig
---

# Distributed dependency notices

Release staging writes `share/glowcap/DEPENDENCY-NOTICES.txt` before sealing
or archiving a product. It contains original license and notice texts for the
Rust and JavaScript dependencies selected by the staged artifacts.
`LICENSE-THIRD-PARTY` owns the separately maintained Zig and font notices.

Cargo supplies the selected package's graph for the host target or the browser
Wasm target, with normal and build edges and the build's default features.
Development-only dependencies are excluded. Build dependencies remain because
macros and generators can emit shipped code. Cargo's graph can conservatively
include code the linker removes.

Vite supplies the JavaScript package inventory from emitted chunks. Deno
supplies those packages' fetched source directories. Type packages and build
tools absent from the bundle are excluded. Notice files inside a package retain
their relative paths, so a bundled library's notice does not become the parent
package's license.

The generator copies license, copying, copyright, and notice files, including
files under license directories. A package's declared license file also counts.
It refuses missing or empty texts. It does not derive copyright notices from
SPDX identifiers or decide whether a license is acceptable to the project.

## Missing upstream files

Some published crates omit their monorepo's license files. `supplements.json`
connects exact package versions and source revisions to original upstream text
under `licenses/`. Each file has its source URL and SHA-256 digest. A changed
version, revision, or file requires a fresh review.

The crc32c supplement retains its README's license grant and the source notice
for its Zlib-derived combine implementation. The enum-assoc supplement retains
its published manifest's dual-license declaration. Both select the offered
Apache-2.0 alternative and include its full terms. Their pinned repositories
contain no standalone license files. These package-specific records do not
establish clearance for unrelated code.

When a new dependency has no notice text, packaging fails. Inspect its exact
published source and upstream revision before adding a supplement. Preserve
applicable notice files as well as license terms. Do not substitute a generic
license for an unknown copyright notice.

The generator's fixture tests prove selection, preserved text and attribution,
and refusal of missing, stale, or corrupt supplements. Release checks require
the generated document in both product and SDK archives. This mechanism checks
notice delivery, not exhaustive legal compliance or license compatibility.
