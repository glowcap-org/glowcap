/// <reference lib="dom" />
/**
 * Films Rooms and ocapnviz together for the site's explainer video: two
 * members talking in Rooms while ocapnviz records the CapTP traffic their
 * talk makes, from Rooms' own trace.
 *
 * One Rooms directory runs with its trace capability, and both members' tabs
 * take that capability, so each tab publishes its own trace and the room
 * server publishes its own. ocapnviz opens on the same trace endpoint in Live
 * mode and records. Before filming, ren opens a direct conversation with
 * mira and goes back to the room: the room server introduces the two tabs,
 * and the session between them leaves the server out. mira, on a phone,
 * writes in the room, and her line crosses the room server to ren. ren then
 * writes to her directly, on the session between them, and mira opens the
 * message. Nothing is scripted but the lines.
 *
 * Two reels film at once, each with the same marks: `traced-rooms`, mira's
 * phone, and `traced-ocapnviz`, the recording (see `reel.ts`). `zig build
 * site-video` builds the ocapnviz bundle and the Rooms page and runs this.
 */
import { chromium } from "playwright";
import { spawnWeb, webAnnouncements, webPort } from "../../apps/rooms/test/support/web_front.ts";
import { waitForHttp } from "../../apps/rooms/test/support/rooms_server.ts";
import { reapOwned } from "../../apps/rooms/test/support/children.ts";
import { joinAs } from "../../apps/rooms/test/support/join.ts";
import { openDmTo } from "../../apps/rooms/test/page/harness.ts";
import { namedRoomRow } from "../../apps/rooms/test/support/conversation_row.ts";
import { plainRun } from "./capture.ts";
import {
	filmArgs,
	glide,
	glideClick,
	placePointer,
	reelsDirArg,
	startReel,
	themeArg,
	themedContext,
	typeOnFilm,
} from "./reel.ts";
import { ROOMS_LAYOUT, smoothLayout } from "./film-smooth.ts";
import {
	heldStill,
	openLiveRecording,
	pointBetween,
	selectedKind,
	serveOcapnviz,
	settledPeers,
	stageBox,
} from "./ocapnviz-live.ts";

const SCALE = 1.5;
const ROOM = "workshop";
/** The two windows' sizes, in CSS pixels, so each reel fills its window in
 * the video at the video's own aspect. */
const PHONE = { width: 360, height: 601 };
const VIEWER = { width: 1100, height: 961 };
/** ocapnviz's panes at their narrowest, with the timeline sized so the stage
 * between them has the window's aspect. The video frames the stage alone. */
const VIEWER_PANES = { leftPaneWidth: 200, rightPaneWidth: 220, bottomPaneHeight: 324 };
const LINES = {
	room: "Kiln is free Saturday. Who has mugs?",
	direct: "Me! Can I bring two of the big ones?",
};

// Everything the film starts, stopped in reverse order when it ends. Each
// stop runs even when an earlier one throws.
await using started = new AsyncDisposableStack();
started.defer(() => reapOwned());
const web = spawnWeb({
	args: ["--transport=tcp", "0", "0"],
	env: { GLOWCAP_ROOMS_CAPABILITIES: "trace", GLOWCAP_ROOMS_TRACE_PORT: "0" },
	stdout: "piped",
	stderr: "inherit",
});
const dist = serveOcapnviz();
started.defer(() => dist.shutdown());
const browser = await chromium.launch({ args: ["--no-sandbox", ...filmArgs(SCALE)] });
started.defer(() => browser.close());
const trace = await webAnnouncements(web).line("ROOMS-TRACE-LISTENING", "rooms-web");
const http = await webPort(web);
await waitForHttp(http);

