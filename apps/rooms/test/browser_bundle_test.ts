// The deployable Rooms page is a browser artifact, so building successfully is
// not enough: Deno may leave host-runtime imports external and let the browser
// fail only after deployment. Build the exact minified graph and inspect what
// the browser would receive.
//
// The graph is layered at the waits a reader can name. `main.js` plus the
// modules it statically imports is boot: the opening screen covers that, the
// wasm runtime, and the next named chunk. A returning visit then loads
// `established-*` (the session shell). Session choice, Operations, each pane,
// the directory's operator and inspect halves, and the parts catalog stay off
// that path until the control that opens them. Gzip is summed per chunk, so a
// split graph compresses a little less than the same bytes in one file.

import { assertEquals } from "./assert.ts";

const ROOT = new URL("../../../", import.meta.url).pathname;
const CONFIG = `${ROOT}apps/rooms/web/browser-bundle.json`;
const ENTRY = `${ROOT}apps/rooms/web/ui/main.tsx`;

const NAMED_CHUNKS = [
	"SessionSetup-",
	"established-",
	"OpsPage-",
	"KitchenBundle-",
	"Listeners-",
	"Gateway-",
	"Peering-",
	"Viz-",
	"Operator-",
	"Diagnostics-",
] as const;

// Raised by a thousand where two changes met: a room stating what the bridge
// behind it calls its own, and the join card's Connect waiting on a directory.
// Each fit alone and the pair did not, which is what a budget this tight is for.
// The bridge half is read on the first paint of any room — the roster, the
// author line, and mention completion all ask the same one reading — so it is
// boot rather than something a later chunk can carry. Compressed moves with it,
// by a thousand, for the same pair.
// Raised again for the form vocabulary and the two verbs that carry one. It is
// boot because a room's own client reaches them, and because the schema that
// checks a form is the same object whether or not anybody opens one.
// Raised again so a restored directory that has never answered says connecting
// rather than reconnecting. That split is the first paint of a refresh, and it
// lives on the boot graph because restore does — the same mapping live
// projection uses, not a second copy of the four words.
// Raised for the sink a file's bytes are read to. A read used to be owned by
// the connection the file arrived over, so a file kept on this device could only
// be read while a directory happened to be reachable — and a cold start, which
// reads the archive before its first connection lands, recorded "no session yet"
// as "these bytes are gone" and meant it permanently. The bytes buy one seam
// with two owners: the session, and the disk.
// Raised for what an access link can now be told to carry. A grant's tier, its
// history, and whether it is suspended are read from the ledger when a verb is
// admitted rather than captured when the link was minted, so an administrator
// can narrow one, pause it with a reason, or hand its history back while
// somebody is holding it, and the link itself never moves.
// Raised by seven thousand so a refresh of a tab that was hosting converts that
// selector to local reconstruction: the wasm Host is not persisted, and a
// leftover sturdyref would dial nobody. A hosted session names the same locator
// DMs already advertise, so sharing does not add a second door. The session
// actor stays off this graph until Share; compressed moves by five thousand
// for the same pair.
// A thousand more so the WebRTC connector can signal through this page's
// directory or a signaling-only Attach membership, not only the one live
// directory.
// Raised for the one reading of whether this browser's access is paused. It is
// boot because the surfaces that ask are: the two rail lists, the roster, and
// the card the page falls back to when there is no room, all of which are on
// the first paint of a returning visit.
// Raised by two thousand so Attach names a missing WebRTC signaling inbox
// instead of a truncated paste, and so the hosted runtime that files that
// inbox after Share is reachable from the same session graph restore already
// pays for. Compressed moves by three thousand for the same pair.
// Raised by a thousand so Share can keep the WebRTC answering inbox on a stolen
// directory session. Closing that inbox while keeping the CapTP session is what
// left Attach able to offer and this tab unable to answer.
// Raised by a thousand so a Share sturdyref can name the host's directory as
// the WebRTC signaling route. Without that hint Attach guessed the attaching
// tab's page, so a host on another directory had to join the attacher's.
// Two thousand more so a room row keeps one identity when its publication id
// is resolved later, adopting the link-era row instead of minting a duplicate
// rail sibling, and so the IRC identity acts ride the session's bridge-form
// command on an attached view.
const MAX_BOOT_MINIFIED_BYTES = 824_000;
// A thousand more compressed alongside the room-row adoption and the IRC
// identity acts riding the session's bridge-form command.
const MAX_BOOT_GZIP_BYTES = 264_000;
// Raised by a thousand for the layer a menu opens into. A menu hangs below the
// control that opened it and is routinely taller than the card holding it,
// which used to mean every such card had to promise never to clip. That promise
// was the wrong way round: it made a card's overflow depend on what somebody
// had put inside it. The bytes buy one box in the browser's top layer, standing
// where the control stands, and the freedom for a card to clip.
// Raised again for the body a modal card's rows now sit in: one element per
// card, ten cards. What it buys is the card being a shell rather than the box
// its rows scroll in, which is what lets the stripe above them be an ordinary
// absolute box instead of a transparent border with a gradient painted into it.
// Raised again so Connect on the join card waits for a directory to answer and
// says so on the locator when it does not: writing a workspace record was not
// the reach, and a form-level leftover was not the act.
// Raised again for a room saying what the bridge behind it calls its own. The
// page used to know that `irc/` was an attribution prefix and that a member
// wearing one is "IRC only"; it now reads both off the room. The bytes buy a
// second bridge being able to name its own members without a client release,
// and the page not knowing IRC exists. Those last two arrived together and each
// had sized this for itself alone, so it takes another thousand for the pair,
// and the compressed figure below moves with it for the same reason. A thousand
// more again for the form vocabulary and its two verbs.
// Raised again so a first Connect on a shared session says connecting, not
// reconnecting: the snapshot used to treat every not-yet-live directory as a
// drop.
// A few hundred more for splitting a bridge submission by the form's own
// declaration of which field is a credential. It replaces each surface building
// the remembered and sent halves by hand, which was a convention whose failure
// mode is a password written to disk.
// Raised for the card that administers one access link. What a link carries is
// four separate answers, every one of them changeable while somebody holds it,
// and that is a card's worth of decisions rather than a row's: putting them in
// the row buried the list they are compared in.
// Raised by eight thousand for a returning visit that can share this tab: the
// hosted selector, the Share door, and the same restore conversion boot already
// paid for. Compressed moves by five thousand.
// A thousand more so that tab can change connection and import without
// reloading — a reload here ends sharing — and so Attach says so.
// A thousand more so Attach uses the same WebRTC door DMs already advertise:
// a paste-only attacher holds a signaling-only directory membership, not a
// second copy of the hosted session's rooms.
// Compressed moves by a few hundred for what a paused link is shown. A view
// with no access is answered with no session, so every surface that would
// otherwise be empty for an ordinary reason — the two rail lists, the roster,
// and the card the page falls back to — has to say which emptiness this is
// rather than invite an act that is closed.
// Two thousand more so the hosted runtime files the WebRTC signaling inbox
// when it reconnects directories after Share. Compressed moves by three thousand.
// A thousand more so Share keeps that inbox on the stolen session instead of
// closing it while keeping the CapTP wrapper.
// A thousand more so the Share sturdyref names the host's directory for Attach
// signaling, instead of the attaching tab guessing its own page.
// A thousand more so a refused workspace save names its bound and the shed
// route, and a nickname names the session holding it, your own included.
// A thousand more for the room row that keeps one identity across a
// publication backfill and the IRC identity acts on an attached view.
// A thousand more so the shared bridge-form renderer honors a declared
// second step on any action, primary and Enter included, instead of running
// a destructive act on first press.
const MAX_RETURNING_MINIFIED_BYTES = 1_144_000;
// A thousand more compressed for the same two acts the minified raise names.
// A thousand more compressed for the declared second step the minified raise
// above names.
const MAX_RETURNING_GZIP_BYTES = 368_000;
const MAX_KITCHEN_BUNDLE_BYTES = 25_000;
const MAX_OPS_BUNDLE_BYTES = 8_000;
const MAX_SESSION_SETUP_BYTES = 8_000;
const MAX_OPERATOR_PANE_BYTES = 25_000;

