use std::path::PathBuf;

fn main() {
    let manifest_dir = PathBuf::from(std::env::var_os("CARGO_MANIFEST_DIR").unwrap());
    // bindings/rust/Cargo.toml -> repo root is two levels up.
    let root = manifest_dir.parent().unwrap().parent().unwrap();
    println!(
        "cargo:rustc-link-search=native={}",
        root.join("zig-out/lib").display()
    );
    println!("cargo:rustc-link-lib=static=pancake");
}
