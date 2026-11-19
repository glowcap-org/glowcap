// The explainer video the website serves: the approved render, published as a
// release of the site media repository and pinned in this one.
//
// `zig build site` runs `fetch`, which puts the pinned files into `--out`
// (default `site/assets`) and checks each against its size and SHA-256. A file
// already there with the pinned hash is kept, and so is one that differs: that
// is a local render under review, and the build says so. A file an earlier
// fetch wrote is published, not local, so once the pin moves it is replaced.
// `zig-out/site-video/fetched.json` records what fetch wrote. A local render is
// used whole or not at all, so one that is missing a file is refused rather
// than completed with published files. Before any render is pinned, a
// complete local render is used the same way. A download that fails, takes
// longer than two minutes, or does not match its pin writes nothing for that
// file and exits 1. A pin for a render made of other files is treated as no
// pin, since nothing it names fits the page.
//
// `zig build site-video-publish` runs `publish` after a maintainer approves a
// render from `zig build site-video`. It uploads the render's files from
// `--out` as one release of the media repository with `gh`, reads back the
// digests GitHub recorded, and only then rewrites the pin. The release is
// named by the hashes of all its files, so publishing the same render again finds
// it, uploads whatever an interrupted publish left out, and rewrites the pin
// from it. A release under that name holding any other file is refused.
//
// Usage: deno run --allow-all site/scripts/published-video.ts fetch|publish [--out=<dir>]
// Runs from the repository root. Reasons for a refusal go to stderr.

import captureAssets from "./capture-assets.json" with { type: "json" };
import { outDirArg, replaceFile } from "./capture.ts";

/** The pin: which render the site serves. Committed, and the only record of it. */
export const PIN = "site/video/published.json";
/** The media repository the renders are published to. */
export const REPOSITORY = "glowcap-org/glowcap-site-media";
/** Where its release assets download from. A pin may name no other place. */
export const DOWNLOADS = `https://github.com/${REPOSITORY}/releases/download/`;
/** How long one download may take before the build gives up on it. */
export const DOWNLOAD_MS = 120_000;
/** The files that make up one render: the video and its poster in each of
 * the site's faces, and the captions they share. `render-video.ts` refuses to
 * write a file this list does not declare. */
export const FILES = captureAssets.filter((name) => name.startsWith("glowcap-explainer"));

export type Pinned = { url: string; bytes: number; sha256: string };
export type Pin = { release: string; files: Record<string, Pinned> };

/** A pin `publish` wrote for a render made of other files than `FILES`, so
 * nothing it names fits the page. Fetch treats it as no pin. */
export class PinForOtherFiles extends Error {}

/** Read a pin, refusing any shape but the one `publish` writes. */
export function parsePin(text: string, downloads = DOWNLOADS): Pin {
	const value: unknown = JSON.parse(text);
	if (typeof value !== "object" || value == null) throw new Error(`${PIN} is not an object`);
	const release = Reflect.get(value, "release");
	const files = Reflect.get(value, "files");
	if (typeof release !== "string") throw new Error(`${PIN} names no release`);
	if (typeof files !== "object" || files == null) throw new Error(`${PIN} lists no files`);
	const names = Object.keys(files).sort();
	if (names.join() !== [...FILES].sort().join()) {
		throw new PinForOtherFiles(`${PIN} lists ${names.join(", ")}, where a render is ${FILES.join(", ")}`);
	}
	const pinned: Record<string, Pinned> = {};
	for (const name of FILES) {
		const entry: unknown = Reflect.get(files, name);
		if (typeof entry !== "object" || entry == null) throw new Error(`${PIN}: ${name} is not an object`);
		const url = Reflect.get(entry, "url");
		const bytes = Reflect.get(entry, "bytes");
		const sha256 = Reflect.get(entry, "sha256");
		if (typeof url !== "string" || !url.startsWith(downloads) || !url.endsWith(`/${name}`)) {
			throw new Error(`${PIN}: ${name} must download from ${downloads}`);
		}
		if (typeof bytes !== "number" || !Number.isSafeInteger(bytes) || bytes <= 0) {
			throw new Error(`${PIN}: ${name} has no size`);
		}
		if (typeof sha256 !== "string" || !/^[0-9a-f]{64}$/.test(sha256)) {
			throw new Error(`${PIN}: ${name} has no SHA-256`);
		}
		pinned[name] = { url, bytes, sha256 };
	}
	return { release, files: pinned };
}

/** The pin at `path` that fetch serves from, or null when there is none or
 * it names a render of other files, which `warn` hears about. Any other
 * flaw in the pin is refused. */
export async function readPin(path: string, warn: (message: string) => void): Promise<Pin | null> {
	try {
		return parsePin(await Deno.readTextFile(path));
	} catch (err) {
		if (err instanceof Deno.errors.NotFound) return null;
		if (err instanceof PinForOtherFiles) {
			warn(err.message);
			return null;
		}
		throw err;
	}
}

export async function sha256(bytes: Uint8Array<ArrayBuffer>): Promise<string> {
	const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
	return Array.from(digest, (b) => b.toString(16).padStart(2, "0")).join("");
}

