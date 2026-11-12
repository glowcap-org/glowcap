#!/usr/bin/env -S deno run -A
/**
 * playwright-inspector-typing-probe.ts: does a Build text field show what
 * is typed into it, while the caret is still in it?
 *
 * A typing burst is one edit transaction, and the panels for a peer, a
 * session, and a message do not render again until it closes. A field that
 * shows only the value its panel hands it therefore drops every character,
 * and the document ends the burst holding the old text plus the last key.
 * `shownText` in `src/ui/inspector/edit-bracket.ts` is the rule that keeps
 * the typed text on screen.
 *
 * The probe presses one key at a time. Playwright's `fill` replaces the value
 * in a single input event, which is the one way of typing this defect does
 * not touch. It walks the document fields, a peer, a session the peer is on,
 * and a message caught in flight, and reads each field twice: with the caret
 * in it, and after leaving it. An id field is asked too: it holds its own
 * draft and renames the entity on leaving, so the probe renames what it
 * selects.
 *
 * Run against a dev server: `deno task dev`, then
 * `deno run -A scripts/playwright-inspector-typing-probe.ts http://127.0.0.1:5173/`.
 */
import { openBuildStage } from "./support/headless.ts";

const url = Deno.args[0] ?? "http://127.0.0.1:5173/";

/** What the probe types on the end of every field. */
const TYPED = "xyz";

const FIELDS = 'input[type="text"].ocv-input, textarea.ocv-input';

const { browser, page, failures } = await openBuildStage(url);

/** The fields whose panels stay quiet through a typing burst. A run that
 *  reached none of them has not looked where the defect lives. */
const QUIET_PANEL_FIELDS = [
	"Peer label",
	"Peer designator",
	"What end a claims to be",
	"What end b claims to be",
	"Message label",
];

/** Labels already typed into, so a field that stays on screen across
 *  selections is asked once. */
const asked = new Set<string>();

/** The one visible text field with this label. */
function fieldLabeled(label: string) {
	return page.locator(FIELDS).and(page.getByLabel(label, { exact: true })).filter({ visible: true });
}

/** Type into every text field on the page that has not been asked yet. */
async function typeIntoEach(where: string) {
	const labels: string[] = [];
	for (const field of await page.locator(FIELDS).filter({ visible: true }).all()) {
		const label = await field.getAttribute("aria-label");
		if (label == null) {
			failures.push(`${where}: a text field has no label to find it by`);
		} else {
			labels.push(label);
		}
	}
	for (const label of labels) {
		if (asked.has(label)) continue;
		asked.add(label);
		const field = fieldLabeled(label);
		if (await field.count() !== 1) {
			failures.push(`${where}, ${label}: ${await field.count()} fields answer to this label`);
			continue;
		}
		const before = await field.inputValue();
		await field.click();
		await page.keyboard.press("Control+End");
		await page.keyboard.type(TYPED, { delay: 30 });
		const focused = await field.inputValue();
		await field.blur();
		await page.waitForTimeout(150);
		const left = await fieldLabeled(label).inputValue();
		const want = before + TYPED;
		const ok = focused === want && left === want;
		if (focused !== want) {
			failures.push(`${where}, ${label}: typing showed "${focused.slice(-24)}", not "${want.slice(-24)}"`);
		} else if (left !== want) {
			failures.push(`${where}, ${label}: leaving the field kept "${left.slice(-24)}", not "${want.slice(-24)}"`);
		}
		console.log(`${ok ? "ok  " : "FAIL"} ${where}, ${label}`);
	}
}

await typeIntoEach("peer selected");

// The peer's connections list the sessions it is on.
const rows = page.locator("button.ocv-session-row");
if (await rows.count() === 0) {
	failures.push("the peer panel lists no session to inspect");
} else {
	await rows.first().click();
	await page.waitForTimeout(400);
	await typeIntoEach("session selected");
}

/**
 * Park the playhead at `t` and report where a message in flight is drawn.
 * Nothing in the page lists messages, so the stage is the way to select one.
 */
function messageOnStageAt(t: number): Promise<{ x: number; y: number } | null> {
	return page.evaluate(async (ms) => {
		type Flying = { position: { x: number; y: number } };
		type VP = { toScreen: (x: number, y: number) => { x: number; y: number } };
		const g = globalThis as unknown as {
			__ocv?: {
				engine?: {
					enqueue(cmd: unknown): void;
					queries?: { messagesInFlight?: Iterable<Flying> };
				};
			};
			__ocvViewport?: VP;
		};
		const engine = g.__ocv?.engine;
		const vp = g.__ocvViewport;
		if (engine == null || vp == null) return null;
		engine.enqueue({ kind: "seekTo", t: ms });
		// Two frames: one for the engine to take the seek, one to draw it.
		await new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done)));
		for (const m of engine.queries?.messagesInFlight ?? []) {
			return vp.toScreen(m.position.x, m.position.y);
		}
		return null;
	}, t);
}

/** How far along the timeline the probe looks for a message, and how finely. */
const LOOK_UNTIL_MS = 30_000;
const LOOK_STEP_MS = 200;

for (let t = 0; t <= LOOK_UNTIL_MS && !asked.has("Message label"); t += LOOK_STEP_MS) {
	const at = await messageOnStageAt(t);
	if (at == null) continue;
	await page.keyboard.press("Escape");
	await page.mouse.click(at.x, at.y);
	await page.waitForTimeout(300);
	if (await page.getByLabel("Message label", { exact: true }).count() > 0) {
		await typeIntoEach("message selected");
	}
}

for (const label of QUIET_PANEL_FIELDS) {
	if (!asked.has(label)) failures.push(`${label}: the probe never reached this field`);
}

await browser.close();
for (const line of failures) console.log(`FAIL ${line}`);
console.log(failures.length === 0 ? `ok   ${asked.size} fields show what is typed` : `${failures.length} failures`);
Deno.exit(failures.length === 0 ? 0 : 1);
