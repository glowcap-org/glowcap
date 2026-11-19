// The published explainer video's pin, fetch, and publish, driven with a fake
// download and a fake `gh`. `zig build site-video-test` runs it.
import { deepStrictEqual as assertEquals, rejects, throws } from "node:assert/strict";
import {
	DOWNLOADS,
	fetchPinned,
	FILES,
	type Gh,
	parsePin,
	type Pin,
	publish,
	readPin,
	renderTag,
	REPOSITORY,
	sha256,
} from "./published-video.ts";

const render: Record<string, Uint8Array<ArrayBuffer>> = Object.fromEntries(
	FILES.map((name, i) => [name, new TextEncoder().encode(`${name} ${"x".repeat(i + 1)}`)]),
);

async function pinFor(tag: string): Promise<Pin> {
	const files: Pin["files"] = {};
	for (const name of FILES) {
		files[name] = {
			url: `${DOWNLOADS}${tag}/${name}`,
			bytes: render[name].length,
			sha256: await sha256(render[name]),
		};
	}
	return { release: `release ${tag}`, files };
}

const serve = (body: (url: string) => Uint8Array<ArrayBuffer> | null) => (url: string) => {
	const bytes = body(url);
	return Promise.resolve(bytes == null ? new Response("missing", { status: 404 }) : new Response(bytes));
};
const byName = (url: string) => render[url.slice(url.lastIndexOf("/") + 1)] ?? null;

Deno.test("a pin reads back as written and refuses any other shape", async () => {
	const pin = await pinFor("explainer-a");
	assertEquals(parsePin(JSON.stringify(pin)), pin);
	const without = structuredClone(pin);
	delete without.files[FILES[1]];
	throws(() => parsePin(JSON.stringify(without)), { message: /where a render is/ });
	const elsewhere = structuredClone(pin);
	elsewhere.files[FILES[0]].url = `https://example.com/explainer-a/${FILES[0]}`;
	throws(() => parsePin(JSON.stringify(elsewhere)), { message: /must download from/ });
	const unhashed = structuredClone(pin);
	unhashed.files[FILES[2]].sha256 = "beef";
	throws(() => parsePin(JSON.stringify(unhashed)), { message: /has no SHA-256/ });
});

/** Run `body` with an empty output directory and a record path beside it,
 * both removed after. */
async function inDirs(body: (out: string, record: string) => Promise<void>): Promise<void> {
	const root = await Deno.makeTempDir();
	try {
		await Deno.mkdir(`${root}/out`);
		await body(`${root}/out`, `${root}/record/fetched.json`);
	} finally {
		await Deno.remove(root, { recursive: true });
	}
}

const none = () => Promise.reject(new Error("this fetch downloads nothing"));

Deno.test("fetch downloads every missing file and keeps one already there", () =>
	inDirs(async (dir, record) => {
		const pin = await pinFor("explainer-a");
		await Deno.writeFile(`${dir}/${FILES[1]}`, render[FILES[1]]);
		const asked: string[] = [];
		const outcomes = await fetchPinned(pin, dir, { record, get: serve((url) => (asked.push(url), byName(url))) });
		const missing = FILES.filter((name) => name !== FILES[1]);
		assertEquals(
			outcomes,
			Object.fromEntries(FILES.map((name) => [name, name === FILES[1] ? "present" : "fetched"])),
		);
		assertEquals(asked, missing.map((name) => pin.files[name].url));
		assertEquals(await Deno.readFile(`${dir}/${FILES[0]}`), render[FILES[0]]);
	}));

Deno.test("fetch keeps a complete local render and downloads nothing", () =>
	inDirs(async (dir, record) => {
		const pin = await pinFor("explainer-a");
		const rendered = FILES[FILES.length - 1];
		for (const name of FILES) {
			await Deno.writeFile(
				`${dir}/${name}`,
				name === rendered ? new TextEncoder().encode("a local render") : render[name],
			);
		}
		const outcomes = await fetchPinned(pin, dir, { record, get: none });
		assertEquals(
			outcomes,
			Object.fromEntries(FILES.map((name) => [name, name === rendered ? "local" : "present"])),
		);
		assertEquals(await Deno.readTextFile(`${dir}/${rendered}`), "a local render");
	}));

Deno.test("fetch replaces a file an earlier fetch wrote once the pin moves", () =>
	inDirs(async (dir, record) => {
		const older = new TextEncoder().encode("the render published before");
		const before = structuredClone(await pinFor("explainer-a"));
		for (const name of FILES) before.files[name] = { ...before.files[name], sha256: await sha256(older) };
		for (const name of FILES) await Deno.writeFile(`${dir}/${name}`, older);
		assertEquals(
			await fetchPinned(before, dir, { record, get: none }),
			Object.fromEntries(FILES.map((name) => [name, "present"])),
		);
		const outcomes = await fetchPinned(await pinFor("explainer-b"), dir, { record, get: serve(byName) });
		assertEquals(outcomes, Object.fromEntries(FILES.map((name) => [name, "fetched"])));
		for (const name of FILES) assertEquals(await Deno.readFile(`${dir}/${name}`), render[name]);
	}));

