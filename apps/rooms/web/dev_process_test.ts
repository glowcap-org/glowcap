import { assert, assertEquals } from "@std/assert";
import { fileURLToPath } from "node:url";
import { nonEphemeralPort } from "../../../bindings/ts/test/ports.ts";

function terminate(child: Deno.ChildProcess): void {
	try {
		child.kill("SIGTERM");
	} catch (error) {
		if (!(error instanceof Deno.errors.NotFound)) throw error;
	}
}

async function retireFixture(fixture: BackendFixture): Promise<void> {
	if (await waitForFile(fixture.retired)) return;
	const pid = Number(await Deno.readTextFile(`${fixture.retired}.pid`));
	try {
		Deno.kill(pid, "SIGTERM");
	} catch (error) {
		if (!(error instanceof Deno.errors.NotFound)) throw error;
	}
	await waitForFile(fixture.retired);
}

async function waitForFile(path: string): Promise<boolean> {
	const deadline = Date.now() + 5_000;
	while (Date.now() < deadline) {
		try {
			await Deno.stat(path);
			return true;
		} catch (error) {
			if (!(error instanceof Deno.errors.NotFound)) throw error;
		}
		await new Promise((resolve) => setTimeout(resolve, 10));
	}
	return false;
}

async function waitFor(url: string): Promise<Response> {
	const deadline = Date.now() + 15_000;
	let last = "no request attempted";
	while (Date.now() < deadline) {
		try {
			const response = await fetch(url, { headers: { accept: "text/html" } });
			if (response.ok) return response;
			last = `HTTP ${response.status}`;
		} catch (error) {
			last = error instanceof Error ? error.message : String(error);
		}
		await new Promise((resolve) => setTimeout(resolve, 50));
	}
	throw new Error(`Vite did not serve ${url}: ${last}`);
}

interface BackendFixture {
	root: string;
	executable: string;
	retired: string;
	argumentLog: string;
}

async function createBackendFixture(): Promise<BackendFixture> {
	const root = await Deno.makeTempDir({ prefix: "glowcap-rooms-vite-dev-" });
	const executable = `${root}/rooms-web-fixture`;
	const retired = `${root}/retired`;
	const argumentLog = `${root}/arguments`;
	const program = `#!/usr/bin/env -S deno run -A
const retired = ${JSON.stringify(retired)};
const argumentLog = ${JSON.stringify(argumentLog)};
await Deno.writeTextFile(argumentLog, Deno.args.join("\\n") + "\\n");
await Deno.writeTextFile(retired + ".pid", String(Deno.pid));
const stopping = new AbortController();
Deno.addSignalListener("SIGTERM", async () => {
	await Deno.writeTextFile(retired + ".starting", "retiring\\n");
	await new Promise((resolve) => setTimeout(resolve, 250));
	await Deno.writeTextFile(retired, "retired\\n");
	stopping.abort();
});
const server = Deno.serve({
	hostname: "127.0.0.1",
	port: 0,
	signal: stopping.signal,
	onListen: ({ port }) => {
		const reached = Deno.args.find((arg) => arg.startsWith("--http-public="))?.slice("--http-public=".length).replace(/\\/$/, "");
		console.log(\`ROOMS-WEB-LISTENING \${port}\\nrooms: serving\\n\\n  web ui           \${reached}\\n\\nrooms: ready\`);
	},
}, (request) => {
	const url = new URL(request.url);
	if (url.pathname === "/locator") return new Response("ocapn://development.fixture\\n");
	if (url.pathname === "/link-preview") {
		return Response.json({ host: request.headers.get("host"), origin: request.headers.get("origin") });
	}
	return new Response("fixture\\n");
});
await server.finished;
`;
	await Deno.writeTextFile(executable, program);
	await Deno.chmod(executable, 0o700);
	return { root, executable, retired, argumentLog };
}

function developmentCommand(fixture: BackendFixture, port: number, env: Record<string, string> = {}): Deno.Command {
	const repository = new URL("../../../", import.meta.url);
	// Each scene names every Rooms variable its front reads. One the caller's
	// shell or container exports would otherwise decide what the scene proves.
	const ambient = Object.fromEntries(
		Object.entries(Deno.env.toObject()).filter(([name]) => !name.startsWith("GLOWCAP_ROOMS_")),
	);
	return new Deno.Command(Deno.execPath(), {
		args: [
			"run",
			"-A",
			`--config=${fileURLToPath(new URL("apps/rooms/deno.json", repository))}`,
			fileURLToPath(new URL("apps/rooms/web/dev.ts", repository)),
			fixture.executable,
			String(port),
		],
		cwd: fixture.root,
		clearEnv: true,
		env: { ...ambient, GLOWCAP_ROOMS_DEV_HOST: "127.0.0.1", ...env },
		stdin: "null",
		stdout: "piped",
		stderr: "piped",
	});
}

