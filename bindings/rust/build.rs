use std::path::PathBuf;

fn main() {
	let manifest_dir = PathBuf::from(std::env::var_os("CARGO_MANIFEST_DIR").unwrap());
	// bindings/rust/Cargo.toml -> repo root is two levels up.
	let root = manifest_dir.parent().unwrap().parent().unwrap();
	// Resolve the archive directory through the cascade every pancake binding
	// shares: an explicit `PANCAKE_LIB_DIR` override (configure) wins, else the
	// repo's `zig-out/lib` build output (the dev fallback). For Rust this is a
	// build-time search path — core/tcp/inproc link statically, so they need no
	// runtime lookup; only the iroh dylib carries it forward as an rpath below.
	println!("cargo:rerun-if-env-changed=PANCAKE_LIB_DIR");
	let lib_dir = match std::env::var_os("PANCAKE_LIB_DIR") {
		Some(dir) => PathBuf::from(dir),
		None => root.join("zig-out/lib"),
	};
	println!("cargo:rustc-link-search=native={}", lib_dir.display());

	// Relink when the native archives change, not only when Rust sources do.
	// Cargo does not track an externally-built `-l static` archive on its own, so
	// without this a Zig-only change (an engine fix with no binding edit) would
	// leave the dogfood linked against a stale `libpancake_ocapn.a` — a false
	// green or red that hides exactly the cross-language regressions the dogfood
	// exists to catch. Re-running build.rs on an archive's mtime forces the
	// relink. Listed by hand (no glob dependency) for the archives this build
	// links; a missing file is fine pre-build (the install step writes them).
	for archive in [
		"libpancake_ocapn.a",
		"libpancake_net_transport_tcp.a",
		"libpancake_net_transport_inproc.a",
	] {
		println!("cargo:rerun-if-changed={}", lib_dir.join(archive).display());
	}

	// The C ABI ships as à-la-carte archives (ADR-0059), each symbol-disjoint, so
	// a consumer links exactly the set its features enable and they compose with
	// no duplicate-symbol collision (the standing Model-A composition proof). The
	// core `libpancake_ocapn` carries the peer/value/event/uri families and is
	// always linked; each transport rides its own companion archive, linked only
	// when its Cargo feature is on. This is the link-line half of "no shipped
	// cost": a transport you do not enable contributes no archive and no symbol.
	println!("cargo:rustc-link-lib=static=pancake_ocapn");

	// The static blocking transports. The `tcp` and `inproc` features are on by
	// default, so the default build links the same set the dogfood always has.
	if cfg!(feature = "tcp") {
		println!("cargo:rustc-link-lib=static=pancake_net_transport_tcp");
	}
	if cfg!(feature = "inproc") {
		println!("cargo:rustc-link-lib=static=pancake_net_transport_inproc");
	}

	// The iroh transport ABI (`libpancake_net_transport_iroh`) is a dynamic
	// companion, not a superset: it exports only the `pancake_iroh_*` family and
	// shares no core symbol (ADR-0055), so the consumer adds it as a dynamic
	// library alongside the static core. It is shared, so the consumer also needs
	// an rpath to find it at run time.
	if cfg!(feature = "iroh") {
		println!("cargo:rustc-link-lib=dylib=pancake_net_transport_iroh");
		println!("cargo:rustc-link-arg=-Wl,-rpath,{}", lib_dir.display());
	}
}
