// The IRC gateway scene of the Operations proof, end to end at the UI.
//
// Its toggle takes the capability, the pane bridges a channel (a dead
// endpoint is fine — joining registers the room and the connection retries
// behind it), the bridged room stands in the rail's namespace with an IRC
// badge, the room card carries the bridge's facts and the reader's own IRC
// identity form, the held gateway exposes the room-level unbridge, and
// parting takes it all down. The capability is dropped again at the end so
// the surrounding scenes keep their held-capability counts.

import type { Page } from "playwright";
import { fail } from "./harness.ts";
import { removeCapability, takeCapability } from "./capability_set.ts";
import { namedRoomRow } from "../support/conversation_row.ts";

export async function runIrcScene(tab: Page, ircSwiss: string): Promise<void> {
	await takeCapability(tab, "#opsIrcToggle", ircSwiss);
	await tab.waitForSelector("#opsBtn", { timeout: 15_000 });
	await tab.click("#opsBtn");
	await tab.waitForFunction(() => location.pathname === "/ops/irc");
	if (await tab.$("#opsNav") !== null) fail("one held capability still drew pane navigation");
	await tab.waitForSelector("#ircBridgedList");
	await tab.fill("#ircJoinNetwork", "deadnet");
	await tab.fill("#ircJoinChannel", "#nowhere");
	await tab.fill("#ircJoinHost", "127.0.0.1");
	await tab.fill("#ircJoinPort", "1");
	await tab.fill("#ircJoinNick", "proofbot");
	await tab.click("#ircJoinTls");
	await tab.click("#ircJoinBtn");
	await tab.waitForSelector('#ircBridgedList .entry[data-room="deadnet/#nowhere"]', { timeout: 10_000 });
	// Entered through the ordinary rail field, the bridged room stands as a
	// room with an IRC badge. Its second line remains directory context, the
	// same as every other room on that directory.
	await tab.click("#newRoomBtn");
	await tab.fill("#newRoomInput", "deadnet");
	await tab.waitForSelector('#newRoomOffers .complete-row:has-text("deadnet/#nowhere")', { timeout: 10_000 })
		.catch(() => fail("the rail field does not offer the bridged channel's name"));
	await tab.click('#newRoomOffers .complete-row:has-text("deadnet/#nowhere")');
	await tab.press("#newRoomInput", "Enter");
	const bridgedRow = namedRoomRow(tab, "deadnet/#nowhere");
	if ((await bridgedRow.locator(".irc-chip").textContent()) !== "IRC") {
		fail("the bridged room's primary rail line carries no IRC badge");
	}
	if (await bridgedRow.locator(".rwhere-bridge").count() !== 0) {
		fail("the bridged room used its directory subtitle for IRC connection details");
	}
	await bridgedRow.hover();
	await bridgedRow.locator(".room-leave").click();
	await bridgedRow.waitFor({ state: "detached", timeout: 10_000 })
		.catch(() => fail("the bridged room could not be left"));
	// Leaving the room stood us back at the front page; the Operations
	// control lives in the Settings head, so it opens through it.
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	await tab.click("#opsBtn");
	await tab.waitForSelector('#ircBridgedList .entry[data-room="deadnet/#nowhere"]', { timeout: 10_000 });
	// The row's own door: Open enters the room and stands the reader in it.
	await tab.click('#ircBridgedList .entry[data-room="deadnet/#nowhere"] button:has-text("Open")');
	await tab.waitForFunction(() => location.pathname === "/", undefined, { timeout: 10_000 });
	await namedRoomRow(tab, "deadnet/#nowhere", true).waitFor({ timeout: 10_000 })
		.catch(() => fail("Open on the bridged row did not stand the reader in the room"));
	await tab.click("#roomAbout");
	const about = (await tab.textContent("#convcardAboutPanel")) ?? "";
	if (!about.includes("Bridged via 127.0.0.1:1")) {
		fail(`the room About facts omitted its IRC endpoint: ${JSON.stringify(about)}`);
	}
	await tab.click("#convcardIrcTab");
	const ircState = (await tab.textContent("#convcardIrcState")) ?? "";
	if (!ircState.includes("bridged via 127.0.0.1:1")) {
		fail(`the IRC state fact omitted the bridge endpoint: ${JSON.stringify(ircState)}`);
	}
	await tab.click("#convcardModerationTab");
	await tab.waitForSelector("#convcardUnbridgeHint").catch(() =>
		fail("a held IRC gateway capability exposed no room-level unbridge operation")
	);
	await tab.click("#convcardClose");
	const ownBridge = tab.locator('#members li[data-network="rooms-failed"]');
	await ownBridge.waitFor({ timeout: 10_000 }).catch(() =>
		fail("the member list did not distinguish the reader's failed IRC link")
	);
	const ownBridgeSaid = (await ownBridge.textContent()) ?? "";
	if (!ownBridgeSaid.includes("FAILED") || !ownBridgeSaid.includes("IRC link failed")) {
		fail(`the failed IRC member row did not say its relationship: ${JSON.stringify(ownBridgeSaid)}`);
	}
	await ownBridge.getByRole("button", { name: "Manage your IRC identity" }).click();
	await tab.waitForSelector("#convcardIrcPanel").catch(() =>
		fail("the reader's member row did not open the IRC identity panel")
	);
	if ((await tab.getAttribute("#convcardIrcTab", "aria-selected")) !== "true") {
		fail("the member row opened room details somewhere other than IRC identity");
	}
	await tab.click("#convcardIrcDisconnect");
	await tab.waitForFunction(() => document.getElementById("convcardIrcState")?.textContent?.includes("Rooms only"))
		.catch(() => fail("disconnecting IRC did not leave the membership visibly Rooms-only"));
	await tab.fill("#convcardIrcNick", "bo-irc");
	await tab.check("#convcardIrcRegistered");
	await tab.fill("#convcardIrcAccount", "bo");
	await tab.fill("#convcardIrcPassword", "not-kept-after-submit");
	await tab.click("#convcardIrcLink");
	await tab.waitForSelector("#convcardIrcWhy");
	const identityWhy = (await tab.textContent("#convcardIrcWhy")) ?? "";
	if (!identityWhy.includes("TLS") && !identityWhy.includes("encrypted")) {
		fail(`the cleartext identity form did not surface the room's custody refusal: ${JSON.stringify(identityWhy)}`);
	}
	if (await tab.inputValue("#convcardIrcPassword") !== "") {
		fail("the IRC identity form retained its password after submission");
	}
	// Retire the bridge through the room's own Moderation surface. The IRC
	// gateway remains the authority, but its holder should not have to leave the
	// room context to exercise the exact bridge capability already held.
	await tab.click("#convcardModerationTab");
	await tab.click('button:has-text("Unbridge from IRC")');
	await tab.click("#convcardUnbridgeConfirm");
	await tab.waitForSelector("#convcardModerationTab", { state: "detached", timeout: 10_000 })
		.catch(() => fail("room-level unbridge did not retire its moderation operation"));
	await tab.click("#convcardClose");
	await tab.waitForSelector("#convcardTitle", { state: "detached" });
	const reopenedRow = namedRoomRow(tab, "deadnet/#nowhere");
	await reopenedRow.hover();
	await reopenedRow.locator(".room-leave").click();
	await reopenedRow.waitFor({ state: "detached", timeout: 10_000 });
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	await tab.click("#opsBtn");
	await tab.waitForFunction(
		() => document.querySelector('#ircBridgedList .entry[data-room="deadnet/#nowhere"]') === null,
		undefined,
		{ timeout: 10_000 },
	).catch(() => fail("room-level unbridge did not retire the gateway inventory row"));
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	await tab.click("#settingsTab");
	await tab.waitForSelector("#settingsPanel", { state: "attached" });
	await removeCapability(tab, "#opsIrcToggle");
}
