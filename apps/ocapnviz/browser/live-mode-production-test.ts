#!/usr/bin/env -S deno run -A
/** Production-bundle proof for Live mode as an OCapN peer.
 *
 * The Vite build happens in the owning task. This process serves only `dist/`,
 * at the directory the website publishes it under, starts the real trace
 * endpoint, and drives an actual Chromium tab. A build that named any file by
 * a path from the server's root would ask outside that directory and fail.
 *
 * The same build is then loaded the way the website's readers load it, from a
 * public https origin, where the browser guards this machine and forbids every
 * other one. */

import type { Browser, Page } from "playwright";

import { launchHeadless } from "../scripts/support/headless.ts";

const TEST_TIMEOUT_MS = 45_000;
const UI_TIMEOUT_MS = 10_000;
const MAX_ANNOUNCEMENT_BYTES = 8 * 1024;
const distRoot = new URL("../dist/", import.meta.url);
const repositoryRoot = new URL("../../../", import.meta.url);
const traceHostScript = new URL(
	"../../rooms/test/trace/browser_host.ts",
	import.meta.url,
);
/** Where the website serves this build. */
const PUBLISHED_AT = "/ocapnviz/";
const requiredAssets = [
	"index.html",
	"glowcap_host.wasm",
	"favicon.svg",
	"fonts/DepartureMono-Regular.woff2",
	"fonts/Inter-Latin-Variable.woff2",
];
/** The worker that retires another app's registration belongs to the dev
 * origin. A published page registers none and carries none. */
const devOnlyAssets = ["sw.js"];

type WorldSnapshot = {
	peers: Array<{ id: string; label: string }>;
	sessions: string[];
};

type TraceAnnouncement = {
	port: number;
	sturdyref: string;
	/** The producer route. A producer is admitted once its first message
	 * there is `swiss`. */
	publish: string;
	swiss: string;
};

function fail(message: string): never {
	throw new Error(message);
}

/** Session is open: waiting for the first record, or already spoken. */
function liveFeedSessionOpen(page: Page) {
	return page.getByTitle(/^The live feed is connected/);
}

/** A public https origin standing in for the website. Chromium decides what a
 * page may reach from where its bytes came from, and a page this machine
 * serves is never guarded, so the page is routed there and not served there. */
const WEBSITE = "https://ocapnviz.example";

/** Open the build as the website serves it, asked to watch `link`, with what
 * the page reported going wrong from its first request. */
async function openFromWebsite(
	browser: Browser,
	httpPort: number,
	link: string,
): Promise<{ page: Page; failures: string[] }> {
	const context = await browser.newContext({ viewport: { width: 1440, height: 900 } });
	await context.route(`${WEBSITE}/**`, async (route) => {
		const asked = new URL(route.request().url());
		const response = await route.fetch({ url: `http://127.0.0.1:${httpPort}${asked.pathname}` });
		await route.fulfill({ response });
	});
	const page = await context.newPage();
	page.setDefaultTimeout(UI_TIMEOUT_MS);
	const failures = failuresOf(page);
	await page.goto(`${WEBSITE}${PUBLISHED_AT}#live=${encodeURIComponent(link)}`);
	return { page, failures };
}

/** What the website's readers meet in Live. A trace at another address is
 * refused by name. A trace on this computer is blocked while the browser's
 * local network prompt goes unanswered, as it does in headless Chromium, and
 * the report names the prompt beside the server. With the browser's check
 * lifted at launch, which stands in for a person answering "allow", the same
 * page connects with nothing failing. */