const errors: string[] = [];
const theme = themeArg();
const viewer = await openLiveRecording(browser, dist, trace, VIEWER, SCALE, theme, errors, VIEWER_PANES);
// Each member's tab takes the trace capability before it joins, so the
// recording sees it from its first session.
const mira = await joinAs(browser, http, "mira", {
	room: ROOM,
	trace,
	context: await themedContext(browser, theme, { viewport: PHONE, deviceScaleFactor: SCALE }),
});
const ren = await joinAs(browser, http, "ren", { room: ROOM, trace, context: await themedContext(browser, theme) });
await mira.locator("#members li", { hasText: "ren" }).first().waitFor({ state: "attached", timeout: 30_000 });
// The session between ren and mira opens before filming. ocapnviz lays
// out each new set of sessions afresh, so a session opening on film would
// turn the whole graph while its first messages fly.
await openDmTo(ren, "mira");
await namedRoomRow(ren, ROOM).click();
await ren.locator("#roomName", { hasText: ROOM }).waitFor({ timeout: 30_000 });
await settledPeers(viewer);
// The stage places peers as they arrive and can leave one under a side
// pane, so ocapnviz fits its stage to the window before filming.
await viewer.getByRole("button", { name: "Fit everything in view" }).click();
const settled = await settledPeers(viewer);
// A second pointer, the reader's in ocapnviz, rests low on the stage, off
// every line.
const stage = await stageBox(viewer);
const rest = { x: stage.x + stage.width * 0.75, y: stage.y + stage.height * 0.9 };
await placePointer(viewer, rest.x, rest.y);

await placePointer(mira, PHONE.width / 2, PHONE.height - 40);
await smoothLayout(mira, ROOMS_LAYOUT);
const rooms = await startReel(mira, `${reelsDirArg()}/traced-rooms`, { realTime: true });
// The video shows ocapnviz's stage alone, which VIEWER_PANES sizes to the
// window's aspect.
const recording = await startReel(viewer, `${reelsDirArg()}/traced-ocapnviz`, { realTime: true, rest: stage });
// Both reels stamp each mark at once, so they play in step. The video
// opens on mira's conversation, and ocapnviz shows its whole stage.
const mark = async (name: string) => {
	await Promise.all([rooms.mark(name), recording.mark(name)]);
};
await Promise.all([rooms.mark("start", mira.locator("#log")), recording.mark("start")]);
// The two windows fade in before mira types.
await viewer.waitForTimeout(1000);

// A room line goes from mira's tab to the room server, and on to ren.
await typeOnFilm(mira.locator("#line"), LINES.room);
await mark("room");
await mira.press("#line", "Enter");
await ren.locator(".bubble", { hasText: plainRun(LINES.room) }).last().waitFor({ timeout: 30_000 });
// The room's traffic settles, and the reader selects the session between
// mira and ren, so ocapnviz marks the line ren's message is about to take.
// The video's next line is up before ren writes.
await viewer.waitForTimeout(400);
await glideClick(viewer, await pointBetween(viewer, "mira", "ren"));
if (await selectedKind(viewer) !== "session") throw new Error("ocapnviz selected no session between mira and ren");
await glide(viewer, rest.x, rest.y, 500);
await viewer.waitForTimeout(700);

// ren writes to mira directly, on the session between the two tabs, and
// the room server is not on it.
await openDmTo(ren, "mira");
await ren.fill("#line", LINES.direct);
await mark("direct");
await ren.press("#line", "Enter");
await ren.locator(".bubble", { hasText: plainRun(LINES.direct) }).last().waitFor({ timeout: 30_000 });
await viewer.waitForTimeout(1200);
await heldStill(viewer, settled);

// mira opens it on her phone.
await glideClick(mira, mira.locator("#backBtn:visible, #railToggle:visible").first());
// The sidebar slides in, and the pointer waits for it to stop.
const row = mira.locator("#dmList li .rname", { hasText: /^ren$/ });
await row.waitFor({ state: "visible", timeout: 30_000 });
await mira.waitForTimeout(600);
await glideClick(mira, row);
// The pointer goes back to rest below the conversation, off its text.
await glide(mira, PHONE.width / 2, PHONE.height - 40, 400);
await mira.locator("#roomName", { hasText: "ren" }).waitFor({ timeout: 30_000 });
await mira.waitForSelector("#line:not([disabled])", { timeout: 30_000 });
await mira.locator(".bubble", { hasText: plainRun(LINES.direct) }).last().waitFor({ timeout: 30_000 });
// The conversation holds on her phone long enough to read.
await viewer.waitForTimeout(1300);
await mark("end");
await Promise.all([rooms.stop(), recording.stop()]);
if (errors.length > 0) throw new Error(`ocapnviz failed while filming:\n${errors.join("\n")}`);
