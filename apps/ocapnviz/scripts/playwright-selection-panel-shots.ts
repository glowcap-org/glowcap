#!/usr/bin/env -S deno run -A
/**
 * playwright-selection-panel-shots.ts: the Inspector, once per
 * selection shape, in both themes and both modes.
 *
 * The group-selection panel is judged on real selections rather than
 * one tidy example, so this walks the shapes that read differently:
 * one entity (the boundary the group panel must not claim), two of
 * one kind, two of different kinds, and everything at once.
 *
 * Usage: playwright-selection-panel-shots.ts <out-dir> [url]
 * Setup: a dev server on the url (default :5173).
 */
import { chromium, type Page } from "playwright";

type Pt = { id: string; sx: number; sy: number };

const outDir = Deno.args[0] ?? "/tmp/ocv-selection";
const url = Deno.args[1] ?? "http://127.0.0.1:5173/";
await Deno.mkdir(outDir, { recursive: true });

/** Screen points for every node the stage draws and the midpoint of
 *  every session edge, read out of the live world through the
 *  viewport the stage publishes. Ends are here too: a session end
 *  nothing has attributed is drawn where a peer would be, and it is
 *  the member of a selection the panel has the most to be careful
 *  about. */
function targets(
	page: Page,
): Promise<{ peers: Pt[]; sessions: Pt[]; ends: Pt[] }> {
	return page.evaluate(() => {
		type Peer = { peer: { id: string }; position?: { x: number; y: number } };
		type End = {
			endpoint: { id: string };
			position?: { x: number; y: number };
		};
		type Session = {
			session: { id: string };
			endpoints: { a: string; b: string };
		};
		type VP = { toScreen: (x: number, y: number) => { x: number; y: number } };
		type World = { with(...c: string[]): Iterable<unknown> };
		const g = globalThis as unknown as {
			__ocv?: {
				engine?: {
					world?: World;
					queries?: { peers?: Iterable<Peer>; sessions?: Iterable<Session> };
				};
			};
			__ocvViewport?: VP;
		};
		const q = g.__ocv?.engine?.queries;
		const world = g.__ocv?.engine?.world;
		const vp = g.__ocvViewport;
		const peers: { id: string; sx: number; sy: number }[] = [];
		const sessions: { id: string; sx: number; sy: number }[] = [];
		const ends: { id: string; sx: number; sy: number }[] = [];
		if (!q || !vp) return { peers, sessions, ends };
		const byId = new Map<string, { x: number; y: number }>();
		for (const p of q.peers ?? []) {
			if (p.position) byId.set(p.peer.id, p.position);
		}
		for (const e of (world?.with("endpoint", "position") ?? []) as End[]) {
			if (e.position) byId.set(e.endpoint.id, e.position);
		}
		for (const p of q.peers ?? []) {
			if (!p.position) continue;
			const s = vp.toScreen(p.position.x, p.position.y);
			peers.push({ id: p.peer.id, sx: s.x, sy: s.y });
		}
		for (const e of (world?.with("endpoint", "position") ?? []) as End[]) {
			if (!e.position) continue;
			const s = vp.toScreen(e.position.x, e.position.y);
			ends.push({ id: e.endpoint.id, sx: s.x, sy: s.y });
		}
		for (const sess of q.sessions ?? []) {
			const a = byId.get(sess.endpoints.a);
			const b = byId.get(sess.endpoints.b);
			if (!a || !b) continue;
			const s = vp.toScreen((a.x + b.x) / 2, (a.y + b.y) / 2);
			sessions.push({ id: sess.session.id, sx: s.x, sy: s.y });
		}
		return { peers, sessions, ends };
	});
}

/** Park the playhead, so the shots catch a moment where something is
 *  on stage and something is not. */
async function seekTo(page: Page, t: number) {
	await page.evaluate((ms) => {
		const g = globalThis as unknown as {
			__ocv?: { engine?: { enqueue(cmd: unknown): void } };
		};
		g.__ocv?.engine?.enqueue({ kind: "seekTo", t: ms });
	}, t);
	await page.waitForTimeout(300);
}