async function readIfThere(path: string): Promise<Uint8Array<ArrayBuffer> | null> {
	try {
		return await Deno.readFile(path);
	} catch (err) {
		if (err instanceof Deno.errors.NotFound) return null;
		throw err;
	}
}

/** Where fetch records the SHA-256 of every file it has written, so a later
 * fetch knows a published file from a local render. */
export const FETCHED = "zig-out/site-video/fetched.json";

/** What `fetchPinned` did with each file: already there, downloaded, or a
 * local render that differs from the pin and was kept. */
export type Outcome = "present" | "fetched" | "local";

/** Put every pinned file into `outDir`. Each download is checked before it is
 * written, and lands under its own name only whole. `record` lists the SHA-256
 * of every file a fetch has written, the pin's own files added before any
 * download, so a fetch that stops partway still knows its files. A file
 * listed there was published once and is replaced like a missing one. With no
 * pin, a complete local render is used as it is, and anything less is
 * refused. */
export async function fetchPinned(
	pin: Pin | null,
	outDir: string,
	{ record = FETCHED, get = (url) => fetch(url, { signal: AbortSignal.timeout(DOWNLOAD_MS) }) }: {
		record?: string;
		get?: (url: string) => Promise<Response>;
	} = {},
): Promise<Record<string, Outcome>> {
	const outcomes: Record<string, Outcome> = {};
	if (pin == null) {
		for (const name of FILES) {
			if (await readIfThere(`${outDir}/${name}`) == null) {
				throw new Error(
					`${PIN} names no render of these files, and ${outDir}/${name} is missing. Render one with zig build site-video, then publish it with zig build site-video-publish`,
				);
			}
			outcomes[name] = "local";
		}
		return outcomes;
	}
	const recorded = await readIfThere(record);
	const listed: unknown = recorded == null ? [] : JSON.parse(new TextDecoder().decode(recorded));
	if (!Array.isArray(listed) || listed.some((hash) => typeof hash !== "string")) {
		throw new Error(`${record} is not a list of SHA-256 hashes. Delete it and fetch again`);
	}
	const fetched = new Set<string>([...listed, ...Object.values(pin.files).map((entry) => entry.sha256)]);
	await Deno.mkdir(record.slice(0, record.lastIndexOf("/")), { recursive: true });
	await replaceFile(record, (temp) => Deno.writeTextFile(temp, `${JSON.stringify([...fetched])}\n`));
	const found: Record<string, Outcome | null> = {};
	for (const [name, entry] of Object.entries(pin.files)) {
		const local = await readIfThere(`${outDir}/${name}`);
		const hash = local == null ? null : await sha256(local);
		if (hash === entry.sha256) found[name] = "present";
		else if (hash == null || fetched.has(hash)) found[name] = null;
		else found[name] = "local";
	}
	const differs = FILES.filter((name) => found[name] === "local");
	const missing = FILES.filter((name) => found[name] == null);
	if (differs.length > 0 && missing.length > 0) {
		throw new Error(
			`${differs.join(", ")} in ${outDir} differs from the published render and ${
				missing.join(", ")
			} is missing, so a published file would join a local render. Finish the render with zig build site-video, or delete ${
				differs.join(", ")
			} to use the published one`,
		);
	}
	for (const [name, entry] of Object.entries(pin.files)) {
		const path = `${outDir}/${name}`;
		const already = found[name];
		if (already != null) {
			outcomes[name] = already;
			continue;
		}
		const response = await get(entry.url);
		if (!response.ok) {
			await response.body?.cancel();
			throw new Error(`${entry.url} answered ${response.status}`);
		}
		const bytes = new Uint8Array(await response.arrayBuffer());
		if (bytes.length !== entry.bytes) {
			throw new Error(`${entry.url} is ${bytes.length} bytes, where ${PIN} pins ${entry.bytes}`);
		}
		const got = await sha256(bytes);
		if (got !== entry.sha256) throw new Error(`${entry.url} has SHA-256 ${got}, where ${PIN} pins ${entry.sha256}`);
		await replaceFile(path, (temp) => Deno.writeFile(temp, bytes));
		outcomes[name] = "fetched";
	}
	return outcomes;
}

/** Runs `gh` with `args` and returns its standard output, or throws with its
 * standard error. */
export type Gh = (args: string[]) => Promise<string>;

const gh: Gh = async (args) => {
	const { success, stdout, stderr } = await new Deno.Command("gh", { args, stdout: "piped", stderr: "piped" })
		.output();
	if (!success) {
		throw new Error(`gh ${args.slice(0, 2).join(" ")} failed: ${new TextDecoder().decode(stderr).trim()}`);
	}
	return new TextDecoder().decode(stdout);
};

/** The SHA-256 GitHub recorded for each asset of the release `tag`, or null
 * when there is no such release. */
