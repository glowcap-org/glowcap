use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::Deserialize;

mod archive_hygiene;
mod release_download;

#[derive(Debug, Deserialize)]
struct Contract {
	abi_version: String,
	default_release_base_url: String,
	tarball_template: String,
	release_tag_template: String,
	cache_layout: String,
	version_header: String,
	marker_static: String,
	user_agent: String,
	max_tarball_bytes: u64,
	max_sums_bytes: u64,
	extract_prefix: String,
	require_https: bool,
	require_checksum: bool,
}

fn load_contract() -> Contract {
	let raw = include_str!("c-abi-resolve.json");
	let contract: Contract = serde_json::from_str(raw).unwrap_or_else(|e| panic!("c-abi-resolve.json: {e}"));
	validate_contract(&contract);
	contract
}

fn main() {
	println!("cargo:rerun-if-env-changed=DOCS_RS");
	// Rustdoc needs declarations, not native libraries. docs.rs has no SDK
	// and forbids network access, so it must not enter archive resolution.
	if std::env::var_os("DOCS_RS").is_some() {
		return;
	}
	let manifest_dir = PathBuf::from(std::env::var_os("CARGO_MANIFEST_DIR").unwrap());
	println!("cargo:rerun-if-env-changed=GLOWCAP_LIB_DIR");
	println!("cargo:rerun-if-env-changed=GLOWCAP_DOWNLOAD");
	println!("cargo:rerun-if-env-changed=GLOWCAP_SKIP_DOWNLOAD");
	println!("cargo:rerun-if-env-changed=GLOWCAP_RELEASE_BASE_URL");
	for name in ["GLOWCAP_CACHE_DIR", "XDG_CACHE_HOME", "HOME", "USERPROFILE"] {
		println!("cargo:rerun-if-env-changed={name}");
	}
	println!("cargo:rerun-if-env-changed=GLOWCAP_STRICT");
	println!("cargo:rerun-if-env-changed=GLOWCAP_ALLOW_INSECURE");
	println!(
		"cargo:rerun-if-changed={}",
		manifest_dir.join("c-abi-resolve.json").display()
	);

	if std::env::var("TARGET").as_deref() == Ok("wasm32-unknown-unknown") {
		for feature in ["TCP", "INPROC", "ONION", "IROH", "WEBRTC", "RELAY"] {
			assert!(
				std::env::var_os(format!("CARGO_FEATURE_{feature}")).is_none(),
				"Rust Wasm uses embedder-owned byte channels; disable native transport feature {feature}"
			);
		}
		let directory = resolve_lib_dir(&manifest_dir)
			.unwrap_or_else(|| panic!("no Wasm library directory; set GLOWCAP_CACHE_DIR or GLOWCAP_LIB_DIR"));
		println!("cargo:rustc-link-search=native={}", directory.display());
		let archives = ["glowcap_host", "glowcap_ocapn"]
			.into_iter()
			.chain(cfg!(feature = "loam").then_some("glowcap_loam"));
		for archive in archives {
			let path = directory.join(format!("lib{archive}.a"));
			assert!(
				path.is_file(),
				"missing Wasm archive {}; check the library download or set GLOWCAP_LIB_DIR to an extracted archive's lib directory",
				path.display()
			);
			println!("cargo:rerun-if-changed={}", path.display());
			println!("cargo:rustc-link-lib=static={archive}");
		}
		return;
	}

	let lib_dir = resolve_lib_dir(&manifest_dir);
	if let Some(ref lib_dir) = lib_dir {
		println!("cargo:rustc-link-search=native={}", lib_dir.display());

		// Relink when the FFI archives change, not only when Rust sources do.
		for archive in [
			"libglowcap_ocapn.a",
			"libglowcap_host.a",
			"libglowcap_driver.a",
			"libglowcap_net_transport_tcp.a",
			"libglowcap_net_transport_inproc.a",
			"libglowcap_net_transport_onion.a",
			"libglowcap_net_transport_relay.a",
		] {
			println!("cargo:rerun-if-changed={}", lib_dir.join(archive).display());
		}
	}

	// Host semantics and transport execution are separate symbol families and
	// archives. The driver adopts a Host created through libglowcap_host.
	println!("cargo:rustc-link-lib=static=glowcap_driver");
	println!("cargo:rustc-link-lib=static=glowcap_host");
	println!("cargo:rustc-link-lib=static=glowcap_ocapn");

	if cfg!(feature = "loam") {
		println!("cargo:rustc-link-lib=static=glowcap_loam_lmdb");
		println!("cargo:rustc-link-lib=static=glowcap_loam_sqlite");
		println!("cargo:rustc-link-lib=static=glowcap_loam_volatile");
		println!("cargo:rustc-link-lib=static=glowcap_loam");
		if let Some(ref lib_dir) = lib_dir {
			for name in [
				"glowcap_loam",
				"glowcap_loam_lmdb",
				"glowcap_loam_sqlite",
				"glowcap_loam_volatile",
			] {
				println!(
					"cargo:rerun-if-changed={}",
					lib_dir.join(format!("lib{name}.a")).display()
				);
			}
		}
	}

	if cfg!(feature = "tcp") {
		println!("cargo:rustc-link-lib=static=glowcap_net_transport_tcp");
	}
	if cfg!(feature = "inproc") {
		println!("cargo:rustc-link-lib=static=glowcap_net_transport_inproc");
	}
	if cfg!(feature = "onion") {
		println!("cargo:rustc-link-lib=static=glowcap_net_transport_onion");
	}
	if cfg!(feature = "relay") {
		println!("cargo:rustc-link-lib=static=glowcap_net_transport_relay");
	}

	for (enabled, name) in [
		(cfg!(feature = "iroh"), "glowcap_net_transport_iroh"),
		(cfg!(feature = "webrtc"), "glowcap_net_transport_webrtc"),
	] {
		if enabled {
			println!("cargo:rustc-link-lib=dylib={name}");
			if let Some(ref lib_dir) = lib_dir {
				use std::env::consts::{DLL_PREFIX, DLL_SUFFIX};
				println!("cargo:rustc-link-arg=-Wl,-rpath,{}", lib_dir.display());
				println!(
					"cargo:rerun-if-changed={}",
					lib_dir.join(format!("{DLL_PREFIX}{name}{DLL_SUFFIX}")).display()
				);
			}
		}
	}
}

