// Internal: how every archive loader finds its shared library.
//
// glowcap ships its C ABI as à-la-carte archives (ADR-0059), one per concern,
// and each loader under this folder opens exactly one of them through the
// runtime FFI seam. This module holds the one piece they all share: resolving a
// built archive's path. Nothing here is public.
//
// Publishable cascade (ADR-0077; see `c-abi-resolve.json` and
// `bindings/README.md`):
//   1. `GLOWCAP_LIB_DIR` (configure) — never downloads.
//   2. Abi-versioned download cache — language-native fetch (HTTP + tar) that
//      ships inside this package; no monorepo operator shell helper required.
//   3. In-tree `zig-out/lib` when a glowcap checkout is discoverable (dev only).
//   4. Bare library name (OS dynamic-linker search).
//
// Deno without `--allow-env` / `--allow-read` / `--allow-net` / `--allow-write`
// / `--allow-run` degrades to the next rung instead of failing.

import { injected_adapter_key } from "./runtime.ts";
import { archiveListingViolation } from "./archive_hygiene.ts";
import { libFile } from "./surface.ts";
import { curlTransportArgs, failArchiveSecurity, HardFailError, requireSecureReleaseUrl } from "./release_security.ts";

// The host built-ins the cascade rides. Static imports (not top-level await)
// so this module ships no top-level await — a browser bundle flattens every
// module's top-level await into one file and the runtime's import graph
// deadlocks around one. A browser build maps these `node:*` specifiers to
// empty stubs (`bindings/ts/web/browser-bundle.json`); the injected-adapter
// guard below sets `host` to null there, so the stubs are imported but never
// used. Under Deno and Bun they resolve to the real built-ins.
import nodeProcess from "node:process";
import * as nodeFs from "node:fs";
import * as nodeCrypto from "node:crypto";
import * as nodePath from "node:path";
import * as nodeUrl from "node:url";
import * as nodeChildProcess from "node:child_process";

// The shape of the host built-ins the cascade rides. Under the wasm adapter
// (ADR-0070) `dlopen` ignores paths entirely, so `libPath` returns the bare
// stem and none of these are touched; Deno and Bun use the real built-ins,
// and every rung below keeps its synchronous shape.
type HostModules = {
	process: typeof import("node:process");
	fs: typeof import("node:fs");
	crypto: typeof import("node:crypto");
	path: typeof import("node:path");
	url: typeof import("node:url");
	childProcess: typeof import("node:child_process");
};

// An injected adapter (the wasm browser binding, ADR-0070) means `dlopen`
// ignores paths and there is no archive cascade to run, so `host` is null and
// the stubbed `node:*` imports above are never touched. Deno and Bun get the
// real built-ins. No top-level await — see the import note above.
const host: HostModules | null = (globalThis as Record<symbol, unknown>)[injected_adapter_key] !== undefined ? null : {
	process: nodeProcess,
	fs: nodeFs,
	crypto: nodeCrypto,
	path: nodePath,
	url: nodeUrl,
	childProcess: nodeChildProcess,
};

// Call-syntax aliases for the cascade's rungs. Every use sits beneath
// `libPath`'s browser early-return, so a null host can never reach one.
function hostOnly(): never {
	throw new Error("glowcap archive resolution needs a host runtime (Deno/Bun)");
}
const process = host?.process ??
	({
		env: {} as Record<string, string | undefined>,
		arch: "",
		platform: "",
		pid: 0,
	} as unknown as typeof import("node:process"));
const existsSync = host?.fs.existsSync ?? hostOnly;
const mkdirSync = host?.fs.mkdirSync ?? hostOnly;
const readFileSync = host?.fs.readFileSync ?? hostOnly;
const renameSync = host?.fs.renameSync ?? hostOnly;
const rmdirSync = host?.fs.rmdirSync ?? hostOnly;
const rmSync = host?.fs.rmSync ?? hostOnly;
const statSync = host?.fs.statSync ?? hostOnly;
const createHash = host?.crypto.createHash ?? hostOnly;
const dirname = host?.path.dirname ?? hostOnly;
const join = host?.path.join ?? hostOnly;
const fileURLToPath = host?.url.fileURLToPath ?? hostOnly;
const spawnSync = host?.childProcess.spawnSync ?? hostOnly;

const syncWaitCell: Int32Array | null = typeof SharedArrayBuffer === "function" && typeof Atomics.wait === "function"
	? new Int32Array(new SharedArrayBuffer(4))
	: null;

