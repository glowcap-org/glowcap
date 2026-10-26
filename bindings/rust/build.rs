use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::Deserialize;

mod archive_hygiene;

#[derive(Debug, Deserialize)]
struct Contract {
	abi_version: String,
	default_release_base_url: String,
	tarball_template: String,
	release_tag_template: String,
	cache_layout: String,
	version_header: String,
	fallback_cache_name: String,
	marker_static: String,
	user_agent: String,
	max_tarball_bytes: u64,
	max_sums_bytes: u64,
	extract_prefix: String,
	require_https: bool,
	require_checksum: bool,
	releases_published: bool,
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
	println!("cargo:rerun-if-env-changed=GLOWCAP_CACHE_DIR");
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
		let directory = std::env::var_os("GLOWCAP_LIB_DIR")
			.map(PathBuf::from)
			.or_else(|| find_dev_root(&manifest_dir).map(|root| root.join("zig-out/wasm/lib")))
			.expect("set GLOWCAP_LIB_DIR to the wasm32 glowcap archives");
		println!("cargo:rustc-link-search=native={}", directory.display());
		for archive in ["glowcap_host", "glowcap_ocapn"] {
			let path = directory.join(format!("lib{archive}.a"));
			assert!(
				path.is_file(),
				"missing Wasm archive {}; run zig build wasm-archives",
				path.display()
			);
			println!("cargo:rerun-if-changed={}", path.display());
			println!("cargo:rustc-link-lib=static={archive}");
		}
		if cfg!(feature = "loam") {
			println!("cargo:rustc-link-lib=static=glowcap_loam");
			println!(
				"cargo:rerun-if-changed={}",
				directory.join("libglowcap_loam.a").display()
			);
		}
		return;
	}

	let lib_dir = resolve_lib_dir(&manifest_dir);
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

	if cfg!(feature = "iroh") {
		println!("cargo:rustc-link-lib=dylib=glowcap_net_transport_iroh");
		println!("cargo:rustc-link-arg=-Wl,-rpath,{}", lib_dir.display());
		#[cfg(target_os = "macos")]
		println!(
			"cargo:rerun-if-changed={}",
			lib_dir.join("libglowcap_net_transport_iroh.dylib").display()
		);
		#[cfg(target_os = "linux")]
		println!(
			"cargo:rerun-if-changed={}",
			lib_dir.join("libglowcap_net_transport_iroh.so").display()
		);
		#[cfg(target_os = "windows")]
		println!(
			"cargo:rerun-if-changed={}",
			lib_dir.join("glowcap_net_transport_iroh.dll").display()
		);
	}

	if cfg!(feature = "webrtc") {
		println!("cargo:rustc-link-lib=dylib=glowcap_net_transport_webrtc");
		println!("cargo:rustc-link-arg=-Wl,-rpath,{}", lib_dir.display());
		#[cfg(target_os = "macos")]
		println!(
			"cargo:rerun-if-changed={}",
			lib_dir.join("libglowcap_net_transport_webrtc.dylib").display()
		);
		#[cfg(target_os = "linux")]
		println!(
			"cargo:rerun-if-changed={}",
			lib_dir.join("libglowcap_net_transport_webrtc.so").display()
		);
		#[cfg(target_os = "windows")]
		println!(
			"cargo:rerun-if-changed={}",
			lib_dir.join("glowcap_net_transport_webrtc.dll").display()
		);
	}
}
/// Cascade (ADR-0023): `GLOWCAP_LIB_DIR` → abi-versioned download cache →
/// optional in-tree `zig-out/lib` → (caller falls through to link failure).
fn resolve_lib_dir(manifest_dir: &Path) -> PathBuf {
	if let Some(dir) = std::env::var_os("GLOWCAP_LIB_DIR") {
		return PathBuf::from(dir);
	}

	let contract = load_contract();
	let dev_root = find_dev_root(manifest_dir);
	let version = abi_version(dev_root.as_deref(), &contract);
	let target = host_target_triple();
	let cache_lib = cache_lib_dir(&contract, &version, &target);
	let zig_out = dev_root.as_ref().map(|r| r.join("zig-out/lib"));

	if cache_lib.join(&contract.marker_static).is_file() {
		return cache_lib;
	}

	if let Some(ref zig) = zig_out
		&& zig.join(&contract.marker_static).is_file()
	{
		// GLOWCAP_DOWNLOAD refreshes the cache even when zig-out exists,
		// including when releases_published is false.
		if env_truthy("GLOWCAP_DOWNLOAD") {
			let _ = fetch_into_cache(&contract, &version, &target, &cache_lib);
			if cache_lib.join(&contract.marker_static).is_file() {
				return cache_lib;
			}
		}
		return zig.clone();
	}

	if want_release_fetch(&contract) {
		let _ = fetch_into_cache(&contract, &version, &target, &cache_lib);
		if cache_lib.join(&contract.marker_static).is_file() {
			return cache_lib;
		}
	}

	zig_out.unwrap_or(cache_lib)
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

/// Cold-cache network gate: when `releases_published` is true, fetch unless
/// `GLOWCAP_SKIP_DOWNLOAD`. When false, fetch only if `GLOWCAP_DOWNLOAD`.
fn want_release_fetch(contract: &Contract) -> bool {
	if contract.releases_published {
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

fn host_target_triple() -> String {
	// CARGO_CFG_TARGET_ARCH/OS already match zig build release-pack names
	// (x86_64, aarch64, macos, linux, windows). Other ports normalize host
	// aliases: see tools/c-abi/c-abi-host-aliases.json.
	let arch = std::env::var("CARGO_CFG_TARGET_ARCH").unwrap_or_else(|_| "unknown".into());
	let os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_else(|_| "unknown".into());
	format!("{arch}-{os}")
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

fn cache_base(contract: &Contract) -> PathBuf {
	if let Some(dir) = std::env::var_os("GLOWCAP_CACHE_DIR") {
		return PathBuf::from(dir);
	}
	if let Some(xdg) = std::env::var_os("XDG_CACHE_HOME") {
		return PathBuf::from(xdg).join("glowcap/c-abi");
	}
	if let Some(home) = std::env::var_os("HOME").or_else(|| std::env::var_os("USERPROFILE")) {
		return PathBuf::from(home).join(".cache/glowcap/c-abi");
	}
	std::env::temp_dir().join(&contract.fallback_cache_name)
}

fn cache_lib_dir(contract: &Contract, version: &str, target: &str) -> PathBuf {
	let base = cache_base(contract);
	PathBuf::from(apply_contract_template(
		&contract.cache_layout,
		version,
		target,
		&base.to_string_lossy(),
	))
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
	struct LockGuard(PathBuf);
	impl Drop for LockGuard {
		fn drop(&mut self) {
			let _ = fs::remove_dir(&self.0);
		}
	}
	let _guard = LockGuard(lock_dir);

	if cache_lib.join(&contract.marker_static).is_file() {
		return Ok(());
	}

	let tarball_path = cache_root.join(&tarball);
	eprintln!("glowcap build.rs: downloading {url}");
	let max_s = contract.max_tarball_bytes.to_string();
	let mut curl_args: Vec<&str> = vec!["-fsSL"];
	curl_args.extend(curl_tls_args(&url));
	curl_args.extend(["--max-filesize", &max_s, "-A", &contract.user_agent, "-o"]);
	let status = Command::new("curl")
		.args(&curl_args)
		.arg(&tarball_path)
		.arg(&url)
		.status()
		.map_err(|e| format!("curl: {e}"))?;
	if !status.success() {
		let _ = fs::remove_file(&tarball_path);
		return soft_fail(&format!("download failed: {url}"));
	}

	let sums_url = format!("{base}/{tag}/SHA256SUMS");
	let sums_path = cache_root.join("SHA256SUMS");
	let max_sums_s = contract.max_sums_bytes.to_string();
	let mut sums_args: Vec<&str> = vec!["-fsSL"];
	sums_args.extend(curl_tls_args(&sums_url));
	sums_args.extend(["--max-filesize", &max_sums_s, "-A", &contract.user_agent, "-o"]);
	let sums_ok = Command::new("curl")
		.args(&sums_args)
		.arg(&sums_path)
		.arg(&sums_url)
		.status()
		.map(|s| s.success())
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
