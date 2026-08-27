#!/usr/bin/env -S deno run -A
/**
 * playwright-session-shift-click-probe.ts — Same matrix as the
 * peer shift-click probe, but targeting session lines and message
 * dots to find any cross-entity-type drift in the click pipeline.
 *
 * The user reported "something off with selection adding by
 * clicking ... peers vs sessions". This probe enumerates each
 * entity type × each modifier combo and prints what actually
 * lands in the store.
 */
import { chromium } from "playwright";

const url = Deno.args[0] ?? "http://127.0.0.1:5173/";
const browser = await chromium.launch({
	headless: true,
	args: ["--no-sandbox", "--disable-gpu"],
});
const ctx = await browser.newContext({
	viewport: { width: 1600, height: 1000 },
});
const page = await ctx.newPage();
page.on("pageerror", (e) => console.log("[pageerror]", e.message));

await page.addInitScript(() => {
	try {
		localStorage.removeItem("ocapnviz:app-state");
	} catch {
		// ignore
	}
});
await page.goto(url, { waitUntil: "networkidle" });
await page.waitForSelector("canvas#ocv-pixi");
await page.waitForTimeout(500);

await page.getByRole("radio", { name: "Build" }).click();
await page.waitForTimeout(200);
await page.evaluate(() => {
	(document.activeElement as HTMLElement | null)?.blur();
});

async function targets(): Promise<{
	peers: { id: string; sx: number; sy: number }[];
	sessions: { id: string; sx: number; sy: number }[];
	messages: { id: string; sx: number; sy: number }[];
}> {
	return await page.evaluate(() => {
		type Peer = {
			peer: { id: string };
			position?: { x: number; y: number };
		};
		type Session = {
			session: { id: string };
			endpoints: { a: string; b: string };
		};
		type Msg = {
			messageInFlight: { id: string };
			position?: { x: number; y: number };
		};
		type VP = { toScreen: (x: number, y: number) => { x: number; y: number } };
		const g = globalThis as unknown as {
			__ocv?: {
				engine?: {
					world?: {
						with(c: string): { find(p: (e: unknown) => boolean): unknown };
					};
					queries?: {
						peers?: Iterable<Peer>;
						sessions?: Iterable<Session>;
						messagesInFlight?: Iterable<Msg>;
					};
				};
			};
			__ocvViewport?: VP;
		};
		const q = g.__ocv?.engine?.queries;
		const vp = g.__ocvViewport;
		const peers: { id: string; sx: number; sy: number }[] = [];
		const sessions: { id: string; sx: number; sy: number }[] = [];
		const messages: { id: string; sx: number; sy: number }[] = [];
		if (!q || !vp) return { peers, sessions, messages };
		const peerById = new Map<string, { x: number; y: number }>();
		for (const p of q.peers ?? []) {
			if (p.position) peerById.set(p.peer.id, p.position);
		}
		for (const p of q.peers ?? []) {
			if (!p.position) continue;
			const s = vp.toScreen(p.position.x, p.position.y);
			peers.push({ id: p.peer.id, sx: s.x, sy: s.y });
		}
		for (const sess of q.sessions ?? []) {
			const a = peerById.get(sess.endpoints.a);
			const b = peerById.get(sess.endpoints.b);
			if (!a || !b) continue;
			// Use midpoint of the edge as the click target.
			const mx = (a.x + b.x) / 2;
			const my = (a.y + b.y) / 2;
			const s = vp.toScreen(mx, my);
			sessions.push({ id: sess.session.id, sx: s.x, sy: s.y });
		}
		for (const m of q.messagesInFlight ?? []) {
			if (!m.position) continue;
			const s = vp.toScreen(m.position.x, m.position.y);
			messages.push({ id: m.messageInFlight.id, sx: s.x, sy: s.y });
		}
		return { peers, sessions, messages };
	});
}

