import { spawnWeb, webPort } from "../support/web_front.ts";
// A room nobody can look up, and the only way into one.
//
// A public room is reached by its name: the directory lists it, `enter` finds
// it, and knowing what it is called is the whole of being able to walk in. A
// private room is the same room with none of that. It is in no list, `enter`
// does not find it, and its name is a label two of them may share. What is left
// is the reference, and holding one is being in the room.
//
// So an invitation is the authority to the room, sent over the direct line this
// reader already has, with the room and the directory told nothing about who
// was offered what. It takes one of two forms. An inviter who holds the room's
// link sends that link, which the guest saves and keeps across a reload. An
// inviter who holds the room only as a live reference hands that reference on
// as a third-party handoff, and it lasts while the guest's page stays open.
// Every inviter here holds the link, so this proof drives the first form. The
// session executor proofs drive the second, and `/link` reads the link out for
// an offer with no direct line at all.
//
// Here both routes to the server spell it the same way, so taking up an
// invitation reuses the session the guest already holds and his name needs no
// proof.
// A deployment where the spellings diverge opens a second session, and the
// name-capability voucher seats him there; that half is pinned hermetically in
// server_test.ts, where a byte pipe makes the divergence.
//
// So this drives the difference rather than the feature. Two tabs on one
// directory:
//
//   ada  makes a private room called "plans" and says something in it.
//   bo   asks for the room list, and it is not there.
//   bo   names a room "plans" himself, and gets a different room with the same
//        label and none of ada's content. The label carries no authority.
//   ada  invites bo. He takes the room's link up, hears what she said next,
//        and is still in the room after his page reloads.
//   bo   is offered a second one and declines it, which lets the reference go.
//
// And then the link on its own, which is the part no directory has to be in on.
// Ada's Capabilities control mints the bearer link another tab enters by.
// A second room server stands beside the page's own, di makes a room there and
// reads its link out, and bo, who holds only the directory his page serves,
// pastes it. The link names its own peer, so that is the peer the room is
// redeemed on: the tab opens that directory beside the one it had. The two ways
// a link can be no good are told apart on the way, and neither leaves a server
// behind in the rail.
//
// Needs deno, the wasm module (`zig build wasm-host`), the installed archives
// (the web front and room server run Rust), and a Playwright Chromium.
// Run: `zig build rooms-web-private`.

import { SERVER } from "../support/paths.ts";
import { parseRoomsSturdyref } from "../../lib/locator.ts";
import { formatRoomsSturdyref } from "../support/sturdyref.ts";
import {
	inviteWithoutTheRoom,
	kickWithoutModerator,
	notRegisteredForDirect,
	roomLinkLine,
} from "../../lib/text/commands.ts";
import { roomLinkNoneHint } from "../../lib/text/room_authority.ts";
import { type Browser, chromium } from "playwright";
import { establishLocalSession } from "../support/session_setup.ts";
import { reapOwned, spawnOwned } from "../support/children.ts";
import { fail } from "../support/fail.ts";
import { nonEphemeralPort } from "../../../../bindings/ts/test/ports.ts";
import { joinAs, ROOM } from "../support/join.ts";
import { say } from "../page/harness.ts";
import { invitedRoomOnCard, linksTakenFromASeat } from "../support/private_room_links.ts";
import { readPort, waitForHttp } from "../support/rooms_server.ts";
import {
	directoriesNamed,
	makeRoom,
	openRailRoom,
	railRooms,
	refusalAbout,
	roomLink,
	said,
	told,
	waitForTcp,
} from "../support/private_room_page.ts";
import { reachDirectoryOnCard } from "../page/harness.ts";

const ROOT = new URL("../../../../", import.meta.url).pathname;
const LABEL = "plans";
const PRIVATE_LINE = "just us then";
const PUBLIC_LINE = "this is my own plans room";

const deadline = setTimeout(() => fail("web-private-room scenario timed out after 240s"), 240_000);