async function proveWebsiteLive(browser: Browser, httpPort: number, sturdyref: string): Promise<void> {
	const elsewhere = await openFromWebsite(browser, httpPort, "ocapn://trace.example%3A9300.tcp/s/c3dpc3M");
	await elsewhere.page.getByText("This page cannot reach that trace").waitFor({ state: "visible" });
	await elsewhere.page.getByTitle(/^This page cannot dial this link/).waitFor({ state: "visible" });
	if (!(await elsewhere.page.getByRole("button", { name: "Start recording" }).isDisabled())) {
		fail("a refused link leaves Record enabled");
	}
	if (elsewhere.failures.length > 0) {
		fail(`a refused link asked the browser for something:\n${elsewhere.failures.join("\n")}`);
	}
	await elsewhere.page.context().close();

	const guarded = await openFromWebsite(browser, httpPort, sturdyref);
	await guarded.page.getByText(/If the browser asks whether this site may reach devices on your local network/)
		.first().waitFor({ state: "visible" });
	await guarded.page.context().close();

	const allowing = await launchHeadless(["--disable-features=LocalNetworkAccessChecks"]);
	try {
		const allowed = await openFromWebsite(allowing, httpPort, sturdyref);
		await liveFeedSessionOpen(allowed.page).waitFor({ state: "visible" });
		if (allowed.failures.length > 0) fail(`the website's tab failed:\n${allowed.failures.join("\n")}`);
	} finally {
		await allowing.close();
	}
}

/** Everything `page` reports going wrong from here on: a thrown error, a
 * console error, a request that failed, or an answer of 400 and above. */
function failuresOf(page: Page): string[] {
	const failures: string[] = [];
	page.on("pageerror", (error) => failures.push(`pageerror: ${error.message}`));
	page.on("console", (message) => {
		if (message.type() === "error") failures.push(`console: ${message.text()}`);
	});
	page.on("requestfailed", (request) => {
		failures.push(`request failed: ${request.url()} (${request.failure()?.errorText ?? "unknown"})`);
	});
	page.on("response", (response) => {
		if (response.status() >= 400) failures.push(`HTTP ${response.status()}: ${response.url()}`);
	});
	return failures;
}

async function readTraceAnnouncement(
	stdout: ReadableStream<Uint8Array>,
): Promise<TraceAnnouncement> {
	const reader = stdout.getReader();
	const decoder = new TextDecoder();
	let line = "";
	try {
		while (!line.includes("\n")) {
			const { value, done } = await reader.read();
			if (done) fail("trace host exited before announcing its endpoint");
			line += decoder.decode(value, { stream: true });
			if (line.length > MAX_ANNOUNCEMENT_BYTES) {
				fail("trace host announcement exceeded its bound");
			}
		}
	} finally {
		reader.releaseLock();
	}

	const parsed: unknown = JSON.parse(line.slice(0, line.indexOf("\n")));
	if (
		typeof parsed !== "object" || parsed === null ||
		!("port" in parsed) || !Number.isInteger(parsed.port) ||
		(parsed.port as number) < 1 || (parsed.port as number) > 65_535 ||
		!("sturdyref" in parsed) || typeof parsed.sturdyref !== "string" ||
		parsed.sturdyref.length === 0 ||
		!("publish" in parsed) || typeof parsed.publish !== "string" ||
		parsed.publish.length === 0 ||
		!("swiss" in parsed) || typeof parsed.swiss !== "string" ||
		parsed.swiss.length === 0
	) {
		fail(`invalid trace host announcement: ${JSON.stringify(parsed)}`);
	}
	return {
		port: parsed.port as number,
		sturdyref: parsed.sturdyref,
		publish: parsed.publish,
		swiss: parsed.swiss,
	};
}

async function stopTraceHost(process: Deno.ChildProcess): Promise<void> {
	try {
		process.kill("SIGTERM");
	} catch (error) {
		if (!(error instanceof Deno.errors.NotFound)) throw error;
	}
	await process.status;
}

function bytesDiffer(a: Uint8Array, b: Uint8Array): boolean {
	if (a.byteLength !== b.byteLength) return true;
	for (let i = 0; i < a.byteLength; i += 1) {
		if (a[i] !== b[i]) return true;
	}
	return false;
}

