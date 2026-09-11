fn main() {
	// Every installed executable finds the optional transport companion beside
	// the rest of glowcap, without a per-binary list or machine-specific paths.
	let loader = match std::env::var("CARGO_CFG_TARGET_OS").as_deref() {
		Ok("linux") => "$ORIGIN/../lib",
		Ok("macos") => "@loader_path/../lib",
		_ => return,
	};
	println!("cargo:rustc-link-arg-bins=-Wl,-rpath,{loader}");
}
