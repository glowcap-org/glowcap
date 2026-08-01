use std::path::PathBuf;

fn main() {
	// The `iroh` feature pulls in the shared `libpancake_net_transport_iroh` (the
	// iroh C ABI companion library). The `pancake` binding's build script links
	// both the static C ABI archives and dynamic `libpancake_net_transport_iroh` —
	// those propagate to this binary — but its rpath
	// `rustc-link-arg` does not cross the crate boundary, so this example sets its
	// own rpath to `zig-out/lib` and runs without `LD_LIBRARY_PATH`. The TCP
	// default links the static C ABI archives and needs nothing here.
	if cfg!(feature = "iroh") {
		let manifest_dir = PathBuf::from(std::env::var_os("CARGO_MANIFEST_DIR").unwrap());
		// apps/rooms/clients/rust -> repo root is four levels up.
		let root = manifest_dir.ancestors().nth(4).unwrap();
		let lib_dir = root.join("zig-out/lib");
		println!("cargo:rustc-link-arg=-Wl,-rpath,{}", lib_dir.display());
	}
}