function contentType(pathname: string): string {
	if (pathname.endsWith(".html")) return "text/html; charset=utf-8";
	if (pathname.endsWith(".js")) return "text/javascript; charset=utf-8";
	if (pathname.endsWith(".css")) return "text/css; charset=utf-8";
	if (pathname.endsWith(".wasm")) return "application/wasm";
	if (pathname.endsWith(".svg")) return "image/svg+xml";
	if (pathname.endsWith(".woff2")) return "font/woff2";
	return "application/octet-stream";
}

async function worldSnapshot(page: Page): Promise<WorldSnapshot> {
	return await page.evaluate(() => {
		type Peer = { peer: { id: string; label: string } };
		type Session = { session: { id: string } };
		type Engine = {
			queries: {
				peers: Iterable<Peer>;
				sessions: Iterable<Session>;
			};
		};
		const engine = (globalThis as unknown as {
			__ocv?: { engine?: Engine };
		}).__ocv?.engine;
		if (engine === undefined) {
			throw new Error("ocapnviz did not expose its live engine");
		}
		return {
			peers: [...engine.queries.peers]
				.map((entity) => ({ ...entity.peer }))
				.sort((a, b) => a.id.localeCompare(b.id)),
			sessions: [...engine.queries.sessions]
				.map((entity) => entity.session.id)
				.sort(),
		};
	});
}

async function waitForWorld(
	page: Page,
	peers: number,
	sessions: number,
): Promise<void> {
	await page.waitForFunction(
		([peerCount, sessionCount]) => {
			type Engine = {
				queries: {
					peers: Iterable<unknown>;
					sessions: Iterable<unknown>;
				};
			};
			const engine = (globalThis as unknown as {
				__ocv?: { engine?: Engine };
			}).__ocv?.engine;
			return engine !== undefined &&
				[...engine.queries.peers].length === peerCount &&
				[...engine.queries.sessions].length === sessionCount;
		},
		[peers, sessions],
		{ timeout: UI_TIMEOUT_MS },
	);
}

function assertWorld(
	actual: WorldSnapshot,
	expectedLabels: string[],
	expectedSessionSuffixes: string[],
): void {
	const labels = actual.peers.map((peer) => peer.label).sort();
	const wantedLabels = [...expectedLabels].sort();
	if (JSON.stringify(labels) !== JSON.stringify(wantedLabels)) {
		fail(
			`expected peer labels ${JSON.stringify(wantedLabels)}, got ${JSON.stringify(labels)}`,
		);
	}
	if (actual.sessions.length !== expectedSessionSuffixes.length) {
		fail(
			`expected ${expectedSessionSuffixes.length} sessions, got ${actual.sessions.length}: ` +
				JSON.stringify(actual.sessions),
		);
	}
	for (const suffix of expectedSessionSuffixes) {
		if (
			!actual.sessions.some((session) => session.endsWith(`/${suffix}`))
		) {
			fail(
				`missing session observation ${suffix}: ${JSON.stringify(actual.sessions)}`,
			);
		}
	}
}

/** Open the producer route and present the capability as the first message,
 * the only place the endpoint reads it. */
async function openPublisher(publish: string, swiss: string): Promise<WebSocket> {
	const socket = new WebSocket(publish);
	await new Promise<void>((resolve, reject) => {
		socket.onopen = () => {
			socket.send(swiss);
			resolve();
		};
		socket.onerror = () => reject(new Error("trace producer WebSocket did not open"));
	});
	return socket;
}

function openRecord(session: string, partner: string): string {
	return JSON.stringify({
		v: 1,
		sim_t_ns: 0,
		kind: "ocapn.session-opened",
		session,
		a: "rooms",
		b: partner,
		// The endpoint drops a record it cannot read in silence, so a missing
		// required field looks like a feed that never delivers. `valid_opened`
		// in the Rooms trace server names the required set.
		transport: "tcp",
		codec: "syrup",
		captp_version: "1.0",
	});
}