/// Cascade (ADR-0023): `GLOWCAP_LIB_DIR` → abi-versioned download cache →
/// optional target-specific in-tree libraries → (caller falls through to link failure).
fn resolve_lib_dir(manifest_dir: &Path) -> Option<PathBuf> {
	if let Some(dir) = std::env::var_os("GLOWCAP_LIB_DIR").filter(|value| !value.is_empty()) {
		return Some(PathBuf::from(dir));
	}

	let contract = load_contract();
	let dev_root = find_dev_root(manifest_dir);
	let version = abi_version(dev_root.as_deref(), &contract);
	let (target, checkout_lib) = sdk_target();
	let zig_out = dev_root.as_ref().map(|r| r.join(checkout_lib));
	let Some(cache_lib) = cache_lib_dir(&contract, &version, &target) else {
		return zig_out;
	};

	if cache_lib.join(&contract.marker_static).is_file() {
		return Some(cache_lib);
	}

	if want_release_fetch(dev_root.as_deref()) {
		let _ = fetch_into_cache(&contract, &version, &target, &cache_lib);
		if cache_lib.join(&contract.marker_static).is_file() {
			return Some(cache_lib);
		}
	}
	zig_out.or(Some(cache_lib))
}

/// Contract hygiene: hard-fail at load (parity with Python/TS/Racket), never
/// soft-fail mid-fetch for a corrupt embed.
fn validate_contract(contract: &Contract) {
	if !contract.require_https {
		panic!("c-abi-resolve.json: require_https must be true");
	}
	if !contract.require_checksum {
		panic!("c-abi-resolve.json: require_checksum must be true");
	}
}

fn env_truthy(name: &str) -> bool {
	match std::env::var(name) {
		Ok(v) => matches!(v.trim().to_ascii_lowercase().as_str(), "1" | "true" | "yes"),
		Err(_) => false,
	}
}

/// Cold-cache network gate: a package outside a checkout downloads its version
/// unless `GLOWCAP_SKIP_DOWNLOAD`. A checkout downloads only with `GLOWCAP_DOWNLOAD`.
fn want_release_fetch(dev_root: Option<&Path>) -> bool {
	if dev_root.is_none() {
		!env_truthy("GLOWCAP_SKIP_DOWNLOAD")
	} else {
		env_truthy("GLOWCAP_DOWNLOAD")
	}
}

fn apply_contract_template(tmpl: &str, version: &str, target: &str, cache_base: &str) -> String {
	tmpl.replace("{cache_base}", cache_base)
		.replace("{version}", version)
		.replace("{target}", target)
}

fn abi_version(dev_root: Option<&Path>, contract: &Contract) -> String {
	if let Some(root) = dev_root {
		let header = root.join(&contract.version_header);
		if let Ok(text) = fs::read_to_string(&header) {
			let major = macro_u32(&text, "GLOWCAP_VERSION_MAJOR").unwrap_or(0);
			let minor = macro_u32(&text, "GLOWCAP_VERSION_MINOR").unwrap_or(1);
			let patch = macro_u32(&text, "GLOWCAP_VERSION_PATCH").unwrap_or(0);
			return format!("{major}.{minor}.{patch}");
		}
	}
	contract.abi_version.clone()
}