async function clickAt(page: Page, at: Pt | undefined, shift = false) {
	if (!at) return;
	if (shift) await page.keyboard.down("Shift");
	await page.mouse.move(at.sx, at.sy);
	await page.mouse.down({ button: "left" });
	await page.waitForTimeout(30);
	await page.mouse.up({ button: "left" });
	if (shift) await page.keyboard.up("Shift");
	await page.waitForTimeout(150);
}

function selection(page: Page): Promise<string[]> {
	return page.evaluate(() => {
		const g = globalThis as unknown as {
			__ocv?: { selection?: { selection?: Iterable<string> } };
		};
		const set = g.__ocv?.selection?.selection;
		return set ? [...set] : [];
	});
}

async function blur(page: Page) {
	await page.evaluate(() => {
		(document.activeElement as HTMLElement | null)?.blur();
	});
}

/** Escape clears every selection slot. Blur first, or the browser's
 *  own Escape handling gets there before the app's. */
async function clear(page: Page) {
	await blur(page);
	await page.keyboard.press("Escape");
	await page.waitForTimeout(150);
}

async function shot(page: Page, name: string) {
	await page.screenshot({
		path: `${outDir}/${name}.png`,
		clip: { x: 1230, y: 40, width: 370, height: 820 },
	});
	console.log(`${name}  ${(await selection(page)).join(" ")}`);
}

const browser = await chromium.launch({
	headless: true,
	args: ["--no-sandbox", "--disable-gpu"],
});

for (const theme of ["light", "dark"] as const) {
	const ctx = await browser.newContext({
		viewport: { width: 1600, height: 1000 },
		deviceScaleFactor: 2,
		colorScheme: theme,
	});
	const page = await ctx.newPage();
	page.on("pageerror", (e) => console.log("[pageerror]", e.message));
	await page.addInitScript(() => {
		try {
			localStorage.removeItem("ocapnviz:app-state");
		} catch {
			// first run has nothing to clear
		}
	});
	await page.goto(url, { waitUntil: "networkidle" });
	await page.waitForSelector("canvas#ocv-pixi");
	await page.evaluate((t) => {
		document.documentElement.dataset.theme = t;
	}, theme);
	await page.waitForTimeout(500);

	for (const mode of ["Build", "Play"] as const) {
		await page.getByRole("radio", { name: mode }).click();
		await page.waitForTimeout(400);
		await blur(page);
		const t = await targets(page);
		const tag = `${theme}-${mode.toLowerCase()}`;

		await clear(page);
		await clickAt(page, t.peers[0]);
		await shot(page, `${tag}-01-one-peer`);

		await clickAt(page, t.peers[1], true);
		await shot(page, `${tag}-02-two-peers`);

		await clear(page);
		await clickAt(page, t.peers[0]);
		await clickAt(page, t.sessions[0], true);
		await shot(page, `${tag}-03-peer-and-session`);

		await clear(page);
		await clickAt(page, t.sessions[0]);
		await clickAt(page, t.sessions[1], true);
		await shot(page, `${tag}-04-two-sessions`);

		// Everything the visible window holds: Cmd-A over the timeline.
		await clear(page);
		await page.keyboard.press("Meta+a");
		await page.waitForTimeout(250);
		await shot(page, `${tag}-05-select-all`);
		await clear(page);

		// A peer and a session end: the member with no time and no delete
		// of its own, which is what the panel's caveats are for. It is
		// only on stage while its session negotiates, so this one moves
		// the playhead to where the stage draws it.
		await seekTo(page, 2000);
		const mid = await targets(page);
		await clear(page);
		await clickAt(page, mid.peers[0]);
		await clickAt(page, mid.ends[0], true);
		await shot(page, `${tag}-06-peer-and-end`);
		await clear(page);
		await seekTo(page, 0);
	}

	await ctx.close();
	console.log(`${theme} → ${outDir}/${theme}-*.png`);
}

await browser.close();
