// What a browser proof of the web binding needs before it opens a page: a
// loud failure, a free loopback port, and the probe script bundled for the
// browser through this package's browser-bundle config, which stubs the
// runtime's non-browser FFI adapters (node:net, bun:ffi) so the single-file
// bundle resolves without a runtime the browser lacks.

export const BROWSER_BUNDLE_CONFIG = new URL("../browser-bundle.json", import.meta.url).pathname;

export function fail(message: string): never {
	console.error(`FAIL: ${message}`);
	Deno.exit(1);
}

export function freePort(): number {
	const listener = Deno.listen({ hostname: "127.0.0.1", port: 0 });
	const port = (listener.addr as Deno.NetAddr).port;
	listener.close();
	return port;
}

/** Bundle `probe` for the browser and return the single-file source. */
export async function bundleProbe(probe: string): Promise<string> {
	const { code, stdout, stderr } = await new Deno.Command(Deno.execPath(), {
		args: ["bundle", "--platform", "browser", "--no-lock", "--quiet", "--config", BROWSER_BUNDLE_CONFIG, probe],
		stdout: "piped",
		stderr: "piped",
	}).output();
	if (code !== 0) {
		fail("deno bundle of the browser probe failed: " + new TextDecoder().decode(stderr).trim());
	}
	return new TextDecoder().decode(stdout);
}