async function releaseDigests(tag: string, run: Gh): Promise<Record<string, string> | null> {
	let text: string;
	try {
		text = await run(["api", `repos/${REPOSITORY}/releases/tags/${tag}`]);
	} catch (err) {
		if (err instanceof Error && /HTTP 404/.test(err.message)) return null;
		throw err;
	}
	const assets: unknown = Reflect.get(JSON.parse(text), "assets");
	if (!Array.isArray(assets)) throw new Error(`the ${tag} release lists no assets`);
	const digests: Record<string, string> = {};
	for (const asset of assets) {
		const name = Reflect.get(asset, "name");
		const digest = Reflect.get(asset, "digest");
		if (typeof name !== "string") continue;
		if (typeof digest !== "string") {
			throw new Error(`the ${tag} release holds ${name} with no SHA-256 yet, so publish again in a minute`);
		}
		digests[name] = digest.replace(/^sha256:/, "");
	}
	return digests;
}

/** The release name for a render: a hash of its files' hashes, so one
 * render is one release, and a change to any of its files is another. */
export async function renderTag(files: Record<string, { sha256: string }>): Promise<string> {
	const listing = FILES.map((name) => `${files[name].sha256}  ${name}\n`).join("");
	return `explainer-${(await sha256(new TextEncoder().encode(listing))).slice(0, 12)}`;
}

/** Upload the render in `outDir` and return the pin that names it. */
export async function publish(outDir: string, source: string, run: Gh = gh): Promise<Pin> {
	const files: Record<string, { bytes: number; sha256: string }> = {};
	for (const name of FILES) {
		const bytes = await readIfThere(`${outDir}/${name}`);
		if (bytes == null) throw new Error(`${outDir}/${name} is missing: render it with zig build site-video`);
		files[name] = { bytes: bytes.length, sha256: await sha256(bytes) };
	}
	const tag = await renderTag(files);
	const matches = (digests: Record<string, string>) =>
		Object.keys(digests).length === FILES.length && FILES.every((name) => digests[name] === files[name].sha256);
	const before = await releaseDigests(tag, run);
	if (before != null && Object.entries(before).some(([name, digest]) => files[name]?.sha256 !== digest)) {
		throw new Error(`the ${tag} release already holds other files: delete it or render again`);
	}
	if (before != null && !matches(before)) {
		// An interrupted publish left part of this render in the release.
		await run([
			"release",
			"upload",
			tag,
			"--repo",
			REPOSITORY,
			...FILES.filter((name) => before[name] == null).map((name) => `${outDir}/${name}`),
		]);
	}
	if (before == null) {
		await run([
			"release",
			"create",
			tag,
			"--repo",
			REPOSITORY,
			"--title",
			`Explainer video ${tag.slice("explainer-".length)}`,
			"--notes",
			`The glowcap website's explainer video, its poster, and its captions, rendered from ${source}.`,
			...FILES.map((name) => `${outDir}/${name}`),
		]);
	}
	if (before == null || !matches(before)) {
		const after = await releaseDigests(tag, run);
		if (after == null || !matches(after)) {
			throw new Error(`the ${tag} release does not hold the files uploaded to it, so ${PIN} is unchanged`);
		}
	}
	return {
		release: `https://github.com/${REPOSITORY}/releases/tag/${tag}`,
		files: Object.fromEntries(FILES.map((name) => [name, { url: `${DOWNLOADS}${tag}/${name}`, ...files[name] }])),
	};
}

/** The commit a render came from, marked when the tree had changes beyond it. */
async function sourceCommit(): Promise<string> {
	const git = async (...args: string[]) => {
		const { success, stdout } = await new Deno.Command("git", { args, stdout: "piped", stderr: "inherit" })
			.output();
		if (!success) throw new Error(`git ${args[0]} failed`);
		return new TextDecoder().decode(stdout).trim();
	};
	const head = await git("rev-parse", "HEAD");
	const dirty = (await git("status", "--porcelain")) !== "";
	return `glowcap-org/glowcap ${head}${dirty ? " with uncommitted changes" : ""}`;
}

if (import.meta.main) {
	const verb = Deno.args[0];
	const outDir = outDirArg();
	try {
		if (verb === "fetch") {
			const pin = await readPin(PIN, (message) => console.error(`site-video-fetch: ${message}`));
			const outcomes = await fetchPinned(pin, outDir);
			if (pin == null) {
				console.error(
					`site-video-fetch: no render of these files is published, so the site build uses the local render in ${outDir}`,
				);
			}
			for (const [name, outcome] of Object.entries(outcomes)) {
				if (pin != null && outcome === "local") {
					console.error(
						`site-video-fetch: ${outDir}/${name} is a local render, not the published one, and the site build uses it. Delete it to use the published render.`,
					);
				}
				if (outcome === "fetched") console.error(`site-video-fetch: fetched ${outDir}/${name}`);
			}
		} else if (verb === "publish") {
			const pin = await publish(outDir, await sourceCommit());
			await Deno.writeTextFile(PIN, `${JSON.stringify(pin, null, "\t")}\n`);
			console.error(`site-video-publish: ${pin.release} is published and ${PIN} names it`);
		} else {
			throw new Error("usage: published-video.ts fetch|publish [--out=<dir>]");
		}
	} catch (err) {
		console.error(
			`${verb === "publish" ? "site-video-publish" : "site-video-fetch"}: ${
				err instanceof Error ? err.message : err
			}`,
		);
		Deno.exit(1);
	}
}