Deno.test("a fetch that stops partway leaves files the next pin replaces", () =>
	inDirs(async (dir, record) => {
		const b = await pinFor("explainer-b");
		const last = b.files[FILES[2]].url;
		await rejects(() => fetchPinned(b, dir, { record, get: serve((url) => url === last ? null : byName(url)) }), {
			message: /answered 404/,
		});
		assertEquals(await Deno.readFile(`${dir}/${FILES[0]}`), render[FILES[0]]);
		// The pin moves to a render whose files all differ before a fetch
		// finishes, and the files the stopped fetch wrote are still published.
		const moved: Record<string, Uint8Array<ArrayBuffer>> = Object.fromEntries(
			FILES.map((name) => [name, new TextEncoder().encode(`${name} moved`)]),
		);
		const c = structuredClone(b);
		for (const name of FILES) {
			c.files[name] = { ...c.files[name], bytes: moved[name].length, sha256: await sha256(moved[name]) };
		}
		const outcomes = await fetchPinned(c, dir, {
			record,
			get: serve((url) => moved[url.slice(url.lastIndexOf("/") + 1)] ?? null),
		});
		assertEquals(outcomes, Object.fromEntries(FILES.map((name) => [name, "fetched"])));
	}));

Deno.test("fetch refuses a record that is not a list of hashes", () =>
	inDirs(async (dir, record) => {
		await Deno.mkdir(record.slice(0, record.lastIndexOf("/")));
		await Deno.writeTextFile(record, "{}");
		const pin = await pinFor("explainer-a");
		await rejects(() => fetchPinned(pin, dir, { record, get: none }), {
			message: /not a list of SHA-256 hashes/,
		});
	}));

Deno.test("fetch refuses to complete a local render with published files", () =>
	inDirs(async (dir, record) => {
		const pin = await pinFor("explainer-a");
		await Deno.writeFile(`${dir}/${FILES[0]}`, new TextEncoder().encode("a local render"));
		const asked: string[] = [];
		await rejects(
			() => fetchPinned(pin, dir, { record, get: serve((url) => (asked.push(url), byName(url))) }),
			{ message: /would join a local render/ },
		);
		assertEquals(asked, []);
		assertEquals([...Deno.readDirSync(dir)].map((entry) => entry.name), [FILES[0]]);
	}));

Deno.test("with no pin, fetch uses a complete local render and refuses a partial one", () =>
	inDirs(async (dir, record) => {
		await Deno.writeFile(`${dir}/${FILES[0]}`, render[FILES[0]]);
		await rejects(() => fetchPinned(null, dir, { record, get: none }), {
			message: /names no render of these files/,
		});
		for (const name of FILES) await Deno.writeFile(`${dir}/${name}`, render[name]);
		assertEquals(
			await fetchPinned(null, dir, { record, get: none }),
			Object.fromEntries(FILES.map((name) => [name, "local"])),
		);
	}));

Deno.test("a pin for a render of other files reads as no pin, and any other flaw is refused", async () => {
	const dir = await Deno.makeTempDir();
	try {
		const path = `${dir}/published.json`;
		const warned: string[] = [];
		const warn = (message: string) => warned.push(message);
		assertEquals(await readPin(path, warn), null);
		const pin = await pinFor("explainer-a");
		await Deno.writeTextFile(path, JSON.stringify(pin));
		assertEquals(await readPin(path, warn), pin);
		const older = structuredClone(pin);
		delete older.files[FILES[1]];
		await Deno.writeTextFile(path, JSON.stringify(older));
		assertEquals(await readPin(path, warn), null);
		assertEquals(warned.length, 1);
		assertEquals(warned[0].includes("where a render is"), true);
		const unhashed = structuredClone(pin);
		unhashed.files[FILES[0]].sha256 = "beef";
		await Deno.writeTextFile(path, JSON.stringify(unhashed));
		await rejects(() => readPin(path, warn), { message: /has no SHA-256/ });
	} finally {
		await Deno.remove(dir, { recursive: true });
	}
});

Deno.test("fetch writes nothing for a download that fails or does not match its pin", async () => {
	const pin = await pinFor("explainer-a");
	const cases: [string, (url: string) => Uint8Array<ArrayBuffer> | null][] = [
		["answered 404", () => null],
		["bytes, where", (url) => new Uint8Array([...byName(url) ?? [], 0])],
		["has SHA-256", (url) => (byName(url) ?? new Uint8Array()).map((b) => b ^ 1)],
	];
	for (const [refusal, body] of cases) {
		await inDirs(async (dir, record) => {
			await rejects(() => fetchPinned(pin, dir, { record, get: serve(body) }), { message: new RegExp(refusal) });
			assertEquals([...Deno.readDirSync(dir)], []);
		});
	}
});

