// Tests for rooms-web's non-page surface: served assets and the byte relay a
// browser peer dials the room server through. Room-server lifecycle and
// takeover live in serve_supervision_test.ts so each process keeps a meaningful
// deterministic deadline.
//
// The page itself is a browser peer now — its end-to-end proof is
// `zig build rooms-web-page` (a real headless Chromium joining a room and
// round-tripping a line over the room capability). There is no JSON bridge
// left to test here; reachability is checked the way the page reaches the
// room: a keyed OCapN session established over `/relay`.

import { parseOpsBundle } from "../../web/ui/ops/bundle.ts";
import { assertEquals } from "../assert.ts";
import { spawnOwned, stopOwned } from "../support/children.ts";
import { freePort } from "../support/rooms_server.ts";
import { reachRoomThroughRelay, ROOT, waitForIndex, WEB, withWeb } from "./serve_harness.ts";

function assert(condition: unknown, message: string): asserts condition {
	if (!condition) throw new Error(message);
}

Deno.test("the web supervisor prints one pasteable capability bundle", async () => {
	const httpPort = freePort();
	const roomPort = freePort();
	const state = await Deno.makeTempDir({ prefix: "glowcap-rooms-web-output-" });
	const proc = spawnOwned(WEB, {
		args: ["--transport=tcp", String(httpPort), String(roomPort), "--operator"],
		cwd: ROOT,
		env: { GLOWCAP_ROOMS_STATE: state },
		stdout: "piped",
		stderr: "piped",
	});
	const stdout = new Response(proc.stdout).text();
	const stderr = new Response(proc.stderr).text();
	let output = "";
	try {
		try {
			await waitForIndex(httpPort);
		} finally {
			await stopOwned(proc);
		}
		output = `${await stdout}\n${await stderr}`;
	} finally {
		await Deno.remove(state, { recursive: true });
	}
	const operators = [...output.matchAll(/^ROOMS-OPERATOR (ocapn:\/\/\S+)$/gm)];
	assertEquals(operators.length, 1);
	assertEquals(parseOpsBundle(output).get("operator"), operators[0][1]);
	assert(!output.includes("operator capabilities, paste"), "the supervisor printed a second capability projection");
});

Deno.test("the IRC Operations stylesheet is a served asset", async () => {
	await withWeb(async (httpPort) => {
		await waitForIndex(httpPort);
		const response = await fetch(`http://127.0.0.1:${httpPort}/operations-irc.css`);
		assertEquals(response.headers.get("content-type"), "text/css; charset=utf-8");
		assert((await response.text()).includes(".irc-connection"), "the IRC asset did not contain its card styles");
	});
});

// A program handed this address reads /llms.txt (https://llmstxt.org/) and
// learns what the server is and how to join, in the shape that site expects:
// an H1, a blockquote summary, then sections of links.
Deno.test("the web front describes itself at /llms.txt in the llms.txt shape", async () => {
	await withWeb(async (httpPort) => {
		await waitForIndex(httpPort);
		const response = await fetch(`http://127.0.0.1:${httpPort}/llms.txt`);
		assertEquals(response.status, 200);
		assertEquals(response.headers.get("content-type"), "text/markdown; charset=utf-8");
		const lines = (await response.text()).split("\n");
		assert(lines[0]?.startsWith("# "), "llms.txt does not open with an H1");
		assert(lines.some((line) => line.startsWith("> ")), "llms.txt carries no blockquote summary");
		assert(lines.some((line) => line.includes("/locator")), "llms.txt does not say where the locator is");
		assert(
			lines.some((line) => line.includes("glowcap apps rooms session")),
			"llms.txt does not say how a program joins",
		);
	});
});