// A second authority: another room server, not another room on the page's own.
const foreign = spawnOwned(SERVER, {
	args: ["--transport=tcp", "--port=0"],
	cwd: ROOT,
	stdout: "piped",
	stderr: "inherit",
});
const foreignRoomPort = await readPort(foreign);
const foreignLocator = `127.0.0.1:${foreignRoomPort}`;
// A port nothing ever listens on stands for a link whose peer is not there.
const deadPort = nonEphemeralPort();

const front = spawnWeb({
	args: ["--transport=tcp", "0", "0"],
	cwd: ROOT,
	// A relay dials iroh anywhere and cleartext TCP only where it is told, so
	// the two addresses this scenario's links name are named here. Production
	// cross-server joins use authenticated iroh, which needs no such list.
	env: { GLOWCAP_RELAY_TCP_PEERS: `127.0.0.1:${foreignRoomPort},127.0.0.1:${deadPort}` },
	stdout: "piped",
	stderr: "inherit",
});
const httpPort = await webPort(front);

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
	// The private room's spoken name, the label with no hash, is the rail
	// row's and the intro panel's, both pinned above. The rail foot does not
	// name rooms at all: it is the reader's identity-and-standing lockup, so
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
	// room can be offered; a tab arriving later is handed the whole list at once,
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
	// A seat in a room is not the room. cy joined the lobby by its name after
	// ada made it, so she holds nothing to hand over, and the refusal says the
	// way in instead of claiming there is no room.
	await say(cy, "/invite bo");
	await cy.waitForFunction(
		(sentence) => (document.getElementById("log")?.textContent ?? "").includes(sentence),
		inviteWithoutTheRoom(ROOM, true),
		{ timeout: 15_000 },
	).catch(async () =>
		fail(
			`a member seated in a room she does not hold was not told the way in: ${
				JSON.stringify((await said(cy)).slice(-200))
			}`,
		)
	);
	await say(ada, "/invite bo");
	await bo.waitForSelector(".inviterow", { timeout: 30_000 })
		.catch(async () => {
			const state = (page: typeof ada) =>
				page.evaluate(() => ({
					title: document.title,
					log: document.querySelector("#log")?.textContent,
					status: document.querySelector("#status")?.textContent,
					rooms: document.querySelector("#roomList")?.textContent,
					composer: (document.querySelector("#line") as HTMLTextAreaElement | null)?.value,
					notices: [...document.querySelectorAll(".toast")].map((node) => node.textContent),
				}));
			fail(
				`handing the room over never reached bo: ${
					JSON.stringify({ ada: await state(ada), bo: await state(bo) })
				}`,
			);
		});
	const offered = (await bo.textContent(".inviterow")) ?? "";
	if (!offered.includes(LABEL) || !offered.includes("ada")) {
		fail(`the invitation does not say what it is or who it is from: ${JSON.stringify(offered)}`);
	}
	// The row answers a take with the shared progress ring. The ring is drawn by
	// a busy mark on the button, so the mark is set and read in one turn.
	const ring = await bo.evaluate(() => {
		const take = document.querySelector(".inviterow .room-open");
		if (take == null) return null;
		take.setAttribute("data-busy", "");
		const drawn = getComputedStyle(take, "::after").width;
		take.removeAttribute("data-busy");
		return drawn;
	});
	if (ring !== "13px") fail(`a busy invitation row draws no progress ring: ${JSON.stringify(ring)}`);
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
	// connection, which silently replaced her own membership, she vanished
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
		fail(`the invitation seated bo as a suffixed stranger: ${JSON.stringify(roster)}`);
	}
	// What she says now reaches him: he is in the room, by the link she sent
	// him and nothing else.
	const second = "and here is the thing itself";
	await say(ada, second);
	await bo.waitForFunction(
		(text) => (document.getElementById("log")?.textContent ?? "").includes(text),
		second,
		{ timeout: 30_000 },
	).catch(() => fail("bo took up the invitation but the room never reached him"));
	await invitedRoomOnCard(ada, bo, LABEL);

	// ── A public room handed over stays public ───────────────────────────
	// The same gesture from bo's listed "plans": /invite sends its link, but
	// a listed room is its name on the directory. Taking the offer up
	// seats ada in the listed room, beside, never inside, the private room
	// wearing the same label.
	const handedPublicLine = "handed over, and still the listed room";
	await openRailRoom(bo, LABEL, false);
	await say(bo, "/invite ada");
	await ada.waitForSelector(".inviterow", { timeout: 30_000 })
		.catch(() => fail("handing the listed room over never reached ada"));
	await ada.click(".inviterow .room-open");
	await ada.waitForFunction(
		(label) => {
			const line = document.querySelector<HTMLTextAreaElement>("#line");
			return line != null && !line.disabled &&
				[...document.querySelectorAll("#roomList li")].some((li) =>
					(li.querySelector(".rname")?.textContent ?? "") === label &&
					li.querySelector(".hash svg") === null && li.classList.contains("here")
				);
		},
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
	// `/join`s that locator and nothing else, the same paste a person makes,
	// and lands in the room under the name it already has, not an invented one.
	const shown = await roomLink(ada, "ada");
	// Typed, the same link is said back where it was typed. A member who only
	// holds a seat is told the link is not theirs to mint, and asking a member
	// out without the moderator capability says so, instead of a generic
	// failure with the reason lost.
	await say(ada, "/link");
	await told(ada, roomLinkLine(LABEL, shown), "/link did not say the room link back");
	await say(cy, "/link");
	await told(cy, roomLinkNoneHint, "/link from a seat did not say the link is not this session's to mint");
	await say(cy, "/kick bo");
	await told(cy, kickWithoutModerator, "/kick without the moderator capability did not say so");
	// A name nobody registered is the reader's typo, said where they typed it.
	await say(cy, "/msg nobody-9");
	await told(cy, notRegisteredForDirect("nobody-9"), "/msg to a name nobody holds did not say so");
	await say(ada, "/invite nobody-9");
	await told(ada, notRegisteredForDirect("nobody-9"), "/invite to a name nobody holds did not say so");
	await say(ada, `/join ${shown}`);
	await ada.waitForFunction(
		() => (document.getElementById("log")?.textContent ?? "").includes("You're already in this room."),
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
	await di.fill("#joinAddressField", foreignLocator);
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
	// The relay closes before CapTP connects, naming the cause in its Close
	// frame; the notice must keep that cause.
	const nowhere = elsewhere.replace(`%3A${foreignRoomPort}.`, `%3A${deadPort}.`);
	if (nowhere === elsewhere) fail("could not aim a link at a port nothing is holding");
	await say(cy, `/join ${nowhere} nowhere`);
	await cy.waitForFunction(
		() =>
			[...document.querySelectorAll("#log .sys")].some((row) =>
				(row.textContent ?? "").includes("That link didn't open a room") &&
				(row.textContent ?? "").includes("WebSocket closed by the peer (code 1011)")
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
				(row.textContent ?? "").includes("That link didn't open a room") &&
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
		() =>
			[...document.querySelectorAll("#roomList li")].some((row) =>
				row.querySelector(".rname")?.textContent === "elsewhere" && row.querySelector(".hash svg") !== null
			),
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

	// The join card's own way in: a reader arriving cold, at this directory or
	// a foreign one, the branch is the same, makes a private room without first
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
	if (publicLabel !== "Open room") {
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

	await linksTakenFromASeat(ada, cy);

	console.log(
		"PASS: a private room is reachable only by the authority to it — it is in no list, " +
			"naming the same thing opens a different room, an offer over a direct line is what " +
			"puts somebody else in it, carrying the room's link so the guest keeps it across a reload, " +
			"and that link gets a reader in with no " +
			"channel at all — `/join` of that locator sits in the room under its name; a declined offer " +
			"leaves them out. A link redeems where it says: on the session this tab already " +
			"holds when it names that directory, and on one opened beside it when it names " +
			"another. A link whose peer is not there and a link whose secret is wrong are " +
			"refused in words of their own, and neither leaves a server behind. A member who came in by " +
			"name takes the manager and moderator links on the room card without leaving the room, and " +
			"a refused `/invite`, `/link`, `/kick`, or `/msg` says why in the conversation, and a link to a room " +
			"the tab already stands in keeps that one row and its seat",
	);
} finally {
	clearTimeout(deadline);
	if (browser) await browser.close().catch(() => {});
	await reapOwned();
}
Deno.exit(0);
