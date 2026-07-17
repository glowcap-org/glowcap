use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::Deserialize;

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
	let contract: Contract =
		serde_json::from_str(raw).unwrap_or_else(|e| panic!("c-abi-resolve.json: {e}"));
	validate_contract(&contract);
	contract
}

fn main() {
	let manifest_dir = PathBuf::from(std::env::var_os("CARGO_MANIFEST_DIR").unwrap());
	println!("cargo:rerun-if-env-changed=PANCAKE_LIB_DIR");
	println!("cargo:rerun-if-env-changed=PANCAKE_DOWNLOAD");
	println!("cargo:rerun-if-env-changed=PANCAKE_SKIP_DOWNLOAD");
	println!("cargo:rerun-if-env-changed=PANCAKE_RELEASE_BASE_URL");
	println!("cargo:rerun-if-env-changed=PANCAKE_CACHE_DIR");
	println!("cargo:rerun-if-env-changed=PANCAKE_STRICT");
	println!("cargo:rerun-if-env-changed=PANCAKE_ALLOW_INSECURE");
	println!(
		"cargo:rerun-if-changed={}",
		manifest_dir.join("c-abi-resolve.json").display()
	);

	let lib_dir = resolve_lib_dir(&manifest_dir);
	println!("cargo:rustc-link-search=native={}", lib_dir.display());

	// Relink when the native archives change, not only when Rust sources do.
	for archive in [
		"libpancake_ocapn.a",
		"libpancake_driver.a",
		"libpancake_net_transport_tcp.a",
		"libpancake_net_transport_inproc.a",
	] {
		println!("cargo:rerun-if-changed={}", lib_dir.join(archive).display());
	}

	println!("cargo:rustc-link-lib=static=pancake_driver");
	println!("cargo:rustc-link-lib=static=pancake_ocapn");

	if cfg!(feature = "tcp") {
		println!("cargo:rustc-link-lib=static=pancake_net_transport_tcp");
	}
	if cfg!(feature = "inproc") {
		println!("cargo:rustc-link-lib=static=pancake_net_transport_inproc");
	}

	if cfg!(feature = "iroh") {
		println!("cargo:rustc-link-lib=dylib=pancake_net_transport_iroh");
		println!("cargo:rustc-link-arg=-Wl,-rpath,{}", lib_dir.display());
		#[cfg(target_os = "macos")]
		println!(
			"cargo:rerun-if-changed={}",
			lib_dir
				.join("libpancake_net_transport_iroh.dylib")
				.display()
		);
		#[cfg(target_os = "linux")]
		println!(
			"cargo:rerun-if-changed={}",
			lib_dir.join("libpancake_net_transport_iroh.so").display()
		);
		#[cfg(target_os = "windows")]
		println!(
			"cargo:rerun-if-changed={}",
			lib_dir.join("pancake_net_transport_iroh.dll").display()
		);
	}
}