Deno.test("the capability-bearing page confines executable content", async () => {
	await withWeb(async (httpPort) => {
		await waitForIndex(httpPort);
		const response = await fetch(`http://127.0.0.1:${httpPort}/`);
		const page = await response.text();
		const policy = response.headers.get("content-security-policy") ?? "";
		const scriptPolicy = policy.split(";").find((directive) => directive.trim().startsWith("script-src")) ?? "";
		const scripts = [...page.matchAll(/<script>([\s\S]*?)<\/script>/g)];
		assert(scripts.length > 0, "the page had no inline boot scripts to authorize");
		assertEquals(scriptPolicy.match(/'sha256-[^']+'/g)?.length ?? 0, scripts.length);
		for (const script of scripts) {
			const digest = new Uint8Array(
				await crypto.subtle.digest("SHA-256", new TextEncoder().encode(script[1])),
			);
			const hash = `'sha256-${btoa(String.fromCharCode(...digest))}'`;
			assert(scriptPolicy.includes(hash), "the policy hash did not authorize the page's exact inline script");
		}
		assert(!scriptPolicy.includes("'unsafe-inline'"), "the script policy admitted arbitrary inline code");
		assert(policy.includes("frame-ancestors 'none'"), "the page could be embedded by another origin");
		assertEquals(response.headers.get("cross-origin-opener-policy"), "same-origin");
		assertEquals(response.headers.get("referrer-policy"), "no-referrer");
		assertEquals(response.headers.get("x-content-type-options"), "nosniff");
	});
});

Deno.test("page assets revalidate and the script carries its deployment version", async () => {
	await withWeb(async (httpPort) => {
		await waitForIndex(httpPort);
		const version = (await (await fetch(`http://127.0.0.1:${httpPort}/ui-version`)).text()).trim();
		assert(/^(?:[0-9a-f]{12}(?:-dirty)?|source-[0-9a-f]{12})$/.test(version), "the UI version was not a build");
		const script = await (await fetch(`http://127.0.0.1:${httpPort}/page.js`)).text();
		assert(
			script.startsWith(
				`document.documentElement.dataset.uiBuild=${JSON.stringify(version)};\n`,
			),
			"the page script did not carry the version the deployment announced",
		);
		const url = `http://127.0.0.1:${httpPort}/tokens.css`;
		const first = await fetch(url);
		await first.text();
		const tag = first.headers.get("etag");
		assert(tag != null && tag.startsWith('"'), "the asset carried no validator");
		assertEquals(first.headers.get("cache-control"), "no-cache");
		const again = await fetch(url, { headers: { "if-none-match": tag } });
		assertEquals(again.status, 304);
		assertEquals(await again.text(), "");
		const moved = await fetch(url, { headers: { "if-none-match": '"stale-tag"' } });
		assertEquals(moved.status, 200);
		await moved.text();
	});
});

/** HTTP status of a WebSocket upgrade to `path`, sending a browser Origin.
 * Native clients omit Origin and already pass; this is the header a second
 * browser sends when Attach follows a tab-hosted session sturdyref. */
async function relayUpgradeStatus(port: number, path: string, origin: string): Promise<number> {
	const conn = await Deno.connect({ hostname: "127.0.0.1", port });
	try {
		const key = btoa("glowcap-origin16");
		await conn.write(
			new TextEncoder().encode(
				`GET ${path} HTTP/1.1\r\n` +
					`Host: 127.0.0.1:${port}\r\n` +
					`Upgrade: websocket\r\n` +
					`Connection: Upgrade\r\n` +
					`Sec-WebSocket-Version: 13\r\n` +
					`Sec-WebSocket-Key: ${key}\r\n` +
					`Origin: ${origin}\r\n` +
					`\r\n`,
			),
		);
		const buf = new Uint8Array(512);
		const n = await conn.read(buf);
		const head = new TextDecoder().decode(buf.subarray(0, n ?? 0));
		return Number(head.split(" ")[1]);
	} finally {
		conn.close();
	}
}

Deno.test("a glowcap peer reaches the room server through the /relay byte pipe", async () => {
	await withWeb(async (httpPort, roomPort) => {
		await waitForIndex(httpPort);
		// The relay refuses targets off the allow-list before upgrading.
		const refused = await fetch(
			`http://127.0.0.1:${httpPort}/relay?target=127.0.0.1:22`,
		);
		await refused.body?.cancel();
		assert(refused.status === 403, "off-list relay target should be refused");

		// A cross-origin page must not drive the relay, even at an allowed target.
		const crossOrigin = await fetch(
			`http://127.0.0.1:${httpPort}/relay?target=127.0.0.1:${roomPort}`,
			{ headers: { origin: "http://evil.example:1234" } },
		);
		await crossOrigin.body?.cancel();
		assert(
			crossOrigin.status === 403,
			"cross-origin relay upgrade should be refused",
		);

		// A rendezvous bridge is capability-addressed. The same Origin that
		// must not drive `?target=` is how a second browser attaches to a
		// tab-hosted session whose sturdyref named this relay.
		const rendezvousId = "aa".repeat(32);
		assertEquals(
			await relayUpgradeStatus(
				httpPort,
				`/relay?rendezvous=${rendezvousId}`,
				"http://evil.example:1234",
			),
			101,
			"a foreign Origin must still upgrade a rendezvous bridge",
		);

		const count = await reachRoomThroughRelay(httpPort, roomPort);
		assert(count >= 0, "the directory list should answer over the relay");
	});
});