function sleepSync(ms: number): boolean {
	if (syncWaitCell != null) {
		try {
			Atomics.wait(syncWaitCell, 0, 0, ms);
			return true;
		} catch {
			// Some embedders expose SharedArrayBuffer but forbid blocking waits on
			// this thread. The archive loader is synchronous by contract, so the
			// caller degrades to the next archive-resolution rung rather than
			// burning CPU.
		}
	}
	return false;
}

function envGranted(variable: string): boolean {
	const deno = (globalThis as {
		Deno?: {
			permissions?: {
				querySync(d: { name: "env"; variable: string }): { state: string };
			};
		};
	}).Deno;
	if (deno?.permissions?.querySync) {
		return deno.permissions.querySync({ name: "env", variable }).state ===
			"granted";
	}
	return true;
}

function envVar(name: string): string | null {
	if (!envGranted(name)) return null;
	try {
		const v = process.env[name];
		return v !== undefined && v.length > 0 ? v : null;
	} catch {
		return null;
	}
}

function envTruthy(name: string): boolean {
	const v = envVar(name);
	if (v === null) return false;
	const lower = v.trim().toLowerCase();
	return lower === "1" || lower === "true" || lower === "yes";
}

type Contract = {
	abi_version: string;
	default_release_base_url: string;
	tarball_template: string;
	release_tag_template: string;
	cache_layout: string;
	version_header: string;
	fallback_cache_name: string;
	marker_shared_stem: string;
	user_agent: string;
	max_tarball_bytes: number;
	max_sums_bytes: number;
	extract_prefix: string;
	require_https: boolean;
	require_checksum: boolean;
	releases_published: boolean;
};

function packageDir(): string {
	return dirname(fileURLToPath(import.meta.url));
}

let cachedContract: Contract | null = null;

function requireField<T>(
	raw: Record<string, unknown>,
	key: keyof Contract,
): T {
	if (!(key in raw) || raw[key as string] === undefined || raw[key as string] === null) {
		throw new Error(`c-abi-resolve.json missing required field ${String(key)}`);
	}
	return raw[key as string] as T;
}

function loadContract(): Contract {
	if (cachedContract !== null) return cachedContract;
	const path = join(packageDir(), "c-abi-resolve.json");
	const raw = JSON.parse(readFileSync(path, "utf8")) as Record<string, unknown>;
	cachedContract = {
		abi_version: requireField(raw, "abi_version"),
		default_release_base_url: requireField(raw, "default_release_base_url"),
		tarball_template: requireField(raw, "tarball_template"),
		release_tag_template: requireField(raw, "release_tag_template"),
		cache_layout: requireField(raw, "cache_layout"),
		version_header: requireField(raw, "version_header"),
		fallback_cache_name: requireField(raw, "fallback_cache_name"),
		marker_shared_stem: requireField(raw, "marker_shared_stem"),
		user_agent: requireField(raw, "user_agent"),
		max_tarball_bytes: requireField(raw, "max_tarball_bytes"),
		max_sums_bytes: requireField(raw, "max_sums_bytes"),
		extract_prefix: requireField(raw, "extract_prefix"),
		require_https: requireField(raw, "require_https"),
		require_checksum: requireField(raw, "require_checksum"),
		releases_published: requireField(raw, "releases_published"),
	};
	if (cachedContract.require_https !== true) {
		throw new Error("c-abi-resolve.json: require_https must be true");
	}
	if (cachedContract.require_checksum !== true) {
		throw new Error("c-abi-resolve.json: require_checksum must be true");
	}
	if (typeof cachedContract.releases_published !== "boolean") {
		throw new Error("c-abi-resolve.json: releases_published must be a bool");
	}
	return cachedContract;
}

/** Cold-cache network gate from contract `releases_published`. */
function wantReleaseFetch(contract: Contract): boolean {
	if (contract.releases_published) {
		return !envTruthy("GLOWCAP_SKIP_DOWNLOAD");
	}
	return envTruthy("GLOWCAP_DOWNLOAD");
}

function applyContractTemplate(
	tmpl: string,
	version: string,
	target: string,
	cacheBasePath = "",
): string {
	return tmpl
		.replaceAll("{version}", version)
		.replaceAll("{target}", target)
		.replaceAll("{cache_base}", cacheBasePath);
}