Deno.test("rooms-dev serves source modules and finishes retirement across repeated signals", async () => {
	const fixture = await createBackendFixture();
	const port = nonEphemeralPort();
	const child = developmentCommand(fixture, port, {
		GLOWCAP_ROOMS_DEV_TRACE_CONNECT: "wss://trace.example/captp",
		GLOWCAP_ROOMS_DEV_TRACE_PUBLISH: "wss://trace.example/publish",
	}).spawn();
	const stdout = new Response(child.stdout).text();
	const stderr = new Response(child.stderr).text();
	try {
		const page = await waitFor(`http://127.0.0.1:${port}/room/development`);
		const html = await page.text();
		assert(html.includes("@react-refresh"), "the page did not receive the React Fast Refresh preamble");
		assert(
			html.includes('dataset.roomsWasm="/rooms_browser_bg.wasm"'),
			"the page did not receive its development Wasm route",
		);

		const script = await fetch(`http://127.0.0.1:${port}/page.js`);
		assertEquals(script.status, 200);
		assert((await script.text()).includes("main.tsx"), "Vite did not serve the shared page entry");
		const ground = await fetch(`http://127.0.0.1:${port}/ground.js`);
		assertEquals(ground.status, 200);
		await ground.text();
		const main = await fetch(`http://127.0.0.1:${port}/main.tsx`);
		assertEquals(main.status, 200);
		const startup = await main.text();
		assert(startup.includes("createRoot"), "Vite did not transform the Rooms React module");
		assert(
			!startup.includes("import.meta.hot.accept"),
			"page startup must reload instead of opening a second Host",
		);
		const setup = await fetch(`http://127.0.0.1:${port}/panes/SessionSetup.tsx`);
		assertEquals(setup.status, 200);
		assert((await setup.text()).includes("import.meta.hot.accept"), "component edits must retain Fast Refresh");

		for (
			const [path, symbol] of [
				["mark/live.ts", "start"],
				["mycelium/live.ts", "startMycelium"],
				["gpu/device.ts", "keepOnPageDevice"],
			]
		) {
			const shared = fileURLToPath(new URL(`../../../ui/${path}`, import.meta.url));
			const module = await fetch(`http://127.0.0.1:${port}/@fs${shared}`);
			assertEquals(module.status, 200, `shared UI module ${path} must be served during development`);
			assert((await module.text()).includes(symbol), `shared UI module ${path} was not transformed`);
		}

		const wasm = await fetch(`http://127.0.0.1:${port}/rooms_browser_bg.wasm`);
		assertEquals(wasm.status, 200);
		assertEquals(wasm.headers.get("content-type"), "application/wasm");
		const etag = wasm.headers.get("etag");
		assert(etag, "the development Wasm route did not retain Vite's cache validator");
		await wasm.body?.cancel();
		const unchanged = await fetch(`http://127.0.0.1:${port}/rooms_browser_bg.wasm`, {
			headers: { "if-none-match": etag },
		});
		assertEquals(unchanged.status, 304);
		assertEquals(await unchanged.text(), "");

		const locator = await fetch(`http://127.0.0.1:${port}/locator`);
		assertEquals(await locator.text(), "ocapn://development.fixture\n");

		// The page and `/ui-version` name one build, the Wasm application's, so
		// an open page reloads only when the application's bytes change.
		const version = (await (await fetch(`http://127.0.0.1:${port}/ui-version`)).text()).trim();
		assert(/^vite-development-[0-9a-f]{16}$/.test(version), `the development build is unnamed: ${version}`);
		assert(
			html.includes(`dataset.uiBuild=${JSON.stringify(version)}`),
			"the page and /ui-version name different builds",
		);

		const origin = `http://127.0.0.1:${port}`;
		const preview = await fetch(`${origin}/link-preview?url=https://example.test`, {
			headers: { origin },
		});
		assertEquals(await preview.json(), { host: `127.0.0.1:${port}`, origin });
	} finally {
		terminate(child);
		const retiring = await waitForFile(`${fixture.retired}.starting`);
		terminate(child);
		const result = await child.status;
		const output = await stdout;
		const errors = await stderr;
		const launchArguments = await Deno.readTextFile(fixture.argumentLog);
		let backendRetired = false;
		try {
			backendRetired = (await Deno.readTextFile(fixture.retired)).trim() === "retired";
		} catch {
			// The assertion below owns the missing marker.
		}
		await Deno.remove(fixture.root, { recursive: true });
		assertEquals(result.code, 0, `rooms-dev failed:\n${output}\n${errors}`);
		assert(
			!`${output}\n${errors}`.includes("Pre-transform error"),
			`nested page assets failed Vite's warm-up:\n${output}\n${errors}`,
		);
		assert(retiring, "the repeated signal must arrive during backend retirement");
		assert(
			/(^|\n)rooms-dev: web server http:\/\/127\.0\.0\.1:\d+ \(internal\)\n/.test(output),
			"rooms-dev did not label its internal listener",
		);
		assert(!output.includes("ROOMS-WEB-LISTENING"), "rooms-dev announced the internal listener as its own");
		assert(
			output.includes(`  web ui           http://localhost:${port}\n`),
			"the backend was not told the address browsers reach this front at",
		);
		assert(
			launchArguments.includes("--no-browser-assets\n"),
			"rooms-dev loaded an unused production asset generation",
		);
		assert(launchArguments.includes("--trace-connect=wss://trace.example/captp\n"));
		assert(launchArguments.includes("--trace-publish=wss://trace.example/publish\n"));
		assert(!launchArguments.includes("--prepared\n"), "rooms-dev launched the production publisher");
		assert(backendRetired, "rooms-dev did not retire its web server");
	}
});