async function startRecording(page: Page): Promise<void> {
	await page.getByRole("button", { name: "Start recording" }).click();
	await page
		.getByRole("alertdialog", { name: "Discard the loaded document?" })
		.getByRole("button", { name: "Record", exact: true })
		.click();
	await page.getByRole("button", { name: "Stop recording" }).waitFor({
		state: "visible",
	});
	await liveFeedSessionOpen(page).waitFor({
		state: "visible",
	});
}

async function waitForPaint(page: Page): Promise<void> {
	await page.evaluate(() =>
		new Promise<void>((resolve) => {
			requestAnimationFrame(() => requestAnimationFrame(() => resolve()));
		})
	);
}

for (const asset of requiredAssets) {
	try {
		await Deno.stat(new URL(asset, distRoot));
	} catch {
		fail(`production build omitted ${asset}`);
	}
}

for (const asset of devOnlyAssets) {
	try {
		await Deno.stat(new URL(asset, distRoot));
	} catch (error) {
		if (error instanceof Deno.errors.NotFound) continue;
		throw error;
	}
	fail(`production build carries ${asset}, which only the dev server answers`);
}

const deadline = setTimeout(() => {
	console.error(
		`FAIL: production Live-mode proof exceeded ${TEST_TIMEOUT_MS}ms`,
	);
	Deno.exit(1);
}, TEST_TIMEOUT_MS);

const staticAbort = new AbortController();
let announceHttp!: (port: number) => void;
const httpReady = new Promise<number>((resolve) => announceHttp = resolve);
const served = new Map<string, number>();
/** Every request the page made outside the directory it is published under. */
const strays: string[] = [];
const staticServer = Deno.serve(
	{
		hostname: "127.0.0.1",
		port: 0,
		signal: staticAbort.signal,
		onListen: ({ port }) => announceHttp(port),
	},
	async (request) => {
		let pathname: string;
		try {
			pathname = decodeURIComponent(new URL(request.url).pathname);
		} catch {
			return new Response("bad path", { status: 400 });
		}
		if (!pathname.startsWith(PUBLISHED_AT)) {
			strays.push(pathname);
			return new Response("not found", { status: 404 });
		}
		const below = pathname.slice(PUBLISHED_AT.length);
		const relative = below === "" ? "index.html" : below;
		if (relative.split("/").includes("..")) {
			return new Response("forbidden", { status: 403 });
		}
		try {
			const bytes = await Deno.readFile(new URL(relative, distRoot));
			served.set(pathname, (served.get(pathname) ?? 0) + 1);
			return new Response(bytes, {
				headers: {
					"Cache-Control": "no-store",
					"Content-Type": contentType(relative),
				},
			});
		} catch (error) {
			if (error instanceof Deno.errors.NotFound) {
				return new Response("not found", { status: 404 });
			}
			throw error;
		}
	},
);

let traceHost: Deno.ChildProcess | null = null;
let browser: Browser | null = null;
let publisher: WebSocket | null = null;

