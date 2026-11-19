/// <reference lib="dom" />
/**
 * ocapnviz's production bundle opened in Live mode on a trace endpoint and
 * recording, ready to film. The two films that show ocapnviz
 * (`film-ocapnviz.ts` and `film-rooms-traced.ts`) both start here.
 */
import type { Browser, Page } from "playwright";
import { isLoopback, serveDirectory } from "./reel.ts";

/** The site's own ocapnviz, built before the films by `site-ocapnviz-page`,
 * so the video shows the bytes the site serves. */
export const serveOcapnviz = (): Deno.HttpServer<Deno.NetAddr> => serveDirectory("site/assets/ocapnviz");

/** Open ocapnviz from `dist` on the trace endpoint `sturdyref`, in a context
 * of its own at `viewport` and `scale`, and start recording. Recording starts
 * off camera: a loaded document asks before a recording replaces it, and a
 * reel opens on the recording itself, not that question. `errors` collects
 * the page's own errors for the film to report. `sizes`, when given, are the
 * pane sizes the app starts with, in CSS pixels. Without a
 * `bottomPaneHeight`, ocapnviz fits its timeline to its rows, as it does by
 * default. */
export async function openLiveRecording(
	browser: Browser,
	dist: Deno.HttpServer<Deno.NetAddr>,
	sturdyref: string,
	viewport: { width: number; height: number },
	scale: number,
	errors: string[],
	sizes?: { leftPaneWidth: number; rightPaneWidth: number; bottomPaneHeight?: number },
): Promise<Page> {
	const context = await browser.newContext({ viewport, deviceScaleFactor: scale, colorScheme: "dark" });
	// The bundle asks Google Fonts for its typeface. Every outside request is
	// refused, so the film needs no network and the app uses its local font.
	// The trace endpoint is on loopback, so the page reaches it.
	await context.route((url) => !isLoopback(url.href), (route) => route.abort("blockedbyclient"));
	// The payload pane remembers its lens, and a film reads Syrup as text.
	await context.addInitScript(() => localStorage.setItem("ocapnviz:payload-view-mode", "utf-8"));
	if (sizes != null) {
		await context.addInitScript(
			(json) => localStorage.setItem("ocapnviz:layout-sizes", json),
			// ocapnviz stores all three sizes, and it raises a fitted timeline's
			// stored 0 to its rows.
			JSON.stringify({ ...sizes, bottomPaneHeight: sizes.bottomPaneHeight ?? 0 }),
		);
	}
	const page = await context.newPage();
	page.setDefaultTimeout(20_000);
	page.on("pageerror", (err) => errors.push(err.message));
	// ocapnviz takes the live link from the address and then clears it, so a
	// second load opens the link again rather than reloading. Each load has its
	// own query, so the browser loads the page anew rather than moving to its #.
	let loads = 0;
	const open = async () => {
		loads += 1;
		await page.goto(`http://127.0.0.1:${dist.addr.port}/?load=${loads}#live=${encodeURIComponent(sturdyref)}`, {
			waitUntil: "load",
		});
		await page.waitForSelector("canvas#ocv-pixi", { timeout: 30_000 });
		await page.waitForFunction(() => "__ocv" in globalThis && "__ocvViewport" in globalThis, undefined, {
			timeout: 30_000,
		});
		await page.getByTitle(/^The live feed is connected/).waitFor({ timeout: 30_000 });
	};
	await open();
	if (sizes?.bottomPaneHeight != null) await holdTimelineHeight(page, sizes.bottomPaneHeight, open);
	await page.evaluate(() => document.fonts.ready);
	await page.waitForTimeout(600);
	// The recording starts at once on a bare Live tab, so wait for whichever
	// comes first, the dialog or the Stop button.
	await page.getByRole("button", { name: "Start recording" }).click();
	const discard = page.getByRole("alertdialog", { name: "Discard the loaded document?" });
	const stop = page.getByRole("button", { name: "Stop recording" });
	await discard.or(stop).first().waitFor();
	if (await discard.isVisible()) {
		await discard.getByRole("button", { name: "Record", exact: true }).click();
		await stop.waitFor();
	}
	return page;
}

/** Keep the timeline at `height`. ocapnviz fits it to its rows while its
 * Auto-size box is ticked, which it is by default, so the film unticks it, as
 * a person would, and opens the page again with `open`. ocapnviz keeps the
 * choice, and the stored sizes come back with the page. */
async function holdTimelineHeight(page: Page, height: number, open: () => Promise<void>): Promise<void> {
	const autoSize = page.locator("label[title^='Auto-size the panel'] input");
	await autoSize.uncheck();
	await open();
	const timeline = await page.locator("canvas#ocv-pixi").evaluate((canvas) => {
		const stage = canvas.getBoundingClientRect();
		const left = document.querySelector("aside.ocv-pane")?.getBoundingClientRect();
		return left == null ? null : stage.bottom - left.bottom;
	});
	if (timeline == null || Math.abs(timeline - height) > 2) {
		throw new Error(`ocapnviz's timeline is ${timeline} px tall, not the ${height} px the film asks for`);
	}
}

/** The part of ocapnviz's canvas between its two side panes, where the
 * stage is. */
