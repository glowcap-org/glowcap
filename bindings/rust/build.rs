use std::path::PathBuf;

fn main() {
    let manifest_dir = PathBuf::from(std::env::var_os("CARGO_MANIFEST_DIR").unwrap());
    // bindings/rust/Cargo.toml -> repo root is two levels up.
    let root = manifest_dir.parent().unwrap().parent().unwrap();
    let lib_dir = root.join("zig-out/lib");
    println!("cargo:rustc-link-search=native={}", lib_dir.display());

    // The iroh feature links the iroh public C ABI superset (`libpancake_iroh`),
    // which carries the whole `libpancake` surface plus the iroh family, so it
    // replaces plain `libpancake` rather than adding to it (ADR-0055). It is a
    // shared library (the bindings dlopen it elsewhere), so the consumer needs an
    // rpath to find it at run time. Without the feature the binding links plain
    // static `libpancake`, exactly as the dogfood always has.
    if cfg!(feature = "iroh") {
        println!("cargo:rustc-link-lib=dylib=pancake_iroh");
        println!("cargo:rustc-link-arg=-Wl,-rpath,{}", lib_dir.display());
    } else {
        println!("cargo:rustc-link-lib=static=pancake");
    }
}
