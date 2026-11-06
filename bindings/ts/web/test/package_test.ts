// portable-package-test serves only an extracted release archive. The shipped
// example must connect two real browser peers without bundling or checkout URLs.
import { chromium } from "playwright";
import { assertEquals } from "../../test/assert.ts";

const archive = Deno.args[0];
if (!archive) throw new Error("package_test needs the browser bundle archive");
const extracted = await Deno.makeTempDir({ prefix: "glowcap-browser-consumer-" });
let browser: Awaited<ReturnType<typeof chromium.launch>> | undefined;
let server: Deno.HttpServer | undefined;
try {
	const extraction = await new Deno.Command("tar", {
		args: ["-xzf", archive, "-C", extracted],
	}).output();
	assertEquals(extraction.code, 0);
	const allowed = new Map([
		["/", ["index.html", "text/html"]],
		["/example.js", ["example.js", "text/javascript"]],
		["/glowcap.js", ["glowcap.js", "text/javascript"]],
		["/glowcap_host.wasm", ["glowcap_host.wasm", "application/octet-stream"]],
	]);
	const unexpected: string[] = [];
	server = Deno.serve({ hostname: "127.0.0.1", port: 0 }, async (request) => {
		const path = new URL(request.url).pathname;
		if (path === "/favicon.ico") return new Response(null, { status: 204 });
		const asset = allowed.get(path);
		if (!asset) {
			unexpected.push(path);
			return new Response("not in browser bundle", { status: 404 });
		}
		return new Response(await Deno.readFile(`${extracted}/${asset[0]}`), { headers: { "content-type": asset[1] } });
	});
	browser = await chromium.launch({ args: ["--no-sandbox"] });
	const page = await browser.newPage();
	const origin = `http://127.0.0.1:${server.addr.port}`;
	await page.route("**/*", async (route) => {
		const url = new URL(route.request().url());
		if (url.origin === origin && (allowed.has(url.pathname) || url.pathname === "/favicon.ico")) {
			await route.continue();
		} else {
			unexpected.push(url.href);
			await route.abort();
		}
	});
	const errors: string[] = [];
	page.on("pageerror", (error: Error) => errors.push(error.message));
	await page.goto(`http://127.0.0.1:${server.addr.port}/`);
	await page.waitForFunction(() => document.querySelector("#result")?.textContent !== "Connecting…", null, {
		timeout: 20_000,
	});
	assertEquals(await page.locator("#result").textContent(), "hello world over WebRTC");
	assertEquals(errors.join("\n"), "");
	assertEquals(unexpected.join("\n"), "");
	console.log("Extracted browser bundle: two peers connected and called the greeter");
} finally {
	await browser?.close();
	await server?.shutdown();
	await Deno.remove(extracted, { recursive: true });
}