/** A fake `gh` holding releases by tag, each a map of asset name to digest. */
function fakeGh(
	releases: Map<string, Record<string, string>>,
	upload: (path: string) => string | null,
): { run: Gh; calls: string[][] } {
	const calls: string[][] = [];
	const run: Gh = (args) => {
		calls.push(args);
		if (args[0] === "api") {
			const tag = args[1].slice(args[1].lastIndexOf("/") + 1);
			const assets = releases.get(tag);
			if (assets == null) return Promise.reject(new Error("gh api failed: HTTP 404: Not Found"));
			return Promise.resolve(
				JSON.stringify({
					assets: Object.entries(assets).map(([name, digest]) => ({ name, digest: `sha256:${digest}` })),
				}),
			);
		}
		if (args[0] === "release" && (args[1] === "create" || args[1] === "upload")) {
			const assets: Record<string, string> = args[1] === "upload" ? releases.get(args[2]) ?? {} : {};
			for (const path of args.filter((arg) => FILES.some((name) => arg.endsWith(`/${name}`)))) {
				const digest = upload(path);
				if (digest != null) assets[path.slice(path.lastIndexOf("/") + 1)] = digest;
			}
			releases.set(args[2], assets);
			return Promise.resolve("");
		}
		return Promise.reject(new Error(`unexpected gh ${args.join(" ")}`));
	};
	return { run, calls };
}

Deno.test("publish uploads a render once and pins what the release holds", async () => {
	const dir = await Deno.makeTempDir();
	try {
		for (const name of FILES) await Deno.writeFile(`${dir}/${name}`, render[name]);
		const digests = Object.fromEntries(
			await Promise.all(FILES.map(async (name) => [name, await sha256(render[name])])),
		);
		const releases = new Map<string, Record<string, string>>();
		const first = fakeGh(releases, (path) => digests[path.slice(path.lastIndexOf("/") + 1)] ?? null);
		const pin = await publish(dir, "source", first.run);
		const tag = await renderTag(Object.fromEntries(FILES.map((name) => [name, { sha256: digests[name] }])));
		assertEquals(parsePin(JSON.stringify(pin)).files, (await pinFor(tag)).files);
		assertEquals(first.calls.filter((args) => args[0] === "release").length, 1);
		const again = fakeGh(releases, () => null);
		assertEquals(await publish(dir, "source", again.run), pin);
		assertEquals(again.calls.filter((args) => args[0] === "release").length, 0);
	} finally {
		await Deno.remove(dir, { recursive: true });
	}
});

Deno.test("publish names a release by every file and finishes one an interrupted publish left", async () => {
	const dir = await Deno.makeTempDir();
	try {
		for (const name of FILES) await Deno.writeFile(`${dir}/${name}`, render[name]);
		const digests = Object.fromEntries(
			await Promise.all(FILES.map(async (name) => [name, await sha256(render[name])])),
		);
		const tag = await renderTag(Object.fromEntries(FILES.map((name) => [name, { sha256: digests[name] }])));
		// New captions on the same video are a new release.
		const recaptioned = await renderTag(
			Object.fromEntries(
				FILES.map((name) => [name, { sha256: name.endsWith(".vtt") ? "0".repeat(64) : digests[name] }]),
			),
		);
		assertEquals(tag === recaptioned, false);
		const releases = new Map([[tag, { [FILES[0]]: digests[FILES[0]] }]]);
		const resumed = fakeGh(releases, (path) => digests[path.slice(path.lastIndexOf("/") + 1)] ?? null);
		const pin = await publish(dir, "source", resumed.run);
		assertEquals(parsePin(JSON.stringify(pin)).files, (await pinFor(tag)).files);
		assertEquals(resumed.calls.filter((args) => args[0] === "release"), [
			["release", "upload", tag, "--repo", REPOSITORY, ...FILES.slice(1).map((name) => `${dir}/${name}`)],
		]);
	} finally {
		await Deno.remove(dir, { recursive: true });
	}
});

Deno.test("publish refuses a missing file, a tag holding other files, and an upload that did not land", async () => {
	const dir = await Deno.makeTempDir();
	try {
		await rejects(() => publish(dir, "source", fakeGh(new Map(), () => null).run), {
			message: /render it with zig build site-video/,
		});
		for (const name of FILES) await Deno.writeFile(`${dir}/${name}`, render[name]);
		const tag = await renderTag(
			Object.fromEntries(
				await Promise.all(FILES.map(async (name) => [name, { sha256: await sha256(render[name]) }])),
			),
		);
		const taken = fakeGh(new Map([[tag, { [FILES[0]]: "0".repeat(64) }]]), () => null);
		await rejects(() => publish(dir, "source", taken.run), { message: /already holds other files/ });
		const lost = fakeGh(new Map(), () => "1".repeat(64));
		await rejects(() => publish(dir, "source", lost.run), { message: /does not hold the files uploaded to it/ });
	} finally {
		await Deno.remove(dir, { recursive: true });
	}
});
