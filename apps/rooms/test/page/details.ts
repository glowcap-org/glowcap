// The conversation card, and the rest of a long refusal.
//
// The title is the way into what this tab knows about the room or line on
// screen. `/details` opens the same card. The directory named there opens that
// directory's conversation. Its title opens the directory card. A room's card
// is where you stand in it and where you leave it. The title's close mark
// asks to leave in this same card. A long error stays two lines
// where it appeared, and Show is the way into the rest. Both cards are native
// dialogs, so Escape and a press on the dim around them put the reader back on
// the control that opened them.

import type { Page } from "playwright";
import { fail, openDirectoryCard } from "./harness.ts";
import { namedRoomRow } from "../support/conversation_row.ts";
import { reachPublicRoom } from "../../lib/text/conversation.ts";
import { roomManagerDiscardSay } from "../../lib/text/room_authority.ts";

export async function run(tab: Page): Promise<void> {
	// ── A long refusal stays in its slot ─────────────────────────────────
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	await tab.click("#helpBtn");
	await tab.waitForSelector("#helpTitle");
	// The writing help is drawn by the real parser, so it is either there whole
	// or the parser failed in the one place a reader is told what it does.
	await tab.click("#helpWritingTab");
	await tab.waitForSelector("#helpWritingPanel .help-example").catch(() =>
		fail("Help did not show how to write a message")
	);
	await tab.click("#helpGlossaryTab");
	await tab.click("#glossarySecret");
	await tab.waitForSelector("#kitchenSink").catch(() =>
		fail("Help did not open the parts catalog for the long refusal")
	);
	const boxed = await tab.evaluate(() => {
		const why = document.getElementById("kitchenLongSaid");
		const sample = why?.closest(".kitchen-sample");
		if (!(why instanceof HTMLElement) || sample == null) return null;
		const a = why.getBoundingClientRect();
		const b = sample.getBoundingClientRect();
		return {
			overflows: Math.round(a.right) > Math.round(b.right + 1) ||
				Math.round(a.bottom) > Math.round(b.bottom + 1),
			show: why.classList.contains("said-more"),
		};
	});
	if (boxed === null) fail("the parts catalog has no long refusal beside a field");
	if (!boxed.show) fail("a long refusal in the catalog is not the Show control");
	if (boxed.overflows) fail("a long refusal in the catalog shoved the field's sample off the card");
	await tab.click("#kitchenDynamicRefusalRun");
	await tab.waitForSelector("#kitchenDynamicRefusal.said-more").catch(() =>
		fail("a long refusal that arrived after mount did not become the Show control")
	);
	await tab.click("#kitchenLongSaid");
	await tab.waitForSelector("#errorTitle").catch(() => fail("Show did not open the rest of the refusal"));
	const rest = await tab.evaluate(() => {
		const body = document.getElementById("errorBody");
		const card = body?.closest(".modal-card");
		if (!(body instanceof HTMLElement) || card == null) return null;
		const a = body.getBoundingClientRect();
		const b = card.getBoundingClientRect();
		return {
			text: body.textContent ?? "",
			overflows: Math.round(a.right) > Math.round(b.right + 1),
			title: document.getElementById("errorTitle")?.textContent ?? "",
		};
	});
	if (rest === null) fail("the error card did not hold the rest of the refusal");
	if (rest.title !== "What went wrong") {
		fail(`the error card is titled ${JSON.stringify(rest.title)}`);
	}
	if (!rest.text.includes("unreachableswissnum")) {
		fail("the error card did not carry the locator the refusal named");
	}
	if (rest.overflows) fail("the rest of the refusal ran out of the error card");
	await tab.keyboard.press("Escape");
	await tab.waitForFunction(() => document.getElementById("errorTitle") === null)
		.catch(() => fail("Escape did not put the catalog back"));
	await tab.waitForFunction(() => document.activeElement?.id === "kitchenLongSaid")
		.catch(() => fail("closing the error card did not return focus to Show"));
	if (await tab.locator("#kitchenSink").count() === 0) {
		fail("reading the rest of a refusal threw the catalog away");
	}
	await tab.click("#kitchenBack");
	await tab.keyboard.press("Escape");
	await tab.waitForSelector("#settingsTitle");
	await tab.keyboard.press("Escape");
	await tab.waitForSelector("#settingsTitle", { state: "hidden" });

	// ── The title is the way into this conversation ──────────────────────
	await tab.click("#roomAbout");
	await tab.waitForSelector("#convcardTitle").catch(() => fail("the room title did not open what is known about it"));
	const about = await tab.evaluate(() => ({
		title: document.getElementById("convcardTitle")?.textContent?.trim() ?? "",
		locator: document.getElementById("convcardLocator")?.textContent?.trim() ?? "",
		facts: document.querySelector("#convcardTitle")?.closest(".modal-card")?.querySelector(".dirfacts")
			?.textContent ?? "",
		pressed: document.getElementById("roomAbout")?.getAttribute("aria-expanded"),
	}));
	if (!about.title.includes("lobby")) {
		fail(`the conversation card is titled ${JSON.stringify(about.title)}`);
	}
	if (about.locator === "" || about.locator === "…") {
		fail("the conversation card did not offer a locator to copy");
	}
	if (about.locator.includes("/s/")) {
		fail("a public room joined by name offered a sturdyref instead of the directory locator");
	}
	const kind = (await tab.textContent("#convcardUriKind"))?.trim() ?? "";
	if (kind !== "Directory locator") {
		fail(`the conversation card labeled the locator ${JSON.stringify(kind)}`);
	}
	// Against the catalog rather than a copy of the sentence. The words here are
	// owned by `lib/text`, and a literal repeated in a proof is a second copy
	// that a voice pass does not know it has to move: this assertion held a
	// sentence the app had stopped saying, and only stopped being green when an
	// unrelated failure earlier in the suite was fixed and the run reached it.
	const reach = ((await tab.textContent("#convcardReach")) ?? "").replace(/\s+/g, " ").trim();
	if (reach !== reachPublicRoom("#lobby")) {
		fail(`the conversation card did not say why the locator is the directory's: ${JSON.stringify(reach)}`);
	}
	if (!about.facts.includes("Public room") || !about.facts.includes("Connected")) {
		fail(`the conversation card did not say what this room is: ${JSON.stringify(about.facts)}`);
	}
	if ((await tab.getAttribute("#convcardAboutTab", "aria-selected")) !== "true") {
		fail("the room card did not open on About");
	}
	if (await tab.locator("#convcardModerationTab").count() !== 0) {
		fail("the room card offered moderation without its capability");
	}
	await tab.click("#convcardCapabilitiesTab");
	await tab.fill("#convcardStewardTake", "ocapn://draft.example/s/draft");
	await tab.click("#convcardAboutTab");
	await tab.click("#convcardCapabilitiesTab");
	if (await tab.inputValue("#convcardStewardTake") !== "ocapn://draft.example/s/draft") {
		fail("switching room-detail tabs discarded an unsaved capability draft");
	}
	await tab.click("#convcardClose");
	await tab.waitForSelector("#settingsUnsavedTitle").catch(() =>
		fail("closing room details with a capability draft did not stack the discard question")
	);
	await tab.click("#settingsUnsavedKeep");
	await tab.waitForSelector("#settingsUnsavedTitle", { state: "detached" });
	if (await tab.inputValue("#convcardStewardTake") !== "ocapn://draft.example/s/draft") {
		fail("keeping a room capability draft did not return to the intact form");
	}
	await tab.fill("#convcardStewardTake", "");
	const capGroup = (await tab.locator('[aria-label="Room capabilities"]').textContent()) ?? "";
	if (!capGroup.includes("Available through the held room manager")) {
		fail(`the conversation card did not show its moderation capability: ${JSON.stringify(capGroup)}`);
	}
	const manager = (await tab.textContent("#convcardManager"))?.trim() ?? "";
	if (!manager.startsWith("ocapn://") || !manager.includes("/s/")) {
		fail(`the conversation card did not expose its passable room manager: ${JSON.stringify(manager)}`);
	}
	if (!capGroup.includes("does not grant entry or moderation") || !capGroup.includes("delegates management")) {
		fail("the room manager did not explain the bounds and consequence of sharing it");
	}
	if (await tab.locator("#convcardStewardClaim").count() !== 1) {
		fail("the held room manager did not offer moderator capability issuance");
	}
	if (await tab.locator("#convcardStewardTake").count() !== 1) {
		fail("the conversation card did not offer a place to take a shared moderator capability");
	}
	await tab.click("#convcardStewardClaim");
	await tab.waitForFunction(() =>
		document.querySelector('[aria-label="Room capabilities"]')?.textContent?.includes("Held by this session") ===
			true
	).catch(async () => {
		const state = await tab.evaluate(() => ({
			refusal: document.getElementById("convcardStewardSaid")?.textContent,
			claim: document.getElementById("convcardStewardClaim")?.textContent,
			retained: document.getElementById("convcardSteward") != null,
			authority: document.querySelector('[aria-labelledby="convcardRoomAuthorityTitle"] dl')?.textContent,
		}));
		fail(`claiming moderation did not make possession visible in the room details: ${JSON.stringify(state)}`);
	});
	await tab.waitForSelector("#convcardSteward").catch(() =>
		fail("claiming moderation did not expose its handover capability in the room details")
	);
	if (await tab.locator("#convcardStewardClaim").count() !== 0) {
		fail("issuing moderation left the manager-backed action available a second time");
	}
	const steward = (await tab.textContent("#convcardSteward"))?.trim() ?? "";
	if (!steward.startsWith("ocapn://") || !steward.includes("/s/")) {
		fail(`the conversation card exposed an invalid moderator capability: ${JSON.stringify(steward)}`);
	}
	const stewardHint = (await tab.textContent("#convcardStewardHint")) ?? "";
	if (!stewardHint.includes("bearer authority") || !stewardHint.includes("Share it only")) {
		fail(`the moderator capability did not explain the authority being copied: ${JSON.stringify(stewardHint)}`);
	}
	await tab.waitForSelector("#convcardModerationTab").catch(() =>
		fail("holding moderation authority did not reveal the room's moderation operations")
	);
	await tab.click("#convcardModerationTab");
	if (await tab.locator('[aria-label="Room moderation"]').count() !== 1) {
		fail("the Moderation tab did not contain the room-scoped operations");
	}
	await tab.click("#convcardCapabilitiesTab");
	const linkBeforeDrop = (await tab.textContent("#convcardRoomLink"))?.trim() ?? "";
	await tab.click("#convcardStewardDropAsk");
	const dropQuestion = tab.getByRole("group", { name: "Discard room moderator capability" });
	if (!(await dropQuestion.textContent())?.includes("Other copies still work")) {
		fail("discarding moderation did not distinguish local release from revocation");
	}
	await dropQuestion.getByRole("button", { name: "Discard capability" }).click();
	await tab.waitForSelector("#convcardSteward", { state: "detached" });
	if ((await tab.textContent("#convcardRoomLink"))?.trim() !== linkBeforeDrop) {
		fail("discarding moderation also discarded the room link");
	}
	if (await tab.locator("#convcardModerationTab").count() !== 0) {
		fail("discarding moderation left live moderation operations visible");
	}
	await tab.fill("#convcardStewardTake", steward);
	await tab.getByRole("button", { name: "Take capability" }).click();
	await tab.waitForFunction(() =>
		document.querySelector('[aria-label="Room capabilities"]')?.textContent?.includes("Held by this session") ===
			true
	).catch(() => fail("a moderator capability discarded locally could not be taken again"));
	await tab.waitForSelector("#convcardModerationTab");
	await tab.click("#convcardManagerDropAsk");
	const discardManager = tab.getByRole("group", { name: "Discard room manager capability" });
	if (!(await discardManager.textContent())?.includes(roomManagerDiscardSay)) {
		fail("discarding room management did not distinguish local custody from revocation");
	}
	await discardManager.getByRole("button", { name: "Discard capability" }).click();
	await tab.waitForSelector("#convcardManager", { state: "detached" });
	if ((await tab.textContent("#convcardRoomLink"))?.trim() !== linkBeforeDrop) {
		fail("discarding room management changed the room link");
	}
	if ((await tab.textContent("#convcardSteward"))?.trim() !== steward) {
		fail("discarding room management changed the retained moderator capability");
	}
	await tab.fill("#convcardManagerTake", manager);
	await tab.getByRole("button", { name: "Take manager capability" }).click();
	await tab.waitForSelector("#convcardManager").catch(() =>
		fail("a discarded room manager capability could not be taken again")
	);
	if (about.pressed !== "true") fail("the title did not say the card was open");
	const hash = await tab.evaluate(() => document.querySelector("#convcardTitle .hash")?.textContent ?? "");
	if (hash !== "#") fail("a public room's card did not wear the hash the rest of the page wears");
	await tab.click("#convcardAboutTab");
	await tab.waitForSelector("#convcardStanding").catch(() =>
		fail("the conversation card did not offer where you are in this room")
	);
	await tab.click("#convcardLeaveAsk");
	await tab.waitForSelector("#convcardLeaveSaid").catch(() => fail("Leave this room did not ask before leaving"));
	const leaving = (await tab.textContent("#convcardLeaveSaid")) ?? "";
	if (!leaving.includes("come back")) {
		fail(`leaving a public room did not say you can come back: ${JSON.stringify(leaving)}`);
	}
	await tab.click("#convcardLeaveStay");
	await tab.waitForSelector("#convcardLeaveAsk").catch(() => fail("Stay did not put Leave this room back"));
	await tab.keyboard.press("Escape");
	await tab.waitForFunction(() => document.getElementById("convcardTitle") === null)
		.catch(() => fail("Escape did not put the conversation away after staying"));
	await tab.click("#leaveBtn");
	await tab.waitForSelector("#convcardLeaveSaid").catch(() =>
		fail("the title's mark did not ask before leaving the room")
	);
	await tab.click("#convcardLeaveStay");
	await tab.waitForSelector("#convcardLeaveAsk").catch(() =>
		fail("Stay from the title's mark did not keep the room")
	);
	await tab.click("#convcardDir");
	await tab.waitForFunction(() => location.pathname === "/directory", { timeout: 10_000 }).catch(() =>
		fail("the directory named on the conversation card did not open that directory")
	);
	await openDirectoryCard(tab);
	const dirTitle = (await tab.textContent("#dircardTitle"))?.toLowerCase() ?? "";
	if (!dirTitle.includes("directory")) {
		fail(`the directory card is titled ${JSON.stringify(dirTitle)}`);
	}
	await tab.keyboard.press("Escape");
	await tab.waitForFunction(() => document.getElementById("dircardTitle") === null)
		.catch(() => fail("Escape did not put the directory conversation back"));
	await tab.waitForFunction(() => document.activeElement?.id === "roomAbout")
		.catch(() => fail("closing the directory card did not return focus to the title"));
	await namedRoomRow(tab, "lobby").locator(".room-open").click();
	await tab.waitForSelector("#line:not([disabled])");

	await tab.click("#roomAbout");
	await tab.waitForSelector("#convcardTitle").catch(() => fail("returning to the room did not restore its title"));
	await tab.keyboard.press("Escape");
	await tab.waitForFunction(() => document.getElementById("convcardTitle") === null)
		.catch(() => fail("Escape did not put the conversation away"));
	await tab.waitForFunction(() => document.activeElement?.id === "roomAbout")
		.catch(() => fail("closing the conversation card did not return focus to the title"));

	await tab.fill("#line", "/details");
	await tab.press("#line", "Enter");
	await tab.waitForSelector("#convcardTitle").catch(() =>
		fail("/details did not open what is known about this room")
	);
	const again = await tab.evaluate(() => document.getElementById("convcardTitle")?.textContent?.trim() ?? "");
	if (!again.includes("lobby")) fail(`/details opened a card titled ${JSON.stringify(again)}`);
	await tab.keyboard.press("Escape");
	await tab.waitForFunction(() => document.getElementById("convcardTitle") === null)
		.catch(() => fail("Escape did not close the card /details opened"));
	await tab.waitForFunction(() => document.activeElement?.id === "line")
		.catch(() => fail("closing the card /details opened did not return focus to the composer"));
}