try {
	traceHost = new Deno.Command(Deno.execPath(), {
		args: ["run", "-A", traceHostScript.pathname],
		cwd: repositoryRoot.pathname,
		stdout: "piped",
		stderr: "inherit",
	}).spawn();
	const [httpPort, trace] = await Promise.all([
		httpReady,
		readTraceAnnouncement(traceHost.stdout),
	]);
	const { sturdyref } = trace;
	publisher = await openPublisher(trace.publish, trace.swiss);

	browser = await launchHeadless();
	const context = await browser.newContext({
		viewport: { width: 1440, height: 900 },
		colorScheme: "dark",
	});
	await context.addInitScript(() => {
		localStorage.removeItem("ocapnviz:app-state");
		localStorage.removeItem("ocapnviz:theme");
	});
	const page = await context.newPage();
	page.setDefaultTimeout(UI_TIMEOUT_MS);
	const browserFailures = failuresOf(page);

	const pageUrl = `http://127.0.0.1:${httpPort}${PUBLISHED_AT}#live=${encodeURIComponent(sturdyref)}`;
	await page.goto(pageUrl, { waitUntil: "networkidle" });
	if (new URL(page.url()).hash !== "") {
		throw new Error(`the page kept the capability in its address: ${page.url()}`);
	}
	const canvas = page.locator("canvas#ocv-pixi");
	await canvas.waitFor({ state: "visible" });
	await liveFeedSessionOpen(page).waitFor({
		state: "visible",
	});
	const emptyCanvas = await canvas.screenshot();

	// Establish the producer's first session through a live capture, then throw
	// that capture away. The next fresh capture can only learn it from replay.
	await startRecording(page);
	publisher.send(openRecord("replay-s1", "alice"));
	await waitForWorld(page, 2, 1);
	await page.getByRole("button", { name: "Discard recording" }).click();
	await page.getByRole("button", { name: "Start recording" }).waitFor({
		state: "visible",
	});

	await startRecording(page);
	await waitForWorld(page, 2, 1);
	await waitForPaint(page);
	const replay = await worldSnapshot(page);
	assertWorld(replay, ["alice", "rooms"], ["replay-s1"]);
	const replayCanvas = await canvas.screenshot();
	if (!bytesDiffer(emptyCanvas, replayCanvas)) {
		fail(
			"replayed topology reached the engine but did not change the rendered canvas",
		);
	}

	publisher.send(openRecord("live-s2", "bob"));
	await waitForWorld(page, 3, 2);
	await waitForPaint(page);
	const live = await worldSnapshot(page);
	assertWorld(live, ["alice", "bob", "rooms"], ["replay-s1", "live-s2"]);
	const liveCanvas = await canvas.screenshot();
	if (!bytesDiffer(replayCanvas, liveCanvas)) {
		fail(
			"live topology reached the engine but did not change the rendered canvas",
		);
	}

	const wasmInitialized = await page.evaluate(() =>
		(globalThis as Record<symbol, unknown>)[
			Symbol.for("glowcap.runtime.adapter")
		] !== undefined
	);
	if (!wasmInitialized) {
		fail("the production tab never installed the wasm runtime adapter");
	}
	const wasmRequests = served.get(`${PUBLISHED_AT}glowcap_host.wasm`) ?? 0;
	if (wasmRequests < 1) {
		fail("the production tab never requested glowcap_host.wasm");
	}
	for (const font of requiredAssets.filter((asset) => asset.startsWith("fonts/"))) {
		if ((served.get(`${PUBLISHED_AT}${font}`) ?? 0) < 1) fail(`the production tab never requested ${font}`);
	}
	if (strays.length > 0) {
		fail(`the production tab asked outside ${PUBLISHED_AT}: ${strays.join(", ")}`);
	}
	if (browserFailures.length > 0) {
		fail(`browser failures:\n${browserFailures.join("\n")}`);
	}
	await context.close();
	await proveWebsiteLive(browser, httpPort, sturdyref);
	if (strays.length > 0) {
		fail(`the website's tab asked outside ${PUBLISHED_AT}: ${strays.join(", ")}`);
	}

	console.log(JSON.stringify({
		sturdyref,
		wasmRequests,
		replay,
		live,
		observerSessionAbsent: replay.sessions.length === 1 &&
			live.sessions.length === 2,
		replayRendered: true,
		liveRendered: true,
		websiteLive: ["refused elsewhere", "unanswered prompt named", "connected when allowed"],
	}));
	console.log(
		"PASS: production ocapnviz Live mode is a wasm-backed OCapN viewer",
	);
} finally {
	clearTimeout(deadline);
	publisher?.close();
	if (browser !== null) await browser.close();
	if (traceHost !== null) {
		await stopTraceHost(traceHost);
	}
	staticAbort.abort();
	await staticServer.finished.catch(() => {});
}