function findDevRoot(): string | null {
	let dir: string | null = packageDir();
	while (dir !== null) {
		try {
			if (
				existsSync(join(dir, "build.zig")) &&
				existsSync(join(dir, "include/glowcap_ocapn.h"))
			) {
				return dir;
			}
		} catch { /* no read permission */ }
		const parent = dirname(dir);
		if (parent === dir) break;
		dir = parent;
	}
	return null;
}

function abiVersion(devRoot: string | null, contract: Contract): string {
	if (devRoot !== null) {
		try {
			const text = readFileSync(join(devRoot, contract.version_header), "utf8");
			const macro = (name: string, fallback: number): number => {
				const m = text.match(new RegExp(`^#define\\s+${name}\\s+(\\d+)\\s*$`, "m"));
				return m ? Number(m[1]) : fallback;
			};
			return `${macro("GLOWCAP_VERSION_MAJOR", 0)}.${macro("GLOWCAP_VERSION_MINOR", 1)}.${
				macro("GLOWCAP_VERSION_PATCH", 0)
			}`;
		} catch { /* fall through to contract pin */ }
	}
	return contract.abi_version;
}

function hostTargetTriple(): string {
	// Host aliases → zig build release-pack triples
	// (`tools/c-abi/c-abi-host-aliases.json`). Full corpus (string literals for
	// source_check per-port presence): "x86_64" "amd64" "x64" "aarch64" "arm64"
	// "macos" "darwin" "macosx" "Darwin" "linux" "Linux" "windows" "win32".
	// Node uses x64; others use amd64 — map both to x86_64.
	const archRaw: string = process.arch;
	const arch = archRaw === "x64" || archRaw === "amd64"
		? "x86_64"
		: archRaw === "arm64" || archRaw === "aarch64"
		? "aarch64"
		: archRaw;
	// darwin / Darwin / macosx → macos; linux / Linux → linux; win32 → windows.
	const platformRaw: string = process.platform;
	const zigOs = platformRaw === "darwin" || platformRaw === "macosx"
		? "macos"
		: platformRaw === "win32"
		? "windows"
		: platformRaw === "linux"
		? "linux"
		: platformRaw;
	return `${arch}-${zigOs}`;
}

function cacheBase(contract: Contract): string | null {
	const override = envVar("GLOWCAP_CACHE_DIR");
	if (override !== null) return override;
	const xdg = envVar("XDG_CACHE_HOME");
	if (xdg !== null) return join(xdg, "glowcap/c-abi");
	const home = envVar("HOME");
	if (home !== null) return join(home, ".cache/glowcap/c-abi");
	const tmp = envVar("TMPDIR");
	if (tmp !== null) return join(tmp, contract.fallback_cache_name);
	return null;
}

function cacheLibDir(
	contract: Contract,
	version: string,
	target: string,
): string | null {
	const base = cacheBase(contract);
	if (base === null) return null;
	return applyContractTemplate(contract.cache_layout, version, target, base);
}

function softFail(msg: string): void {
	if (envTruthy("GLOWCAP_STRICT")) {
		throw new Error(msg);
	}
	console.error(`glowcap: ${msg} (soft-fail)`);
}

function curlDownload(
	url: string,
	dest: string,
	userAgent: string,
	maxBytes: number,
): boolean {
	const args = [
		"-fsSL",
		...curlTransportArgs(url, envTruthy("GLOWCAP_ALLOW_INSECURE")),
		"--max-filesize",
		String(maxBytes),
		"-A",
		userAgent,
		"-o",
		dest,
		url,
	];
	return spawnSync("curl", args, { stdio: "ignore" }).status === 0;
}

/** List members, reject traversal/links under extract_prefix, then extract.
 * Refuse/link and extract failures hard-fail; tar list failure returns false
 * (tooling soft-fail at the caller).
 *
 * Exported so the C-ABI extract matrix can run this exact path — the listing
 * and the extract, with the environment this function builds — against
 * untrusted archives. Counting the environment's spelling in the source cannot
 * show that the environment reaching both subprocesses is the one intended. */