async function selection(): Promise<string[]> {
	return await page.evaluate(() => {
		const g = globalThis as unknown as {
			__ocv?: { selection?: { selection?: Iterable<string> } };
		};
		const set = g.__ocv?.selection?.selection;
		if (!set) return [];
		return [...set];
	});
}

async function clickAt(
	sx: number,
	sy: number,
	mods: { shift?: boolean; alt?: boolean } = {},
) {
	if (mods.shift) await page.keyboard.down("Shift");
	if (mods.alt) await page.keyboard.down("Alt");
	await page.mouse.move(sx, sy);
	await page.mouse.down({ button: "left" });
	await page.waitForTimeout(30);
	await page.mouse.up({ button: "left" });
	if (mods.alt) await page.keyboard.up("Alt");
	if (mods.shift) await page.keyboard.up("Shift");
	await page.waitForTimeout(120);
}

async function escapeAll() {
	await page.evaluate(() => {
		(document.activeElement as HTMLElement | null)?.blur();
	});
	await page.keyboard.press("Escape");
	await page.waitForTimeout(120);
}

const t = await targets();
console.log(
	`targets: peers=${t.peers.length} sessions=${t.sessions.length} messages=${t.messages.length}`,
);
for (const s of t.sessions) {
	console.log(`  session ${s.id} @ (${s.sx.toFixed(0)}, ${s.sy.toFixed(0)})`);
}

const results: { name: string; ok: boolean; detail: string }[] = [];

// --- SESSIONS ---
const sess = t.sessions[0];
if (sess) {
	const sessKey = `session:${sess.id}`;

	await escapeAll();
	await clickAt(sess.sx, sess.sy);
	const a1 = await selection();
	results.push({
		name: "session plain click → replace selection with [session]",
		ok: a1.length === 1 && a1[0] === sessKey,
		detail: `selection=[${a1.join(", ")}]`,
	});

	await escapeAll();
	await clickAt(sess.sx, sess.sy);
	const a2Before = await selection();
	await clickAt(sess.sx, sess.sy, { shift: true });
	const a2After = await selection();
	results.push({
		name: "session shift+click on already-selected → no-op",
		ok: a2After.length === a2Before.length &&
			a2After.every((k) => a2Before.includes(k)),
		detail: `before=${a2Before.length}  after=${a2After.length}`,
	});

	await escapeAll();
	const a3Before = await selection();
	await clickAt(sess.sx, sess.sy, { shift: true });
	const a3After = await selection();
	results.push({
		name: "session shift+click on empty → add",
		ok: a3After.length === a3Before.length + 1 && a3After.includes(sessKey),
		detail: `before=${a3Before.length}  after=[${a3After.join(", ")}]`,
	});

	await escapeAll();
	await clickAt(sess.sx, sess.sy);
	const a4Before = await selection();
	await clickAt(sess.sx, sess.sy, { shift: true, alt: true });
	const a4After = await selection();
	const log = await page.evaluate(() => {
		const g = globalThis as unknown as {
			__ocv?: { lastEffects?: string[] };
		};
		return g.__ocv?.lastEffects ?? [];
	});
	console.log("fsm tail:");
	for (const line of log.slice(-8)) console.log(`    ${line}`);
	results.push({
		name: "session shift+option click on selected → remove",
		ok: a4After.length === a4Before.length - 1 && !a4After.includes(sessKey),
		detail: `before=${a4Before.length}  after=${a4After.length}`,
	});
} else {
	console.log("no session in fixture; skipping session tests");
}

await browser.close();

let failed = 0;
for (const r of results) {
	console.log(`  ${r.ok ? "PASS" : "FAIL"} — ${r.name}`);
	console.log(`         ${r.detail}`);
	if (!r.ok) failed++;
}
console.log("");
console.log(failed === 0 ? "ALL PASS" : `FAIL: ${failed}`);
Deno.exit(failed === 0 ? 0 : 1);
