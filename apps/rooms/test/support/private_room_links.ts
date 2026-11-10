// The private room proof's scenes on the room card's links tab. A member who
// came in by name takes the manager and moderator links there, runs the room,
// and joins by the room's own link without a second row. A member invited by
// someone who holds the room's link receives that link, sees it on the card,
// and keeps the room across a reload. ada made both rooms, cy stands in the
// lobby by name, and bo holds the private room by the link ada sent.
import type { Page } from "playwright";
import { fail } from "./fail.ts";
import { ROOM } from "./join.ts";
import { awaitBubble, say } from "../page/harness.ts";
import { heard, openRailRoom, railRooms, roomLink, said, told } from "./private_room_page.ts";
import { roomLinkLine } from "../../lib/text/commands.ts";
import { roomCapabilitiesLead, roomManagerTakeCommit, roomModeratorTakeCommit } from "../../lib/text/room_authority.ts";
import { alreadyInRoom } from "../../lib/text/attached.ts";

/** The link the room card shows at `id`, once it shows one. The card asks the
 * server for its links after the tab opens, so a read before the answer sees
 * an empty field. On a miss, fail with what the links tab showed instead. */
async function linkOnCard(tab: Page, id: string, what: string): Promise<string> {
	await tab.waitForFunction(
		(id) => (document.querySelector(id)?.textContent ?? "").trim().startsWith("ocapn://"),
		id,
		{ timeout: 30_000 },
	).catch(async () => {
		const links = await tab.evaluate(() => document.querySelector('[aria-label="Room links"]')?.textContent ?? "");
		fail(`${what}: ${JSON.stringify(links.slice(0, 3000))}`);
	});
	return (await tab.textContent(id))?.trim() ?? "";
}

export async function linksTakenFromASeat(ada: Page, cy: Page): Promise<void> {
	// ── A link is taken where you stand ─────────────────────────────────
	// cy came into the lobby by its name and holds no room link. ada, who made
	// the lobby, hands her the manager link and a moderator link, and cy takes
	// both on the room card without leaving the room, because her seat says
	// which room she is in.
	await openRailRoom(ada, ROOM, false);
	await ada.click("#roomAbout");
	await ada.click("#convcardCapabilitiesTab");
	const lobbyManager = await linkOnCard(
		ada,
		"#convcardManager",
		"the lobby's maker holds no manager link to hand over",
	);
	await ada.keyboard.press("Escape");
	await openRailRoom(cy, ROOM, false);
	await cy.click("#roomAbout");
	await cy.click("#convcardCapabilitiesTab");
	await cy.waitForSelector("#convcardLinksLead").catch(() =>
		fail("the room card did not say what the links are and that they are taken here")
	);
	if ((await cy.textContent("#convcardLinksLead"))?.trim() !== roomCapabilitiesLead) {
		fail("the room card's links lead is not the catalog's");
	}
	const takenOnCard = async (tab: Page, id: string, handed: string, what: string) => {
		const held = await linkOnCard(tab, id, `a member who came in by name could not take the ${what}`);
		if (held !== handed) fail(`the ${what} on the card is not the one handed: ${JSON.stringify(held)}`);
	};
	await cy.fill("#convcardManagerTake", lobbyManager);
	await cy.getByRole("button", { name: roomManagerTakeCommit }).click();
	await takenOnCard(cy, "#convcardManager", lobbyManager, "manager link");
	await ada.click("#roomAbout");
	await ada.click("#convcardCapabilitiesTab");
	await ada.click("#convcardStewardClaim");
	const lobbySteward = await linkOnCard(
		ada,
		"#convcardSteward",
		"the lobby's manager could not issue a moderator link",
	);
	await ada.keyboard.press("Escape");
	await cy.fill("#convcardStewardTake", lobbySteward);
	await cy.getByRole("button", { name: roomModeratorTakeCommit }).click();
	await takenOnCard(cy, "#convcardSteward", lobbySteward, "moderator link");
	await cy.keyboard.press("Escape");
	// The taken manager link runs the room: /link from the seat that held
	// no link now says the room's own link, the one the card shows.
	const lobbyLink = await roomLink(cy, "cy");
	await say(cy, "/link");
	await told(cy, roomLinkLine(ROOM, lobbyLink), "/link with a taken manager link did not say the room link");
	// A link to the room cy already stands in is that room's way in, not a
	// second row. The join lands with nothing new to show, so a second join is
	// what proves it settled: it finds the room entered by that link.
	for (let attempt = 0;; attempt++) {
		await say(cy, "/join " + lobbyLink);
		if (await heard(cy, alreadyInRoom, 3_000)) break;
		if (attempt === 4) {
			fail(
				`joining the lobby by its link from a seat in it never settled: ${
					JSON.stringify((await said(cy)).slice(-200))
				}`,
			);
		}
	}
	const lobbyRows = (await railRooms(cy)).filter((row) => row.name === ROOM);
	if (lobbyRows.length !== 1) {
		fail(`a link to a room cy stands in made ${lobbyRows.length} rows: ${JSON.stringify(lobbyRows)}`);
	}
	await say(ada, "still one room after the link");
	await awaitBubble(cy, "still one room after the link", "cy");
}

export async function invitedRoomOnCard(ada: Page, bo: Page, label: string): Promise<void> {
	// ── An invitation carries the room's link ───────────────────────────
	// ada made the room, so she holds its link, and /invite sent bo that link
	// rather than the live reference. His card shows it to copy, the same one
	// hers shows, with nothing to create, and /link says it back.
	await openRailRoom(ada, label, true);
	const held = await roomLink(ada, "ada");
	await openRailRoom(bo, label, true);
	await bo.click("#roomAbout");
	await bo.click("#convcardCapabilitiesTab");
	const given = await linkOnCard(bo, "#convcardRoomLink", "the invited room's card shows no link to copy");
	if (given !== held) fail(`the invited room's link is not the one its maker holds: ${JSON.stringify(given)}`);
	if (await bo.locator("#convcardCreateRoomLink").count() !== 0) {
		fail("a room invited with its link offered to create one");
	}
	await bo.keyboard.press("Escape");
	await say(bo, "/link");
	await told(bo, roomLinkLine(label, given), "/link from a room invited with its link did not say it");
	// ── The link outlasts the page ───────────────────────────────────────
	// A reload ends every live reference the page held. The saved link seats
	// bo in the room again: ada hears him there, and he still hears her.
	await bo.reload();
	await bo.waitForSelector("#line:not([disabled])", { timeout: 60_000 })
		.catch(() => fail("bo's reloaded page never re-entered a room"));
	await openRailRoom(bo, label, true);
	await bo.waitForSelector("#line:not([disabled])", { timeout: 60_000 })
		.catch(() => fail("bo's reloaded page did not re-enter the room he was invited to"));
	const back = "back after the reload";
	await say(bo, back);
	await awaitBubble(ada, back, "ada");
	const line = "and still hearing ada";
	await say(ada, line);
	await awaitBubble(bo, line, "bo");
}