export function safeExtractPrefix(
	tarballPath: string,
	stage: string,
	prefix: string,
): boolean {
	// A minimal environment for both tar calls below. Spreading `process.env`
	// enumerates every variable, which Deno refuses under a scoped
	// `--allow-env`, and this module promises to degrade rather than throw.
	// `LC_ALL` is what the shared validator's two accepted layouts are
	// defined in.
	//
	// `TAR_OPTIONS` is neutralized by name rather than by omission. Node
	// replaces the environment when `env` is given, but Deno's compatibility
	// layer merges it with the parent's, so an untrusted `TAR_OPTIONS` survived
	// this object and hid members from the listing that the extract would
	// still have written. An empty value overrides it either way.
	const tarEnv = { LC_ALL: "C", PATH: envVar("PATH") ?? "", TAR_OPTIONS: "" };
	const listing = spawnSync("tar", ["--numeric-owner", "-tvzf", tarballPath], {
		encoding: "utf8",
		stdio: ["ignore", "pipe", "ignore"],
		env: tarEnv,
	});
	if (listing.status !== 0 || listing.stdout === null) return false;
	const violation = archiveListingViolation(listing.stdout, prefix);
	if (violation !== null) failArchiveSecurity(violation);
	const untar = spawnSync(
		"tar",
		["-xzf", tarballPath, "-C", stage, "--no-same-owner", prefix],
		{ stdio: "ignore", env: tarEnv },
	);
	if (untar.status !== 0) {
		failArchiveSecurity("tar extract failed");
	}
	return true;
}

function fetchIntoCache(
	contract: Contract,
	version: string,
	target: string,
	cacheLib: string,
): void {
	const base = envVar("GLOWCAP_RELEASE_BASE_URL") ??
		contract.default_release_base_url;
	requireSecureReleaseUrl(base, envTruthy("GLOWCAP_ALLOW_INSECURE"));
	const userAgent = contract.user_agent;
	const maxBytes = contract.max_tarball_bytes;
	const maxSums = contract.max_sums_bytes;
	const extractPrefix = contract.extract_prefix;
	const tag = applyContractTemplate(contract.release_tag_template, version, target);
	const tarball = applyContractTemplate(contract.tarball_template, version, target);
	const url = `${base}/${tag}/${tarball}`;
	const cacheRoot = join(cacheLib, "..");
	const lockDir = join(cacheRoot, ".lock");

	try {
		mkdirSync(cacheRoot, { recursive: true });
	} catch { /* soft-fail */ }

	let waited = 0;
	while (true) {
		try {
			mkdirSync(lockDir);
			break;
		} catch {
			waited += 1;
			if (waited > 300) {
				softFail(`timed out waiting for cache lock at ${lockDir}`);
				return;
			}
			if (!sleepSync(100)) {
				softFail("host runtime cannot park while waiting for cache lock");
				return;
			}
		}
	}

	try {
		if (existsSync(markerPath(cacheLib, contract))) return;

		const tarballPath = join(cacheRoot, tarball);
		console.error(`glowcap: downloading ${url}`);
		if (!curlDownload(url, tarballPath, userAgent, maxBytes)) {
			try {
				rmSync(tarballPath, { force: true });
			} catch { /* soft-fail */ }
			softFail(`download failed: ${url}`);
			return;
		}

		const sumsUrl = `${base}/${tag}/SHA256SUMS`;
		const sumsPath = join(cacheRoot, "SHA256SUMS");
		if (!curlDownload(sumsUrl, sumsPath, userAgent, maxSums)) {
			try {
				rmSync(tarballPath, { force: true });
				rmSync(sumsPath, { force: true });
			} catch { /* soft-fail */ }
			failArchiveSecurity("checksum required before extract: SHA256SUMS download failed");
		}
		try {
			const lines = readFileSync(sumsPath, "utf8").split("\n");
			let expect: string | null = null;
			for (const line of lines) {
				const parts = line.trim().split(/\s+/);
				if (parts.length >= 2 && parts[1].replace(/^\*/, "") === tarball) {
					expect = parts[0].toLowerCase();
					break;
				}
			}
			if (expect === null) {
				failArchiveSecurity(`SHA256SUMS has no entry for ${tarball}`);
			}
			const got = createHash("sha256")
				.update(readFileSync(tarballPath))
				.digest("hex");
			if (got !== expect) {
				failArchiveSecurity(`SHA256 mismatch for ${tarball}`);
			}
		} catch (err) {
			if (err instanceof HardFailError) throw err;
			failArchiveSecurity(`checksum required before extract: ${err}`);
		}

		const stage = join(cacheRoot, `stage.${process.pid}`);
		try {
			rmSync(stage, { recursive: true, force: true });
		} catch { /* soft-fail */ }
		mkdirSync(stage, { recursive: true });
		if (!safeExtractPrefix(tarballPath, stage, extractPrefix)) {
			softFail("tar list failed");
			return;
		}
		const extracted = join(stage, extractPrefix);
		let extractedIsDir = false;
		try {
			extractedIsDir = statSync(extracted).isDirectory();
		} catch {
			extractedIsDir = false;
		}
		if (!extractedIsDir) {
			failArchiveSecurity(`tarball missing ${extractPrefix}/`);
		}
		try {
			rmSync(cacheLib, { recursive: true, force: true });
		} catch { /* soft-fail */ }
		renameSync(extracted, cacheLib);
		try {
			rmSync(stage, { recursive: true, force: true });
		} catch { /* soft-fail */ }
	} catch (err) {
		// Soft-fail: missing curl/tar, denied permissions, or I/O error.
		// HardFailError and STRICT always re-throw — do not swallow them.
		if (err instanceof HardFailError) throw err;
		if (envTruthy("GLOWCAP_STRICT")) throw err;
	} finally {
		try {
			rmdirSync(lockDir);
		} catch { /* soft-fail */ }
	}
}