export async function stageBox(page: Page): Promise<{ x: number; y: number; width: number; height: number }> {
	const panes = page.locator("aside.ocv-pane");
	const left = await panes.first().boundingBox();
	const right = await panes.last().boundingBox();
	if (left == null || right == null) throw new Error("ocapnviz shows no side panes");
	return { x: left.x + left.width, y: left.y, width: right.x - left.x - left.width, height: left.height };
}

/** What the helpers here read from the app's test handle. */
export type OcvPage = {
	__ocv: {
		engine: {
			clock: { snapshot(): { t: number; duration: number } };
			seekTo(t: number): void;
			orderedPeers(): readonly { peer: { label: string }; position: { x: number; y: number } }[];
			orderedMessages(): readonly {
				messageInFlight: { sessionId: string; sentT: number; arrivalT: number };
				position: { x: number; y: number };
			}[];
		};
	};
	__ocvViewport: { toScreen(x: number, y: number): { x: number; y: number } };
};

type Point = { x: number; y: number };

/** Each peer on the stage, by label: where it stands in the stage's own
 * coordinates, and where that is on the page. */
export async function peerPlaces(page: Page): Promise<{ label: string; world: Point; page: Point }[]> {
	return await page.evaluate(() => {
		const scope = globalThis as unknown as OcvPage;
		const canvas = document.querySelector("canvas#ocv-pixi");
		if (canvas == null) return [];
		const origin = canvas.getBoundingClientRect();
		return scope.__ocv.engine.orderedPeers().map(({ peer, position }) => {
			const at = scope.__ocvViewport.toScreen(position.x, position.y);
			return {
				label: peer.label,
				world: { x: position.x, y: position.y },
				page: { x: origin.left + at.x, y: origin.top + at.y },
			};
		});
	});
}

/** A point on the session line between two peers, `along` of the way from
 * the first, in page pixels. The line's label sits at its middle, so a point
 * off the middle lands on the line itself. */
export async function pointBetween(page: Page, from: string, to: string, along = 0.35): Promise<Point> {
	const places = await peerPlaces(page);
	const a = places.find(({ label }) => label === from)?.page;
	const b = places.find(({ label }) => label === to)?.page;
	if (a == null || b == null) throw new Error(`ocapnviz shows no line between ${from} and ${to}`);
	return { x: a.x + (b.x - a.x) * along, y: a.y + (b.y - a.y) * along };
}

/** The kind of entity ocapnviz's selection follows, or null with nothing
 * selected. */
export async function selectedKind(page: Page): Promise<string | null> {
	return await page.evaluate(() =>
		(globalThis as unknown as { __ocv: { selection: { anchor: { kind: string } | null } } }).__ocv.selection.anchor
			?.kind ?? null
	);
}

/** Where each peer stands, by label, once the stage has stopped moving: two
 * reads 400 ms apart agree. Refuses after 15 s. */
export async function settledPeers(page: Page): Promise<Map<string, Point>> {
	const read = async () => new Map((await peerPlaces(page)).map(({ label, world }) => [label, world]));
	let last = await read();
	for (let tries = 0; tries < 37; tries++) {
		await page.waitForTimeout(400);
		const now = await read();
		if (now.size > 0 && now.size === last.size && [...now].every(([label, at]) => near(at, last.get(label)))) {
			return now;
		}
		last = now;
	}
	throw new Error("ocapnviz's stage did not stop moving within 15 s");
}

const near = (a: Point, b: Point | undefined): boolean => b != null && Math.hypot(a.x - b.x, a.y - b.y) <= 0.5;

/** Refuses when a peer has moved since `settledPeers` read `settled`, or a
 * peer has come or gone. */
export async function heldStill(page: Page, settled: ReadonlyMap<string, Point>): Promise<void> {
	const now = await peerPlaces(page);
	const moved = now.filter(({ label, world }) => !near(world, settled.get(label)));
	if (moved.length > 0 || now.length !== settled.size) {
		throw new Error(
			`ocapnviz moved its peers: ${settled.size} settled, ${now.length} now, moved ${
				moved.map(({ label }) => label).join(", ")
			}`,
		);
	}
}

/** The box around the peers on the stage as they stand now, in page pixels,
 * with `margin` around their middles so each peer and its label fall inside
 * it. `labels`, when given, names the peers it holds, and every other peer
 * is left out. */
export async function peersBox(
	page: Page,
	margin = 80,
	labels?: readonly string[],
): Promise<{ x: number; y: number; width: number; height: number }> {
	const points = (await peerPlaces(page)).filter(({ label }) => labels == null || labels.includes(label)).map(
		(place) => place.page,
	);
	if (points.length !== (labels?.length ?? points.length) || points.length === 0) {
		throw new Error(`ocapnviz shows ${points.length} of the peers ${labels?.join(", ") ?? "on its stage"}`);
	}
	const xs = points.map((p) => p.x);
	const ys = points.map((p) => p.y);
	const left = Math.min(...xs) - margin;
	const top = Math.min(...ys) - margin;
	return { x: left, y: top, width: Math.max(...xs) + margin - left, height: Math.max(...ys) + margin - top };
}
