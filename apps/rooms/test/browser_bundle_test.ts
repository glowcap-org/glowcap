// A successful build is not enough. A bundler may leave host-runtime imports
// external and let the browser fail only after deployment. Build and inspect
// the exact minified graph that the browser would receive.
//
// The graph is layered at the waits a reader can name. `page.js` plus the
// modules it statically imports is boot: the opening screen covers that, the
// wasm runtime, and the next named chunk. A returning visit then loads
// `established-*` (the session shell). The generated Rust application glue loads
// with the Wasm artifact after the opening screen. Session choice, Operations, each pane,
// the directory's operator and inspect halves, and the parts catalog stay off
// that path until the control that opens them. Gzip is summed per chunk, so a
// split graph compresses a little less than the same bytes in one file.

import { ROOT, WEB } from "./support/paths.ts";
import { bundleGraph, closure } from "./support/bundle_graph.ts";
import { denoBrowserSource } from "./support/deno_browser_source.ts";

const WEB_ROOT = `${ROOT}apps/rooms/web/`;

const NAMED_CHUNKS = [
	"rooms_browser-",
	"SessionSetup-",
	"established-",
	"OpsPage-",
	"KitchenBundle-",
	"Listeners-",
	"Gateway-",
	"Peering-",
	"Trace-",
	"Operator-",
	"Diagnostics-",
] as const;

/** Payload ceilings protect the two waits visible on an ordinary visit: boot
 * reaches the opening screen, while returning adds the established session
 * shell. Named operations and setup chunks remain outside both graphs. A new
 * feature must fit that loading model or change it. This test is
 * not a changelog for incremental budget raises. */
const MAX_BOOT_MINIFIED_BYTES = 826_000;
const MAX_BOOT_GZIP_BYTES = 265_000;
const MAX_RETURNING_MINIFIED_BYTES = 1_148_000;
const MAX_RETURNING_GZIP_BYTES = 370_000;
const MAX_KITCHEN_BUNDLE_BYTES = 25_000;
const MAX_OPS_BUNDLE_BYTES = 8_000;
const MAX_SESSION_SETUP_BYTES = 8_000;
const MAX_OPERATOR_PANE_BYTES = 25_000;

Deno.test("bundle accounting follows ESM edges across minifiers and rejects unresolved imports", () => {
	const sources = new Map([
		[
			"page.js",
			`import './side.js'; export { value } from "./shared.js"; import('./lazy.js');
			const text = 'from"./fiction.js"'; /* import './comment.js' */`,
		],
		["side.js", 'import"./shared.js";'],
		["shared.js", "export const value = 1;"],
		["lazy.js", "console.log(import.meta.url); import(runtimeRoute);"],
	]);
	const boot = [...closure("page.js", bundleGraph(sources))].sort();
	if (boot.join() !== "page.js,shared.js,side.js") throw new Error(`wrong boot graph: ${boot}`);
	for (
		const source of [
			`import './missing.js'`,
			`export * from 'node:fs'`,
			`import('bun:ffi')`,
			`import 'react'`,
			`import('https://example.test/module.js')`,
		]
	) {
		let refused = false;
		try {
			bundleGraph(new Map([["page.js", source]]));
		} catch {
			refused = true;
		}
		if (!refused) throw new Error(`bundle inspection accepted ${source}`);
	}
});

async function gzipBytes(bytes: Uint8Array): Promise<number> {
	const own = new Uint8Array(bytes.byteLength);
	own.set(bytes);
	return (await new Response(
		new Blob([own.buffer]).stream().pipeThrough(new CompressionStream("gzip")),
	).arrayBuffer()).byteLength;
}

async function graphBytes(
	names: Iterable<string>,
	files: Map<string, Uint8Array>,
): Promise<{ minified: number; gzip: number }> {
	let minified = 0;
	let gzip = 0;
	for (const name of names) {
		const bytes = files.get(name);
		if (bytes == null) continue;
		minified += bytes.byteLength;
		gzip += await gzipBytes(bytes);
	}
	return { minified, gzip };
}

function namedSize(files: Map<string, Uint8Array>, prefix: string): number {
	let total = 0;
	for (const [name, bytes] of files) {
		if (name.startsWith(prefix)) total += bytes.byteLength;
	}
	return total;
}

