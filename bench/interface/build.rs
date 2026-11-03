fn main() {
	println!("cargo:rerun-if-env-changed=GLOWCAP_INTERFACE_MARKS");
	let path = std::env::var("GLOWCAP_INTERFACE_MARKS").expect("build through zig build bench-interface");
	println!("cargo:rerun-if-changed={path}");
	println!("cargo:rustc-link-arg={path}");
}