Deno.test("rooms-dev retires its web server when Vite cannot take the public port", async () => {
	const fixture = await createBackendFixture();
	const occupied = Deno.listen({ hostname: "127.0.0.1", port: 0 });
	const port = (occupied.addr as Deno.NetAddr).port;
	const child = developmentCommand(fixture, port).spawn();
	const stdout = new Response(child.stdout).text();
	const stderr = new Response(child.stderr).text();
	let ended = false;
	try {
		const result = await child.status;
		ended = true;
		const output = await stdout;
		const errors = await stderr;
		assertEquals(result.code, 1, `rooms-dev unexpectedly survived an occupied port:\n${output}\n${errors}`);
		assert(
			errors.includes("Vite exited while rooms-web was serving"),
			`rooms-dev hid the Vite failure:\n${errors}`,
		);
		assertEquals((await Deno.readTextFile(fixture.retired)).trim(), "retired");
	} finally {
		if (!ended) {
			terminate(child);
			await child.status;
		}
		occupied.close();
		await Deno.remove(fixture.root, { recursive: true });
	}
});

Deno.test("rooms-dev retires its backend when the status output closes", async () => {
	const fixture = await createBackendFixture();
	// Close the operating-system descriptor while the backend stays alive.
	// Deno's stdout resource wrapper does not close the inherited descriptor.
	await Deno.writeTextFile(
		fixture.executable,
		`#!/usr/bin/env python3
import os, signal
from pathlib import Path
retired = Path(${JSON.stringify(fixture.retired)})
Path(str(retired) + ".pid").write_text(str(os.getpid()))
# The front sends SIGTERM the moment it sees the close. Blocked, the signal
# stays pending for sigwait. A handler with signal.pause() loses one that
# lands between the close and the pause, and the front waits out its grace.
signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM})
os.close(1)
signal.sigwait({signal.SIGTERM})
retired.write_text("retired\\n")
`,
	);
	const child = developmentCommand(fixture, nonEphemeralPort()).spawn();
	const stdout = new Response(child.stdout).text();
	const stderr = new Response(child.stderr).text();
	const timer = setTimeout(() => terminate(child), 5_000);
	try {
		const result = await child.status;
		clearTimeout(timer);
		assertEquals(result.code, 1);
		assert(await waitForFile(fixture.retired), "the output failure must retire the backend before exit");
	} finally {
		clearTimeout(timer);
		// The red run demonstrates an abandoned backend. Retire exactly that
		// fixture if the front failed to do so, before removing its files.
		await retireFixture(fixture);
		await stdout;
		await stderr;
		await Deno.remove(fixture.root, { recursive: true });
	}
	const errors = await stderr;
	assert(errors.includes("rooms-web closed its startup and status output"), errors);
});
