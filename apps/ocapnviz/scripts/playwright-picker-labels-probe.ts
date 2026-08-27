#!/usr/bin/env -S deno run -A
/**
 * playwright-picker-labels-probe.ts — every Build-mode picker that
 * offers an entity, photographed with its options showing.
 *
 * The rule under test is in `src/ui/inspector/picker-labels.ts`: a
 * picker leads with the name a person knows the entity by, and shows the
 * id only where two rows would otherwise read the same. Both halves need
 * a document to be seen, so this authors one: it renames a peer so two
 * peers answer to "alice", and opens a second session between one pair so
 * a message has more than one session to have been carried over.
 *
 * A native select shows one option when it is closed, and its popup is
 * drawn by the operating system where no screenshot can reach it. So each
 * picker is photographed twice: closed, which is what a reader sees at
 * rest, and again with `size` set to its option count, which makes the
 * browser lay the same options out inline as a list. The second shot is
 * the rendered strings themselves, and the option text is printed beside
 * it so the run can be read without opening the images.
 *
 * Usage: playwright-picker-labels-probe.ts <out-dir> [url]
 * Setup: a dev server on the url (default :5173).
 */
import { chromium, type Locator, type Page } from "playwright";

const outDir = Deno.args[0] ?? "/tmp/ocv-picker-labels";
const url = Deno.args[1] ?? "http://127.0.0.1:5173/";
await Deno.mkdir(outDir, { recursive: true });

type Pt = { id: string; sx: number; sy: number };

/** Where the stage is drawing each peer, session, and in-flight message
 *  right now, in screen coordinates, so a click can land on one. */