/// Cascade (ADR-0077): `PANCAKE_LIB_DIR` → abi-versioned download cache →
/// optional in-tree `zig-out/lib` → (caller falls through to link failure).
fn resolve_lib_dir(manifest_dir: &Path) -> PathBuf {
	if let Some(dir) = std::env::var_os("PANCAKE_LIB_DIR") {
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

	if let Some(ref zig) = zig_out {
		if zig.join(&contract.marker_static).is_file() {
			// PANCAKE_DOWNLOAD refreshes the cache even when zig-out exists,
			// including when releases_published is false.
			if env_truthy("PANCAKE_DOWNLOAD") {
				let _ = fetch_into_cache(&contract, &version, &target, &cache_lib);
				if cache_lib.join(&contract.marker_static).is_file() {
					return cache_lib;
				}
			}
			return zig.clone();
		}
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
/// `PANCAKE_SKIP_DOWNLOAD`; when false, fetch only if `PANCAKE_DOWNLOAD`.
fn want_release_fetch(contract: &Contract) -> bool {
	if contract.releases_published {
		!env_truthy("PANCAKE_SKIP_DOWNLOAD")
	} else {
		env_truthy("PANCAKE_DOWNLOAD")
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
			let major = macro_u32(&text, "PANCAKE_VERSION_MAJOR").unwrap_or(0);
			let minor = macro_u32(&text, "PANCAKE_VERSION_MINOR").unwrap_or(1);
			let patch = macro_u32(&text, "PANCAKE_VERSION_PATCH").unwrap_or(0);
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
	// aliases — see tools/c-abi/c-abi-host-aliases.json.
	let arch = std::env::var("CARGO_CFG_TARGET_ARCH").unwrap_or_else(|_| "unknown".into());
	let os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_else(|_| "unknown".into());
	format!("{arch}-{os}")
}

fn find_dev_root(start: &Path) -> Option<PathBuf> {
	let mut cur = Some(start);
	while let Some(dir) = cur {
		if dir.join("build.zig").is_file() && dir.join("include/pancake_ocapn.h").is_file() {
			return Some(dir.to_path_buf());
		}
		cur = dir.parent();
	}
	None
}

fn cache_base(contract: &Contract) -> PathBuf {
	if let Some(dir) = std::env::var_os("PANCAKE_CACHE_DIR") {
		return PathBuf::from(dir);
	}
	if let Some(xdg) = std::env::var_os("XDG_CACHE_HOME") {
		return PathBuf::from(xdg).join("pancake/c-abi");
	}
	if let Some(home) = std::env::var_os("HOME").or_else(|| std::env::var_os("USERPROFILE")) {
		return PathBuf::from(home).join(".cache/pancake/c-abi");
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
	eprintln!("pancake build.rs: {msg} (soft-fail)");
	if env_truthy("PANCAKE_STRICT") {
		panic!("pancake build.rs: {msg}");
	}
	Err(msg.to_string())
}

/// Hygiene/security failures always fail closed (never gated on STRICT).
fn hard_fail(msg: &str) -> ! {
	panic!("pancake build.rs: {msg}");
}

fn require_https(base: &str) {
	if base.starts_with("https://") || env_truthy("PANCAKE_ALLOW_INSECURE") {
		return;
	}
	hard_fail(&format!("refusing non-HTTPS release base URL: {base}"));
}

fn curl_tls_args(url: &str) -> Vec<&'static str> {
	if env_truthy("PANCAKE_ALLOW_INSECURE") && !url.starts_with("https://") {
		return Vec::new();
	}
	vec!["--proto", "=https", "--tlsv1.2"]
}

fn fetch_into_cache(
	contract: &Contract,
	version: &str,
	target: &str,
	cache_lib: &Path,
) -> Result<(), String> {
	let base = std::env::var("PANCAKE_RELEASE_BASE_URL")
		.unwrap_or_else(|_| contract.default_release_base_url.clone());
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
	eprintln!("pancake build.rs: downloading {url}");
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
	sums_args.extend([
		"--max-filesize",
		&max_sums_s,
		"-A",
		&contract.user_agent,
		"-o",
	]);
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
		if let (Some(hash), Some(name)) = (parts.next(), parts.next()) {
			if name.trim_start_matches('*') == tarball {
				expect = Some(hash.to_ascii_lowercase());
				break;
			}
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
/// Refuse/link and extract failures hard-fail; tar list failure returns Err
/// (tooling soft-fail at the caller).
fn safe_extract_prefix(tarball: &Path, stage: &Path, prefix: &str) -> Result<(), String> {
	let listing = Command::new("tar")
		.args(["-tvzf"])
		.arg(tarball)
		.output()
		.map_err(|e| format!("tar list: {e}"))?;
	if !listing.status.success() {
		return Err("tar list failed".into());
	}
	let prefix_slash = format!("{prefix}/");
	for line in String::from_utf8_lossy(&listing.stdout).lines() {
		if line.is_empty() {
			continue;
		}
		let kind = line.as_bytes()[0];
		let name = tar_tv_name(line);
		if name != prefix && !name.starts_with(&prefix_slash) {
			continue;
		}
		if name.starts_with('/') || name.split('/').any(|p| p == "..") {
			hard_fail(&format!("refusing unsafe tar member: {name}"));
		}
		if kind == b'l' || kind == b'h' {
			hard_fail(&format!("refusing link tar member: {name}"));
		}
	}
	let status = Command::new("tar")
		.args(["-xzf"])
		.arg(tarball)
		.arg("-C")
		.arg(stage)
		.arg("--no-same-owner")
		.arg(prefix)
		.status()
		.map_err(|e| format!("tar: {e}"))?;
	if !status.success() {
		hard_fail("tar extract failed");
	}
	Ok(())
}

fn tar_tv_name(line: &str) -> String {
	let without_link = line.split(" -> ").next().unwrap_or(line);
	let parts: Vec<&str> = without_link.split_whitespace().collect();
	if parts.len() >= 8 {
		parts[7..].join(" ")
	} else if let Some(last) = parts.last() {
		(*last).to_string()
	} else {
		String::new()
	}
}