function markerPath(dir: string, contract: Contract): string {
	return join(dir.replace(/\/$/, ""), libFile(contract.marker_shared_stem));
}

function libDir(): string | null {
	const override = envVar("GLOWCAP_LIB_DIR");
	if (override !== null) return override;

	let contract: Contract;
	try {
		contract = loadContract();
	} catch (err) {
		// Deno permission denial degrades to the next rung; a corrupt or
		// incomplete contract is a hard failure (parity with Python/Racket).
		const msg = err instanceof Error ? err.message : String(err);
		if (
			msg.includes("Requires") ||
			msg.includes("PermissionDenied") ||
			msg.includes("NotCapable") ||
			msg.includes("permission")
		) {
			return null;
		}
		throw err;
	}

	const devRoot = findDevRoot();
	const version = abiVersion(devRoot, contract);
	const target = hostTargetTriple();
	const cacheLib = cacheLibDir(contract, version, target);
	const zigOut = devRoot !== null ? join(devRoot, "zig-out/lib") : null;

	try {
		if (cacheLib !== null && existsSync(markerPath(cacheLib, contract))) {
			return cacheLib;
		}
	} catch { /* no read permission */ }

	let zigHasMarker = false;
	if (zigOut !== null) {
		try {
			zigHasMarker = existsSync(markerPath(zigOut, contract));
		} catch { /* no read permission */ }
	}

	if (zigHasMarker) {
		// GLOWCAP_DOWNLOAD refreshes the cache even when zig-out exists,
		// including when releases_published is false.
		if (cacheLib !== null && envTruthy("GLOWCAP_DOWNLOAD")) {
			fetchIntoCache(contract, version, target, cacheLib);
			try {
				if (existsSync(markerPath(cacheLib, contract))) return cacheLib;
			} catch { /* soft-fail */ }
		}
		return zigOut;
	}

	if (cacheLib !== null && wantReleaseFetch(contract)) {
		fetchIntoCache(contract, version, target, cacheLib);
		try {
			if (existsSync(markerPath(cacheLib, contract))) return cacheLib;
		} catch { /* soft-fail */ }
	}

	if (zigOut !== null) {
		try {
			return existsSync(zigOut) ? zigOut : null;
		} catch {
			return null;
		}
	}
	return null;
}

export function libPath(stem: string): string {
	// No host built-ins means no filesystem and no dlopen: the active adapter
	// is the wasm one (ADR-0070), whose `dlopen` ignores the path. Hand back
	// the stem before any cascade rung runs. The injected check is re-read
	// here, not just via `host`: a static import chain can evaluate this
	// module before the browser binding injects its adapter, so `host` may
	// have been built from the (stubbed) node imports; an injected adapter at
	// call time still means no cascade.
	if (
		host === null || (globalThis as Record<symbol, unknown>)[injected_adapter_key] !== undefined
	) {
		return stem;
	}
	const file = libFile(stem);
	const dir = libDir();
	if (dir !== null) return `${dir.replace(/\/$/, "")}/${file}`;
	if (process.platform === "win32") {
		throw new Error(
			`glowcap: could not resolve an absolute path for ${file}; set GLOWCAP_LIB_DIR or populate the abi-versioned cache (Windows refuses bare DLL names to avoid search-order plants)`,
		);
	}
	console.error(`glowcap: warning: loading bare ${file} via the OS search path`);
	return file;
}