fn macro_u32(text: &str, name: &str) -> Option<u32> {
	for line in text.lines() {
		let trimmed = line.trim();
		let prefix = format!("#define {name} ");
		if let Some(rest) = trimmed.strip_prefix(&prefix) {
			return rest.trim().parse().ok();
		}
	}
	None
}

fn sdk_target() -> (String, &'static str) {
	// Host cfg names match c-sdk-pack. Browser Wasm maps to the one portable
	// library target, regardless of the machine Cargo runs on.
	let arch = std::env::var("CARGO_CFG_TARGET_ARCH").unwrap_or_else(|_| "unknown".into());
	let os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_else(|_| "unknown".into());
	if arch == "wasm32" && os == "unknown" {
		("wasm32-freestanding".into(), "zig-out/wasm/lib")
	} else {
		(format!("{arch}-{os}"), "zig-out/lib")
	}
}

fn find_dev_root(start: &Path) -> Option<PathBuf> {
	let mut cur = Some(start);
	while let Some(dir) = cur {
		if dir.join("build.zig").is_file() && dir.join("include/glowcap_ocapn.h").is_file() {
			return Some(dir.to_path_buf());
		}
		cur = dir.parent();
	}
	None
}

fn cache_base() -> Option<PathBuf> {
	if let Some(dir) = std::env::var_os("GLOWCAP_CACHE_DIR").filter(|value| !value.is_empty()) {
		return Some(PathBuf::from(dir));
	}
	for (name, suffix) in [
		("XDG_CACHE_HOME", "glowcap/c-abi"),
		("HOME", ".cache/glowcap/c-abi"),
		("USERPROFILE", ".cache/glowcap/c-abi"),
	] {
		if let Some(base) = std::env::var_os(name).map(PathBuf::from).filter(|p| p.is_absolute()) {
			return Some(base.join(suffix));
		}
	}
	None
}

fn cache_lib_dir(contract: &Contract, version: &str, target: &str) -> Option<PathBuf> {
	let base = cache_base()?;
	Some(PathBuf::from(apply_contract_template(
		&contract.cache_layout,
		version,
		target,
		&base.to_string_lossy(),
	)))
}

fn soft_fail(msg: &str) -> Result<(), String> {
	eprintln!("glowcap build.rs: {msg} (soft-fail)");
	if env_truthy("GLOWCAP_STRICT") {
		panic!("glowcap build.rs: {msg}");
	}
	Err(msg.to_string())
}

/// Hygiene/security failures always fail closed (never gated on STRICT).
fn hard_fail(msg: &str) -> ! {
	panic!("glowcap build.rs: {msg}");
}

fn require_https(base: &str) {
	if base.starts_with("https://") || env_truthy("GLOWCAP_ALLOW_INSECURE") {
		return;
	}
	hard_fail(&format!("refusing non-HTTPS release base URL: {base}"));
}

fn curl_tls_args(url: &str) -> Vec<&'static str> {
	if env_truthy("GLOWCAP_ALLOW_INSECURE") && !url.starts_with("https://") {
		return Vec::new();
	}
	vec!["--proto", "=https", "--tlsv1.2"]
}

