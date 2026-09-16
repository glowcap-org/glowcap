// A room nobody can look up, and the only way into one.
//
// A public room is reached by its name: the directory lists it, `enter` finds
// it, and knowing what it is called is the whole of being able to walk in. A
// private room is the same room with none of that — it is in no list, `enter`
// does not find it, and its name is a label two of them may share. What is left
// is the reference, and holding one is being in the room.
//
// So an invitation is the room itself: `/invite` hands the live reference over
// the direct line this reader already has, carried across as a third-party
// handoff, with the room and the directory told nothing about who was offered
// what. `/link` is the durable sibling: data the room minted, for an offer that
// must outlive its sessions.
//
// Here both routes to the server spell it the same way, so taking up a handed
// room reuses the session the guest already holds and his name needs no proof.
// A deployment where the spellings diverge opens a second session, and the
// name-capability voucher seats him there; that half is pinned hermetically in
// server_test.ts, where a byte pipe makes the divergence on purpose.
//
// So this drives the difference rather than the feature. Two tabs on one
// directory:
//
//   ada  makes a private room called "plans" and says something in it.
//   bo   asks for the room list, and it is not there.
//   bo   names a room "plans" himself, and gets a different room with the same
//        label and none of ada's content. The label carries no authority.
//   ada  hands hers over. bo takes it up and hears what she said next.
//   bo   is offered a second one and declines it, which lets the reference go.
//
// And then the link on its own, which is the part no directory has to be in on.
// A second room server stands beside the page's own, di makes a room there and
// reads its link out, and bo — who holds only the directory his page serves —
// pastes it. The link names its own peer, so that is the peer the room is
// redeemed on: the tab opens that directory beside the one it had. The two ways
// a link can be no good are told apart on the way, and neither leaves a server
// behind in the rail.
//
// Needs deno, the wasm module (`zig build wasm-driver`), the native archives
// (the web front and room server run Rust), and a Playwright Chromium.
// Run: `deno run --allow-all apps/rooms/test/web/private_room_test.ts`.

import { SERVER, WEB } from "../support/paths.ts";
import { formatRoomsSturdyref, parseRoomsSturdyref } from "../../lib/locator.ts";
import { type Browser, chromium } from "playwright";
import { establishLocalSession } from "../support/session_setup.ts";
import { reapOwned, spawnOwned } from "../support/children.ts";
import { fail } from "../support/fail.ts";
import { freePort } from "../support/ports.ts";
import { joinAs, ROOM } from "../support/join.ts";
import { say } from "../page/harness.ts";
import { waitForHttp } from "../support/rooms_server.ts";
import {
	directoriesNamed,
	makeRoom,
	openRailRoom,
	railRooms,
	refusalAbout,
	roomLink,
	said,
	waitForTcp,
} from "../support/private_room_page.ts";
import { reachDirectoryOnCard } from "../page/harness.ts";

const ROOT = new URL("../../../../", import.meta.url).pathname;
const LABEL = "plans";
const PRIVATE_LINE = "just us then";
const PUBLIC_LINE = "this is my own plans room";

const deadline = setTimeout(() => fail("web-private-room scenario timed out after 240s"), 240_000);

const httpPort = freePort();
const roomPort = freePort();
// A second authority: another room server, not another room on the page's own.
// A port nothing ever listens on stands for a link whose peer is not there.
const foreignRoomPort = freePort();
const deadPort = freePort();
const foreignLocator = `127.0.0.1:${foreignRoomPort}`;

spawnOwned(SERVER, {
	args: ["--transport=tcp", `--port=${foreignRoomPort}`],
	cwd: ROOT,
	stdout: "null",
	stderr: "inherit",
});

spawnOwned(WEB, {
	args: [
		"--transport=tcp",
		String(httpPort),
		String(roomPort),
	],
	cwd: ROOT,
	// A relay dials iroh anywhere and cleartext TCP only where it is told, so
	// the two addresses this scenario's links name are named here. Production
	// cross-server joins use authenticated iroh, which needs no such list.
	env: { GLOWCAP_RELAY_TCP_PEERS: `127.0.0.1:${foreignRoomPort},127.0.0.1:${deadPort}` },
	stdout: "null",
	stderr: "inherit",
});