function targets(
	page: Page,
): Promise<{ peers: Pt[]; sessions: Pt[]; messages: Pt[] }> {
	return page.evaluate(() => {
		type Peer = { peer: { id: string }; position?: { x: number; y: number } };
		type Session = {
			session: { id: string };
			endpoints: { a: string; b: string };
		};
		type Msg = {
			messageInFlight: { id: string };
			position?: { x: number; y: number };
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
		const peers: Pt[] = [];
		const sessions: Pt[] = [];
		const messages: Pt[] = [];
		if (!q || !vp) return { peers, sessions, messages };
		const byId = new Map<string, { x: number; y: number }>();
		for (const p of q.peers ?? []) {
			if (p.position) {
				byId.set(p.peer.id, p.position);
				const s = vp.toScreen(p.position.x, p.position.y);
				peers.push({ id: p.peer.id, sx: s.x, sy: s.y });
			}
		}
		for (const sess of q.sessions ?? []) {
			const a = byId.get(sess.endpoints.a);
			const b = byId.get(sess.endpoints.b);
			if (!a || !b) continue;
			const s = vp.toScreen((a.x + b.x) / 2, (a.y + b.y) / 2);
			sessions.push({ id: sess.session.id, sx: s.x, sy: s.y });
		}
		for (
			const m of (world?.with("messageInFlight", "position") ?? []) as Msg[]
		) {
			if (!m.position) continue;
			const s = vp.toScreen(m.position.x, m.position.y);
			messages.push({ id: m.messageInFlight.id, sx: s.x, sy: s.y });
		}
		return { peers, sessions, messages };
	});
}

type Intent = Record<string, unknown>;

/** Author into the loaded document, the way the Build tools do. */
function dispatch(page: Page, intent: Intent): Promise<string | undefined> {
	return page.evaluate((i) => {
		const g = globalThis as unknown as {
			__ocv?: { engine?: { dispatch(intent: unknown): string | undefined } };
		};
		return g.__ocv?.engine?.dispatch(i);
	}, intent);
}

function peerIds(page: Page): Promise<{ id: string; label: string }[]> {
	return page.evaluate(() => {
		const g = globalThis as unknown as {
			__ocv?: {
				engine?: {
					doc?: { entities?: { peers?: Record<string, { label?: string }> } };
				};
			};
		};
		const peers = g.__ocv?.engine?.doc?.entities?.peers ?? {};
		return Object.entries(peers).map(([id, def]) => ({
			id,
			label: def.label ?? id,
		}));
	});
}

async function seekTo(page: Page, t: number) {
	await page.evaluate((ms) => {
		const g = globalThis as unknown as {
			__ocv?: { engine?: { enqueue(cmd: unknown): void } };
		};
		g.__ocv?.engine?.enqueue({ kind: "seekTo", t: ms });
	}, t);
	await page.waitForTimeout(300);
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

async function clickAt(page: Page, at: Pt | undefined) {
	if (!at) return;
	await page.mouse.move(at.sx, at.sy);
	await page.mouse.down({ button: "left" });
	await page.waitForTimeout(30);
	await page.mouse.up({ button: "left" });
	await page.waitForTimeout(200);
}

/** One picker, at rest and then opened out into a list, with the option
 *  strings printed. `size` is set for the second shot only and put back
 *  after, so nothing else in the panel is photographed out of shape. */
async function shootPicker(page: Page, select: Locator, name: string) {
	if (await select.count() === 0) {
		console.log(`${name}: absent`);
		return;
	}
	const options = await select.locator("option").allTextContents();
	console.log(`${name}: ${options.map((o) => JSON.stringify(o)).join("  ")}`);
	await select.screenshot({ path: `${outDir}/${name}-closed.png` });
	await select.evaluate((el, n) => {
		const sel = el as HTMLSelectElement;
		sel.size = n;
		// `.ocv-select` pins a control height, which a list box would be
		// clipped to. Released for the shot and put back after.
		sel.style.height = "auto";
		sel.style.maxHeight = "none";
	}, options.length);
	await page.waitForTimeout(200);
	await select.screenshot({ path: `${outDir}/${name}-open.png` });
	await select.evaluate((el) => {
		const sel = el as HTMLSelectElement;
		sel.size = 0;
		sel.style.height = "";
		sel.style.maxHeight = "";
	});
}

const browser = await chromium.launch({
	headless: true,
	args: ["--no-sandbox", "--disable-gpu"],
});
const ctx = await browser.newContext({
	viewport: { width: 1600, height: 1000 },
	deviceScaleFactor: 2,
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
await page.getByRole("radio", { name: "Build" }).click();
await page.waitForTimeout(500);

// ── one session, selected through a peer ───────────────────────────────
//
// Reached through the peer rather than by clicking the edge, because two
// sessions between one pair fan apart and the straight midpoint between
// the peers lands between them rather than on either.
async function selectFirstSessionOfFirstPeer(): Promise<string | undefined> {
	const t = await targets(page);
	await clickAt(page, t.peers[0]);
	await page.locator("button.ocv-session-row").first().click();
	await page.waitForTimeout(300);
	const picked = (await selection(page))[0];
	console.log(`selected: ${picked}`);
	return picked?.replace("session:", "");
}

// ── with the names the document arrives with ───────────────────────────
//
// Every peer answers to something different here, so every option is a
// name and nothing needs an id beside it.
await selectFirstSessionOfFirstPeer();
await shootPicker(
	page,
	page.getByLabel("Peer attached to end a"),
	"01-unique-attached-to-end-a",
);

// ── the document this probe authors ────────────────────────────────────
//
// Two peers answering to one name, which is the collision the rule exists
// for, and a second session between one pair, which is what gives a
// message more than one session to have been carried over.
const peers = await peerIds(page);
const [first, second] = peers;
if (!first || !second) throw new Error("no peers in the loaded document");
for (const peer of [first, second]) {
	await dispatch(page, {
		kind: "update-peer",
		peerId: peer.id,
		patch: { label: "alice" },
	});
}
await seekTo(page, 400);
const extra = await dispatch(page, {
	kind: "open-session",
	a: { peer: first.id, attributedBy: "session-key-attestation" },
	b: { peer: second.id, attributedBy: "session-key-attestation" },
	codec: "syrup",
	captpVersion: "v1_0",
});
console.log(`authored: "alice" on ${first.id} and ${second.id}`);
console.log(`authored: second session ${extra} between them`);
await page.waitForTimeout(400);

// ── the end-attachment picker, now that two peers collide ──────────────
const sessionId = await selectFirstSessionOfFirstPeer();
await shootPicker(
	page,
	page.getByLabel("Peer attached to end a"),
	"02-collision-attached-to-end-a",
);

// ── the same picker on a trajectory row ────────────────────────────────
//
// A moment that attaches an end, so the row with the two attachment
// controls exists to be photographed.
if (sessionId) {
	await dispatch(page, {
		kind: "set-session-keyframe",
		sessionId,
		property: "a",
		t: 600,
		value: { peer: first.id, attributedBy: "session-key-attestation" },
	});
	await page.waitForTimeout(300);
	await shootPicker(
		page,
		page.getByLabel("New end a"),
		"03-collision-trajectory-end-a",
	);
}

// ── the session picker, on a message panel ─────────────────────────────
//
// Every session a message could have been carried over joins the same two
// peers, so this list collides by construction and always qualifies.
await seekTo(page, 500);
const msg = await dispatch(page, {
	kind: "send-message",
	sessionId: extra,
	from: first.id,
	to: second.id,
	label: "which session carried this",
	flightMs: 400,
});
console.log(`authored: message ${msg}`);
await seekTo(page, 600);
const t = await targets(page);
await clickAt(page, t.messages[0]);
await shootPicker(
	page,
	page.getByLabel("Session carrying this message"),
	"04-message-session",
);

// The whole Inspector, so the pickers are seen in the panel they live in
// rather than only as cropped controls.
await page.screenshot({
	path: `${outDir}/05-inspector.png`,
	clip: { x: 1230, y: 40, width: 370, height: 900 },
});

await ctx.close();
await browser.close();
console.log(`shots in ${outDir}`);