for (const compiler of ["configured", "deno"] as const) {
	Deno.test(`the ${compiler} Rooms compiler publishes a complete graph within the payload budget`, async () => {
		const outdir = await Deno.makeTempDir({ prefix: "glowcap-rooms-bundle-test-" });
		try {
			const source = compiler === "deno" ? await denoBrowserSource(outdir) : WEB_ROOT;
			const built = await new Deno.Command(WEB, {
				args: [`--prepare=${outdir}/published`, `--assets=${source}`],
				stdout: "piped",
				stderr: "piped",
			}).output();
			if (!built.success) throw new Error(new TextDecoder().decode(built.stderr));
			const directory = `${outdir}/published/current`;
			const files = new Map<string, Uint8Array>();
			const sources = new Map<string, string>();
			for await (const entry of Deno.readDir(directory)) {
				if (!entry.isFile || !entry.name.endsWith(".js")) continue;
				const bytes = await Deno.readFile(`${directory}/${entry.name}`);
				const bundle = new TextDecoder().decode(bytes);
				files.set(entry.name, bytes);
				sources.set(entry.name, bundle);
			}
			if (!files.has("page.js")) throw new Error("the Rooms browser bundle produced no page entry");
			for (const prefix of NAMED_CHUNKS) {
				if (namedSize(files, prefix) === 0) {
					throw new Error(`the Rooms browser bundle produced no ${prefix}* chunk`);
				}
			}
			const kitchenBytes = namedSize(files, "KitchenBundle-");
			if (kitchenBytes > MAX_KITCHEN_BUNDLE_BYTES) {
				throw new Error(`the async parts catalog is ${kitchenBytes} bytes; budget ${MAX_KITCHEN_BUNDLE_BYTES}`);
			}
			const opsBytes = namedSize(files, "OpsPage-");
			if (opsBytes > MAX_OPS_BUNDLE_BYTES) {
				throw new Error(`the async operations surface is ${opsBytes} bytes; budget ${MAX_OPS_BUNDLE_BYTES}`);
			}
			const sessionSetupBytes = namedSize(files, "SessionSetup-");
			if (sessionSetupBytes > MAX_SESSION_SETUP_BYTES) {
				throw new Error(`session choice is ${sessionSetupBytes} bytes; budget ${MAX_SESSION_SETUP_BYTES}`);
			}
			const operatorBytes = namedSize(files, "Operator-");
			if (operatorBytes > MAX_OPERATOR_PANE_BYTES) {
				throw new Error(`the operator pane is ${operatorBytes} bytes; budget ${MAX_OPERATOR_PANE_BYTES}`);
			}
			if (namedSize(files, "Directory-") > 0) {
				throw new Error("the directory pane shell must stay in the operations chunk");
			}
			const graph = bundleGraph(sources);
			const boot = closure("page.js", graph);
			if ([...boot].some((name) => NAMED_CHUNKS.some((prefix) => name.startsWith(prefix)))) {
				throw new Error(`boot statically includes a deferred chunk: ${[...boot].sort().join(", ")}`);
			}
			const established = [...files.keys()].find((name) => name.startsWith("established-"));
			if (established == null) throw new Error("the Rooms browser bundle produced no established chunk");
			const returning = new Set([...boot, ...closure(established, graph)]);
			const bootSize = await graphBytes(boot, files);
			if (bootSize.minified > MAX_BOOT_MINIFIED_BYTES) {
				throw new Error(`the boot graph is ${bootSize.minified} bytes; budget ${MAX_BOOT_MINIFIED_BYTES}`);
			}
			if (bootSize.gzip > MAX_BOOT_GZIP_BYTES) {
				throw new Error(`the compressed boot graph is ${bootSize.gzip} bytes; budget ${MAX_BOOT_GZIP_BYTES}`);
			}
			const returningSize = await graphBytes(returning, files);
			console.log(
				`Rooms payload bytes: boot ${JSON.stringify(bootSize)}, returning ${JSON.stringify(returningSize)}`,
			);
			if (returningSize.minified > MAX_RETURNING_MINIFIED_BYTES) {
				throw new Error(
					`the returning session graph is ${returningSize.minified} bytes; budget ${MAX_RETURNING_MINIFIED_BYTES}`,
				);
			}
			if (returningSize.gzip > MAX_RETURNING_GZIP_BYTES) {
				throw new Error(
					`the compressed returning session graph is ${returningSize.gzip} bytes; budget ${MAX_RETURNING_GZIP_BYTES}`,
				);
			}
		} finally {
			await Deno.remove(outdir, { recursive: true });
		}
	});
}