let browser: Browser | null = null;
try {
	await waitForHttp(httpPort);
	browser = await chromium.launch({ args: ["--no-sandbox"] });

	const ada = await joinAs(browser, httpPort, "ada");
	const bo = await joinAs(browser, httpPort, "bo");
	await ada.locator('#members li:has-text("bo")').waitFor({ state: "visible", timeout: 60_000 })
		.catch(() => fail("the two tabs never met in the public room"));

	// ── A room that is in no list ────────────────────────────────────────
	await makeRoom(ada, LABEL, true);
	await ada.waitForFunction(
		() => document.querySelector("#roomList li .hash svg") !== null,
		undefined,
		{ timeout: 30_000 },
	).catch(() => fail("naming a room privately did not put a private room in the rail"));
	const hers = await railRooms(ada);
	const locked = hers.filter((row) => row.locked);
	if (locked.length !== 1 || locked[0].name !== LABEL || !locked[0].here) {
		fail(`making a private room did not open exactly one, on screen: ${JSON.stringify(hers)}`);
	}
	// The panel at the top of a room says what kind of room a reader is in, and
	// the open sentence over a private room would be the worst answer here.
	const panel = (await ada.textContent(".conv-intro")) ?? "";
	if (!panel.includes("private") || panel.includes("Anyone who knows its name")) {
		fail(`a private room's panel does not say what it is: ${JSON.stringify(panel)}`);
	}
	if (await ada.locator(".conv-intro .hash svg").count() !== 1) {
		fail("a private room's welcome title did not wear the lock");
	}
	// The private room's spoken name — the label with no hash — is the rail
	// row's and the intro panel's, both pinned above. The rail foot no longer
	// names rooms at all: it is the reader's identity-and-standing lockup, so
	// there is no third spelling to hold to the same authority.
	await say(ada, PRIVATE_LINE);
	await ada.waitForFunction(
		(text) => (document.getElementById("log")?.textContent ?? "").includes(text),
		PRIVATE_LINE,
		{ timeout: 30_000 },
	).catch(() => fail("ada's own line never landed in her private room"));

	// The directory does not offer it, to anybody. `/list` is the whole of what
	// a directory will say about its rooms, so this is the surface a stranger
	// would find it on if it were findable at all.
	await say(bo, "/list");
	await bo.waitForFunction(
		(room) => (document.getElementById("log")?.textContent ?? "").includes(`#${room}: `),
		ROOM,
		{ timeout: 30_000 },
	).catch(() => fail("/list never answered"));
	const listed = await said(bo);
	if (listed.includes(`#${LABEL}: `)) {
		fail(`the directory offered a private room in its list: ${JSON.stringify(listed.slice(-200))}`);
	}

	// And to somebody who was not here when it was made. Bo's list was built
	// from the changes the directory pushed him, which is one of the two ways a
	// room can be offered; a tab arriving now is handed the whole list at once,
	// which is the other, and a guard on one of them is not a guard.
	const cy = await joinAs(browser, httpPort, "cy");
	await say(cy, "/list");
	await cy.waitForFunction(
		(room) => (document.getElementById("log")?.textContent ?? "").includes(`#${room}: `),
		ROOM,
		{ timeout: 30_000 },
	).catch(() => fail("/list never answered for a tab that arrived later"));
	const arrived = await said(cy);
	if (arrived.includes(`#${LABEL}: `)) {
		fail(`a tab arriving later was handed a private room in its list: ${JSON.stringify(arrived.slice(-200))}`);
	}

	// ── The label is a label ─────────────────────────────────────────────
	// Naming the same thing gets a room of one's own rather than a way into
	// hers, which is the difference between a name and an address.
	await makeRoom(bo, LABEL, false);
	await bo.waitForFunction(
		(label) => [...document.querySelectorAll("#roomList .rname")].some((row) => row.textContent === label),
		LABEL,
		{ timeout: 30_000 },
	).catch(() => fail("bo could not open a public room of his own by that name"));
	await say(bo, PUBLIC_LINE);
	await bo.waitForFunction(
		(text) => (document.getElementById("log")?.textContent ?? "").includes(text),
		PUBLIC_LINE,
		{ timeout: 30_000 },
	).catch(() => fail("bo's own line never landed in his own room"));
	const inBos = await said(bo);
	if (inBos.includes(PRIVATE_LINE)) {
		fail("naming a room the same thing reached the private one");
	}
	const inHers = await said(ada);
	if (inHers.includes(PUBLIC_LINE)) {
		fail("a public room of the same name reached into the private one");
	}

	// ── Handed over ──────────────────────────────────────────────────────
	await say(ada, "/invite bo");
	await bo.waitForSelector(".inviterow", { timeout: 30_000 })
		.catch(() => fail("handing the room over never reached bo"));
	const offered = (await bo.textContent(".inviterow")) ?? "";
	if (!offered.includes(LABEL) || !offered.includes("ada")) {
		fail(`the invitation does not say what it is or who it is from: ${JSON.stringify(offered)}`);
	}
	await bo.click(".inviterow .room-open");
	await bo.waitForFunction(
		() => document.querySelector("#roomList li.held.here") !== null,
		undefined,
		{ timeout: 30_000 },
	).catch(() => fail("taking up the invitation did not open the room"));
	const afterTaking = await railRooms(bo);
	if (afterTaking.filter((row) => row.locked).length !== 1) {
		fail(`taking up one invitation left bo with the wrong rooms: ${JSON.stringify(afterTaking)}`);
	}
	// He arrives under his own name, and ada is still here to see it. Both
	// halves of this assertion have caught a real defect: a room behaviour that
	// closed over the session it was spawned for blamed bo's subscribe on ada's
	// connection, which silently replaced her own membership — she vanished
	// from her own room, and bo arrived into an empty roster.
	await ada.waitForFunction(
		() => [...document.querySelectorAll("#members li")].some((row) => row.textContent?.includes("bo")),
		undefined,
		{ timeout: 30_000 },
	).catch(() => fail("ada never saw bo arrive in her private room"));
	const roster = await ada.evaluate(() =>
		[...document.querySelectorAll("#members li")].map((row) => row.textContent ?? "")
	);
	if (roster.some((row) => row.includes("bo-"))) {
		fail(`the handed reference seated bo as a suffixed stranger: ${JSON.stringify(roster)}`);
	}
	// What she says now reaches him: he is in the room, by the reference she
	// handed him and nothing else.
	const second = "and here is the thing itself";
	await say(ada, second);
	await bo.waitForFunction(
		(text) => (document.getElementById("log")?.textContent ?? "").includes(text),
		second,
		{ timeout: 30_000 },
	).catch(() => fail("bo took up the invitation but the room never reached him"));

	// ── A public room handed over stays public ───────────────────────────
	// The same gesture from bo's listed "plans": /invite hands the reference,
	// but a listed room is its name on the directory. Taking the offer up
	// seats ada in the listed room, beside — never inside — the private room
	// wearing the same label.
	const handedPublicLine = "handed over, and still the listed room";
	await openRailRoom(bo, LABEL, false);
	await say(bo, "/invite ada");
	await ada.waitForSelector(".inviterow", { timeout: 30_000 })
		.catch(() => fail("handing the listed room over never reached ada"));
	await ada.click(".inviterow .room-open");
	await ada.waitForFunction(
		(label) =>
			[...document.querySelectorAll("#roomList li")].some((li) =>
				(li.querySelector(".rname")?.textContent ?? "") === label &&
				li.querySelector(".hash svg") === null
			),
		LABEL,
		{ timeout: 30_000 },
	).catch(() => fail("taking up a listed room's offer did not seat ada in the listed room"));
	const adaPlans = (await railRooms(ada)).filter((row) => row.name === LABEL);
	if (adaPlans.length !== 2 || adaPlans.filter((row) => row.locked).length !== 1) {
		fail(`the listed offer did not sit beside the private room: ${JSON.stringify(adaPlans)}`);
	}
	await say(ada, handedPublicLine);
	await bo.waitForFunction(
		(text) => (document.getElementById("log")?.textContent ?? "").includes(text),
		handedPublicLine,
		{ timeout: 30_000 },
	).catch(() => fail("ada's line never reached the listed room she was handed"));
	await openRailRoom(ada, LABEL, true);
	if ((await said(ada)).includes(handedPublicLine)) {
		fail("a listed room's offer reached into the private room of the same name");
	}
	await openRailRoom(bo, LABEL, true);

	// ── The link on its own ──────────────────────────────────────────────
	// An invitation through the rail is one channel; the link under it is the
	// authority, and it works with no channel at all. Ada reads hers out. Cy
	// `/join`s that locator and nothing else — the same paste a person makes —
	// and lands in the room under the name it already has, not an invented one.
	const shown = await roomLink(ada, "ada");
	await say(ada, `/join ${shown}`);
	await ada.waitForFunction(
		() => (document.getElementById("log")?.textContent ?? "").includes("You are already in this room."),
		undefined,
		{ timeout: 15_000 },
	).catch(() => fail("joining a room this tab is already in did not say so"));
	const adaHeld = (await railRooms(ada)).filter((row) => row.locked);
	if (adaHeld.length !== 1 || adaHeld[0].name !== LABEL) {
		fail(`joining this tab's own link duplicated the room: ${JSON.stringify(adaHeld)}`);
	}
	await say(cy, `/join ${shown}`);
	await cy.waitForFunction(
		() => document.querySelector("#roomList li.held") !== null,
		undefined,
		{ timeout: 30_000 },
	).catch(async () => {
		const log = (await cy.textContent("#log").catch(() => "?")) ?? "?";
		fail(`a reader holding the link alone could not get in: ${JSON.stringify(log.slice(-200))}`);
	});
	const heard = "anybody holding the link is here";
	await say(ada, heard);
	await cy.waitForFunction(
		(text) => (document.getElementById("log")?.textContent ?? "").includes(text),
		heard,
		{ timeout: 30_000 },
	).catch(() => fail("the reader who redeemed the link is not in the room"));
	// The locator is to this room, so `/join` of it sits here under this room's
	// name, not under a placeholder the joiner never typed.
	const named = (await railRooms(cy)).find((row) => row.locked);
	if (named?.name !== LABEL) {
		fail(`a room taken up by link is not called what it already is: ${JSON.stringify(named)}`);
	}
	// And it cost him no second connection to the server he was already on. A
	// link for a directory this tab holds is redeemed on that very session:
	// two live sessions to one peer would split its rooms, its granted name and
	// its direct lines between them, and the rail marks directories the moment
	// there is more than one to tell apart.
	if (await directoriesNamed(cy) !== 0) {
		fail("a link for the directory this tab already held opened a second session to it");
	}

	// ── A link from a server this tab has never met ──────────────────────
	// The link is the whole authority and it names its own peer, so the room it
	// reaches need not be on any directory the reader holds. Di makes a private
	// room on a second server and reads its link out.
	await waitForTcp(foreignRoomPort, "the second room server");
	const di = await browser.newPage();
	await di.goto(`http://127.0.0.1:${httpPort}/`);
	await establishLocalSession(di);
	await di.waitForSelector("#joinBtn", { timeout: 20_000 });
	await di.fill("#locator", foreignLocator);
	await di.fill("#nick", "di");
	// The room question is behind the directory, so reach it before answering.
	await reachDirectoryOnCard(di);
	await di.fill("#room", "elsewhere");
	// Open, moderated, private: two presses to reach the one this turns on.
	await di.click("#joinPrivate");
	await di.click("#joinPrivate");
	await di.click("#joinBtn");
	await di.waitForSelector("#line:not([disabled])", { timeout: 60_000 })
		.catch(async () => {
			const status = await di.textContent("#status").catch(() => "?");
			fail(`di never reached a private room on the second server; status="${status}"`);
		});
	const elsewhere = await roomLink(di, "di");
	// The address in the link is the one her room is actually on. Everything
	// below turns on that, so it is checked rather than assumed.
	if (!elsewhere.includes(`%3A${foreignRoomPort}.`)) {
		fail(`the link di read out does not name the server hosting her room: ${JSON.stringify(elsewhere)}`);
	}

	// Two ways a link can be no good, and they are not the same news. This one
	// names a peer that is not there, so it fails on the way to the room.
	// The relay closes before CapTP connects; the notice must keep that cause.
	const nowhere = elsewhere.replace(`%3A${foreignRoomPort}.`, `%3A${deadPort}.`);
	if (nowhere === elsewhere) fail("could not aim a link at a port nothing is holding");
	await say(cy, `/join ${nowhere} nowhere`);
	await cy.waitForFunction(
		() =>
			[...document.querySelectorAll("#log .sys")].some((row) =>
				(row.textContent ?? "").includes("That link did not open a room") &&
				(row.textContent ?? "").includes("connection closed during the OCapN handshake")
			),
		undefined,
		{ timeout: 60_000 },
	).catch(async () =>
		fail(
			`a link naming a peer nobody is holding was not refused in words: ${
				JSON.stringify(await refusalAbout(cy))
			}`,
		)
	);
	if (await directoriesNamed(cy) !== 0) {
		fail("a link that could not be reached left its server in the rail");
	}

	// This one names the right peer and the wrong room, so it fails at the
	// directory. The notice must keep the fetch refusal distinct from a failed
	// connection, without claiming that an unknown secret identifies a room.
	const parsedLink = parseRoomsSturdyref(elsewhere);
	const wrongSwiss = parsedLink.swissnum.slice();
	wrongSwiss[wrongSwiss.length - 1] ^= 1;
	const wrongSecret = formatRoomsSturdyref(parsedLink.locator, wrongSwiss);
	await say(cy, `/join ${wrongSecret} nothing`);
	await cy.waitForFunction(
		() =>
			[...document.querySelectorAll("#log .sys")].some((row) =>
				(row.textContent ?? "").includes("That link did not open a room") &&
				(row.textContent ?? "").includes("unknown swissnum")
			),
		undefined,
		{ timeout: 60_000 },
	).catch(async () =>
		fail(`a link with the wrong secret was not refused in words: ${JSON.stringify(await refusalAbout(cy))}`)
	);
	// Redeeming that one opened the directory it named, and it did not seat a
	// room there. A server the reader never asked to hold is given back rather
	// than left in the rail with nothing under it.
	if (await directoriesNamed(cy) !== 0) {
		fail("a link the directory refused left that directory held with no room in it");
	}

	// Bo holds only the directory his page serves. Pasting di's link is the
	// whole of getting into a room on a server he has never spoken to.
	await say(bo, `/join ${elsewhere} elsewhere`);
	await bo.waitForFunction(
		() => [...document.querySelectorAll("#roomList .rname")].some((row) => row.textContent === "elsewhere"),
		undefined,
		{ timeout: 60_000 },
	).catch(async () => {
		const log = (await bo.textContent("#log").catch(() => "?")) ?? "?";
		fail(`a link minted on another server did not open its room: ${JSON.stringify(log.slice(-300))}`);
	});
	// Under the peer that hosts it, which is the whole claim: the room is on a
	// session to di's server, not proxied through the one that served the page.
	const under = await bo.evaluate(() => {
		const row = [...document.querySelectorAll("#roomList li")]
			.find((li) => li.querySelector(".rname")?.textContent === "elsewhere");
		return {
			where: row?.querySelector(".rwhere-said")?.textContent ?? "",
			locked: row?.querySelector(".hash svg") !== null,
		};
	});
	if (!under.where.includes(`127.0.0.1:${foreignRoomPort}`)) {
		fail(`the room bo reached by link is not filed under the server hosting it: ${JSON.stringify(under)}`);
	}
	if (!under.locked) fail("a private room reached by link is not drawn as one");
	// And it is the room, not a room: what di says next reaches him.
	const across = "the link was the whole of the introduction";
	await say(di, across);
	await bo.waitForFunction(
		(text) => (document.getElementById("log")?.textContent ?? "").includes(text),
		across,
		{ timeout: 30_000 },
	).catch(() => fail("bo redeemed the link but the room on the second server never reached him"));

	// ── Declined ─────────────────────────────────────────────────────────
	// A second room, offered and refused. Declining lets the reference go, so
	// the row is answered and no room appears.
	await makeRoom(ada, "quiet", true);
	await ada.waitForFunction(
		(label) => [...document.querySelectorAll("#roomList .rname")].some((row) => row.textContent === label),
		"quiet",
		{ timeout: 30_000 },
	).catch(() => fail("ada could not make a second private room"));
	await say(ada, "/invite bo");
	await bo.waitForSelector(".inviterow", { timeout: 30_000 })
		.catch(() => fail("the second invitation never arrived"));
	await bo.click(".inviterow .room-leave");
	await bo.waitForFunction(
		() => document.querySelector(".inviterow") === null,
		undefined,
		{ timeout: 30_000 },
	).catch(() => fail("declining an invitation left it in the rail"));
	const afterDeclining = await railRooms(bo);
	if (afterDeclining.some((row) => row.name === "quiet")) {
		fail(`declining an invitation put the reader in the room anyway: ${JSON.stringify(afterDeclining)}`);
	}

	// The join card's own way in: a reader arriving cold — at this directory or
	// a foreign one, the branch is the same — makes a private room without first
	// announcing themselves in a listed room. The card's lock is pressed, the
	// join lands in a room whose intro says it is private, and the other tab's
	// live list never shows it.
	const cold = await browser.newPage();
	await cold.goto(`http://127.0.0.1:${httpPort}/`);
	await establishLocalSession(cold);
	await cold.waitForSelector("#joinBtn", { timeout: 20_000 });
	await cold.fill("#nick", "cole");
	await cold.fill("#room", "colddrop");
	const publicLabel = (await cold.textContent('label[for="room"]'))?.trim();
	if (publicLabel !== "Room") {
		fail(
			`the join card labeled the room field ${JSON.stringify(publicLabel)} before its access control was pressed`,
		);
	}
	await cold.click("#joinPrivate");
	await cold.click("#joinPrivate");
	const privateLabel = (await cold.textContent('label[for="room"]'))?.trim();
	if (privateLabel !== "Private room") {
		fail(
			`the join card labeled the room field ${JSON.stringify(privateLabel)} after pressing through to private`,
		);
	}
	await cold.click("#joinBtn");
	await cold.waitForFunction(() => {
		const intro = document.querySelector("#log .conv-intro p")?.textContent ?? "";
		return intro.includes("private");
	}, { timeout: 20_000 }).catch(() => fail("the join card's access control did not open a private room"));
	await ada.waitForTimeout(400);
	const listedCold = await ada.evaluate(() =>
		[...document.querySelectorAll("#roomList .rname")].map((row) => row.textContent?.trim())
	);
	if (listedCold.includes("colddrop")) {
		fail("a private room made from the join card appeared in another tab's room list");
	}
	await cold.close();

	console.log(
		"PASS: a private room is reachable only by the authority to it — it is in no list, " +
			"naming the same thing opens a different room, an offer over a direct line is what " +
			"puts somebody else in it, and the link under that offer gets a reader in with no " +
			"channel at all — `/join` of that locator sits in the room under its name; a declined offer " +
			"leaves them out. A link redeems where it says: on the session this tab already " +
			"holds when it names that directory, and on one opened beside it when it names " +
			"another. A link whose peer is not there and a link whose secret is wrong are " +
			"refused in words of their own, and neither leaves a server behind",
	);
} finally {
	clearTimeout(deadline);
	if (browser) await browser.close().catch(() => {});
	await reapOwned();
}
Deno.exit(0);