const STATIC_FROM = /from"\.\/([^"]+\.js)"/g;

function staticImports(source: string): string[] {
	const found: string[] = [];
	STATIC_FROM.lastIndex = 0;
	let match: RegExpExecArray | null;
	while ((match = STATIC_FROM.exec(source)) !== null) found.push(match[1]);
	return found;
}

function closure(start: string, sources: Map<string, string>): Set<string> {
	const seen = new Set<string>();
	const stack = [start];
	while (stack.length > 0) {
		const name = stack.pop();
		if (name == null || seen.has(name)) continue;
		seen.add(name);
		const source = sources.get(name);
		if (source == null) continue;
		for (const next of staticImports(source)) {
			if (sources.has(next)) stack.push(next);
		}
	}
	return seen;
}

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

Deno.test("the Rooms browser bundle contains no host imports and stays within its payload budget", async () => {
	const outdir = await Deno.makeTempDir({ prefix: "glowcap-rooms-bundle-test-" });
	try {
		const result = await new Deno.Command(Deno.execPath(), {
			args: [
				"bundle",
				"--platform",
				"browser",
				"--quiet",
				"--minify",
				"--code-splitting",
				"--config",
				CONFIG,
				"--outdir",
				outdir,
				ENTRY,
			],
			cwd: ROOT,
			stdout: "null",
			stderr: "piped",
		}).output();
		const stderr = new TextDecoder().decode(result.stderr).trim();
		assertEquals(result.success, true, stderr || "the Rooms browser bundle did not build");
		const files = new Map<string, Uint8Array>();
		const sources = new Map<string, string>();
		for await (const entry of Deno.readDir(outdir)) {
			if (!entry.isFile || !entry.name.endsWith(".js")) continue;
			const bytes = await Deno.readFile(`${outdir}/${entry.name}`);
			const bundle = new TextDecoder().decode(bytes);
			const hostImport = bundle.match(/\b(?:from|import)\s*["']((?:node:|bun:ffi)[^"']*)["']/)?.[1];
			if (hostImport != null) throw new Error(`${entry.name} retained the host import ${hostImport}`);
			files.set(entry.name, bytes);
			sources.set(entry.name, bundle);
		}
		if (!files.has("main.js")) throw new Error("the Rooms browser bundle produced no main entry");
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
		const boot = closure("main.js", sources);
		if ([...boot].some((name) => NAMED_CHUNKS.some((prefix) => name.startsWith(prefix)))) {
			throw new Error(`boot statically includes a deferred chunk: ${[...boot].sort().join(", ")}`);
		}
		const established = [...files.keys()].find((name) => name.startsWith("established-"));
		if (established == null) throw new Error("the Rooms browser bundle produced no established chunk");
		const returning = new Set([...boot, ...closure(established, sources)]);
		const bootSize = await graphBytes(boot, files);
		if (bootSize.minified > MAX_BOOT_MINIFIED_BYTES) {
			throw new Error(`the boot graph is ${bootSize.minified} bytes; budget ${MAX_BOOT_MINIFIED_BYTES}`);
		}
		if (bootSize.gzip > MAX_BOOT_GZIP_BYTES) {
			throw new Error(`the compressed boot graph is ${bootSize.gzip} bytes; budget ${MAX_BOOT_GZIP_BYTES}`);
		}
		const returningSize = await graphBytes(returning, files);
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