fn fetch_into_cache(contract: &Contract, version: &str, target: &str, cache_lib: &Path) -> Result<(), String> {
	let base = std::env::var("GLOWCAP_RELEASE_BASE_URL").unwrap_or_else(|_| contract.default_release_base_url.clone());
	require_https(&base);
	let tag = apply_contract_template(&contract.release_tag_template, version, target, "");
	let tarball = apply_contract_template(&contract.tarball_template, version, target, "");
	let url = format!("{base}/{tag}/{tarball}");
	let cache_root = cache_lib.parent().unwrap();
	fs::create_dir_all(cache_root).map_err(|e| e.to_string())?;

	let lock_dir = cache_root.join(".lock");
	let mut waited = 0;
	while fs::create_dir(&lock_dir).is_err() {
		waited += 1;
		if waited > 300 {
			return soft_fail("timed out waiting for cache lock");
		}
		std::thread::sleep(std::time::Duration::from_millis(100));
	}
	let _guard = std::mem::DropGuard::new(lock_dir, |dir| {
		let _ = fs::remove_dir(dir);
	});

	if cache_lib.join(&contract.marker_static).is_file() {
		return Ok(());
	}

	let tarball_path = cache_root.join(&tarball);
	eprintln!("glowcap build.rs: downloading {url}");
	let downloaded = release_download::download(
		&url,
		&tarball_path,
		&contract.user_agent,
		contract.max_tarball_bytes,
		&curl_tls_args(&url),
	)
	.map_err(|e| format!("curl: {e}"))?;
	if !downloaded {
		let _ = fs::remove_file(&tarball_path);
		return soft_fail(&format!("download failed: {url}"));
	}

	let sums_url = format!("{base}/{tag}/SHA256SUMS");
	let sums_path = cache_root.join("SHA256SUMS");
	let sums_ok = release_download::download(
		&sums_url,
		&sums_path,
		&contract.user_agent,
		contract.max_sums_bytes,
		&curl_tls_args(&sums_url),
	)
	.unwrap_or(false);
	if !sums_ok {
		let _ = fs::remove_file(&tarball_path);
		let _ = fs::remove_file(&sums_path);
		hard_fail("checksum required before extract: SHA256SUMS download failed");
	}
	let sums_text = fs::read_to_string(&sums_path).unwrap_or_default();
	let mut expect: Option<String> = None;
	for line in sums_text.lines() {
		let mut parts = line.split_whitespace();
		if let (Some(hash), Some(name)) = (parts.next(), parts.next())
			&& name.trim_start_matches('*') == tarball
		{
			expect = Some(hash.to_ascii_lowercase());
			break;
		}
	}
	let Some(want) = expect else {
		let _ = fs::remove_file(&tarball_path);
		hard_fail(&format!("SHA256SUMS has no entry for {tarball}"));
	};
	let got = {
		let sha256sum = Command::new("sha256sum").arg(&tarball_path).output();
		if let Ok(out) = sha256sum {
			if out.status.success() {
				String::from_utf8_lossy(&out.stdout)
					.split_whitespace()
					.next()
					.unwrap_or("")
					.to_ascii_lowercase()
			} else {
				String::new()
			}
		} else {
			String::new()
		}
	};
	let got = if got.is_empty() {
		let out = Command::new("shasum")
			.args(["-a", "256"])
			.arg(&tarball_path)
			.output()
			.map_err(|e| format!("shasum: {e}"))?;
		if !out.status.success() {
			let _ = fs::remove_file(&tarball_path);
			return soft_fail("could not hash tarball");
		}
		String::from_utf8_lossy(&out.stdout)
			.split_whitespace()
			.next()
			.unwrap_or("")
			.to_ascii_lowercase()
	} else {
		got
	};
	if got != want {
		let _ = fs::remove_file(&tarball_path);
		hard_fail(&format!("SHA256 mismatch for {tarball}"));
	}

	let nanos = SystemTime::now()
		.duration_since(UNIX_EPOCH)
		.map(|d| d.as_nanos())
		.unwrap_or(0);
	let stage = cache_root.join(format!("stage.{nanos}"));
	let _ = fs::remove_dir_all(&stage);
	fs::create_dir_all(&stage).map_err(|e| e.to_string())?;
	if let Err(msg) = safe_extract_prefix(&tarball_path, &stage, &contract.extract_prefix) {
		let _ = fs::remove_dir_all(&stage);
		// tar list failure is tooling (soft); refuse/extract already hard_fail inside.
		return soft_fail(&msg);
	}
	let extracted_lib = stage.join(&contract.extract_prefix);
	if !extracted_lib.is_dir() {
		let _ = fs::remove_dir_all(&stage);
		hard_fail(&format!("tarball missing {}/", contract.extract_prefix));
	}
	let _ = fs::remove_dir_all(cache_lib);
	fs::rename(&extracted_lib, cache_lib).map_err(|e| e.to_string())?;
	let _ = fs::remove_dir_all(&stage);
	Ok(())
}

/// List members, reject traversal/links under extract_prefix, then extract.
/// Refuse/link and extract failures hard-fail. tar list failure returns Err
/// (tooling soft-fail at the caller).
fn safe_extract_prefix(tarball: &Path, stage: &Path, prefix: &str) -> Result<(), String> {
	// One environment for both tar calls below. `TAR_OPTIONS` would otherwise
	// let the listing and the extract see different archives: flags that hide
	// a member from validation, then admit it at extract.
	let listing = Command::new("tar")
		.args(["--numeric-owner", "-tvzf"])
		.arg(tarball)
		.env("LC_ALL", "C")
		.env_remove("TAR_OPTIONS")
		.output()
		.map_err(|e| format!("tar list: {e}"))?;
	if !listing.status.success() {
		return Err("tar list failed".into());
	}
	if let Some(violation) = archive_hygiene::listing_violation(&String::from_utf8_lossy(&listing.stdout), prefix) {
		hard_fail(&violation);
	}
	let status = Command::new("tar")
		.args(["-xzf"])
		.arg(tarball)
		.arg("-C")
		.arg(stage)
		.arg("--no-same-owner")
		.arg(prefix)
		.env("LC_ALL", "C")
		.env_remove("TAR_OPTIONS")
		.status()
		.map_err(|e| format!("tar: {e}"))?;
	if !status.success() {
		hard_fail("tar extract failed");
	}
	Ok(())
}
