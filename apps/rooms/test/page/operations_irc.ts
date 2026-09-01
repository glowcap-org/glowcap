// The IRC gateway scene of the Operations proof, end to end at the UI.
//
// Its toggle takes the capability, the pane retains a zero-channel connection,
// then leases a channel from it (a dead endpoint is fine — joining registers
// the room and the connection retries behind it). The bridged room stands in the rail's namespace with an IRC
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
	// A restored active room changes behind this surface during startup. That
	// background selection must not overwrite an explicit Operations address.
	await tab.reload();
	await tab.waitForSelector("#ircConnectionsTitle", { timeout: 60_000 });
	if (!new URL(tab.url()).pathname.endsWith("/ops/irc")) {
		fail(`restoring the active room replaced the IRC Operations deep link with ${tab.url()}`);
	}
	if (await tab.$("#opsNav") !== null) fail("one held capability still drew pane navigation");
	await tab.waitForSelector("#ircConnectionsTitle");
	await tab.fill("#ircNetwork", "deadnet");
	await tab.fill("#ircHost", "127.0.0.1");
	await tab.fill("#ircPort", "1");
	await tab.fill("#ircNick", "proofbot");
	await tab.click("#ircTls");
	await tab.click("#ircOpenNetwork");
	const connection = tab.locator('.irc-connection[data-network="deadnet"]');
	await connection.waitFor({ timeout: 10_000 });
	if (!(await connection.textContent())?.includes("No channels")) {
		fail("an opened IRC connection did not exist independently of a channel");
	}
	await connection.locator(".irc-channel-add input").fill("#nowhere");
	const channelFieldEdge = await connection.locator(".irc-channel-add input").evaluate((input) => {
		const style = getComputedStyle(input);
		return { left: style.borderLeftWidth, shadow: style.boxShadow, background: style.backgroundColor };
	});
	if (channelFieldEdge.left !== "0px" || channelFieldEdge.shadow !== "none") {
		fail(`the fixed channel prefix was divided from its input: ${JSON.stringify(channelFieldEdge)}`);
	}
	await connection.locator('.irc-channel-add button:has-text("Join")').click();
	await connection.locator('.irc-channel-list li:has-text("#nowhere")').waitFor({ timeout: 10_000 });
	await connection.locator('.said:has-text("Connection refused")').waitFor({ timeout: 10_000 })
		.catch(() => fail("the connection card did not surface its IRC registration failure"));
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
	await connection.locator('.irc-channel-list li:has-text("#nowhere")').waitFor({ timeout: 10_000 });
	// The row's own door: Open enters the room and stands the reader in it.
	await connection.locator('.irc-channel-list li:has-text("#nowhere") button:has-text("Open room")').click();
	await tab.waitForFunction(() => decodeURIComponent(location.pathname) === "/room/deadnet/#nowhere", undefined, {
		timeout: 10_000,
	});
	await namedRoomRow(tab, "deadnet/#nowhere", true).waitFor({ timeout: 10_000 })
		.catch(() => fail("Open on the bridged row did not stand the reader in the room"));
	await tab.click("#roomAbout");
	const about = (await tab.textContent("#convcardAboutPanel")) ?? "";
	if (!about.includes("Bridged via 127.0.0.1:1")) {
		fail(`the room About facts omitted its IRC endpoint: ${JSON.stringify(about)}`);
	}
	if (await tab.getAttribute("#convcardTabs", "data-count") !== "4") {
		fail("the bridged room did not expose its four real detail choices");
	}
	await tab.click("#convcardCapabilitiesTab");
	if (await tab.locator("#convcardManagerTake").count() !== 0) {
		fail("the IRC bridge exposed a native room-manager form it cannot satisfy");
	}
	const bridgeAuthority = (await tab.locator('[aria-label="Room capabilities"]').textContent()) ?? "";
	if (!bridgeAuthority.includes("IRC bridge owns entry and moderator authority")) {
		fail(`the bridge capability surface did not name its source authority: ${bridgeAuthority}`);
	}
	await tab.getByRole("button", { name: "Save entry link" }).click();
	await tab.waitForSelector("#convcardRoomLink");
	await tab.click("#convcardAboutTab");
	const priorViewport = tab.viewportSize();
	await tab.setViewportSize({ width: 390, height: 720 });
	const phoneTabs = await tab.evaluate(() => {
		const tabs = [...document.querySelectorAll<HTMLElement>("#convcardTabs .tab")];
		return {
			rows: new Set(tabs.map((item) => Math.round(item.getBoundingClientRect().top))).size,
			labels: tabs.map((item) => ({
				text: item.textContent?.trim() ?? "",
				left: Number.parseFloat(getComputedStyle(item).paddingLeft),
				right: Number.parseFloat(getComputedStyle(item).paddingRight),
			})),
		};
	});
	if (
		phoneTabs.rows !== 2 ||
		phoneTabs.labels.some((item) =>
			(item.text === "Capabilities" || item.text === "Moderation") && (item.left < 10 || item.right < 10)
		)
	) fail(`the phone-sized room tabs were squeezed instead of composed as two rows: ${JSON.stringify(phoneTabs)}`);
	if (priorViewport != null) await tab.setViewportSize(priorViewport);
	await tab.click("#convcardIrcTab");
	await tab.waitForSelector("#convcardBridgeState");
	const ircState = (await tab.textContent("#convcardBridgeState")) ?? "";
	if (!ircState.includes("deadnet") || !ircState.includes("127.0.0.1:1")) {
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
	if (
		!ownBridgeSaid.includes("FAILED") || !ownBridgeSaid.includes("deadnet") ||
		!ownBridgeSaid.includes("link failed")
	) {
		fail(`the failed IRC member row did not say its relationship: ${JSON.stringify(ownBridgeSaid)}`);
	}
	await ownBridge.getByRole("button", { name: "Manage your IRC identity" }).click();
	await tab.waitForSelector("#convcardIrcPanel").catch(() =>
		fail("the reader's member row did not open the IRC identity panel")
	);
	if ((await tab.getAttribute("#convcardIrcTab", "aria-selected")) !== "true") {
		fail("the member row opened room details somewhere other than IRC identity");
	}
	// Pressing a declared action drives the whole rendered form: the button
	// submits its scope and action through the session's bridge-form command to
	// the live room, and the seat's reported state moves. Disconnecting from a
	// failed IRC link is the one transition this fixture can prove, because the
	// bridge's own IRC reach is unavailable to it.
	await tab.click("#convcardBridgeAct-disconnect");
	await tab.waitForFunction(() => document.getElementById("convcardBridgeState")?.textContent?.includes("Rooms only"))
		.catch(() => fail("disconnecting IRC did not leave the membership visibly Rooms-only"));
	// The bridge declares its form for the state it is in: over cleartext it
	// refuses a SASL password, so the registered-account half is absent rather
	// than offered and refused after the fact. The nick field it does offer is
	// present and editable.
	if (await tab.locator("#convcardBridge-registered").count() !== 0) {
		fail("a cleartext bridge offered a registered-account login it would refuse");
	}
	await tab.waitForSelector("#convcardBridge-nick").catch(() =>
		fail("the declared cleartext identity form drew no nick field")
	);
	// Retire the bridge through the room's own Moderation surface. The IRC
	// gateway remains the authority, but its holder should not have to leave the
	// room context to exercise the exact bridge capability already held.
	await tab.click("#convcardModerationTab");
	await tab.click('button:has-text("Unbridge from IRC")');
	await tab.click("#convcardUnbridgeConfirm");
	await tab.waitForSelector("#convcardModerationTab", { state: "detached", timeout: 10_000 })
		.catch(() => fail("room-level unbridge did not retire its moderation operation"));
	await tab.waitForFunction(
		() => {
			const input = document.querySelector<HTMLTextAreaElement>("#line");
			return input?.disabled === true &&
				document.getElementById("composerAvailability")?.textContent?.includes("parted");
		},
		undefined,
		{ timeout: 10_000 },
	).catch(() => fail("a parted IRC bridge left its retired room composer writable"));
	await tab.click("#convcardClose");
	await tab.waitForSelector("#convcardTitle", { state: "detached" });
	const reopenedRow = namedRoomRow(tab, "deadnet/#nowhere");
	await reopenedRow.hover();
	await reopenedRow.locator(".room-leave").click();
	await reopenedRow.waitFor({ state: "detached", timeout: 10_000 });
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	await tab.click("#opsBtn");
	await connection.locator('.irc-channel-list li:has-text("#nowhere")').waitFor({
		state: "detached",
		timeout: 10_000,
	})
		.catch(() => fail("room-level unbridge did not retire the gateway channel lease"));
	if (!(await connection.textContent())?.includes("No channels")) {
		fail("parting the last channel also discarded its retained connection");
	}
	await connection.getByRole("button", { name: "Close connection…" }).click();
	await connection.getByRole("button", { name: "Close connection", exact: true }).click();
	await connection.waitFor({ state: "detached", timeout: 10_000 })
		.catch(() => fail("the operator could not close a zero-channel IRC connection"));

	// A fresh connection and channel are a fresh publication generation. The
	// retired room above must not poison this one merely because its name is the
	// same.
	await tab.fill("#ircNetwork", "deadnet");
	await tab.fill("#ircHost", "127.0.0.1");
	await tab.fill("#ircPort", "1");
	await tab.fill("#ircNick", "proofbot");
	await tab.click("#ircTls");
	await tab.click("#ircOpenNetwork");
	await connection.waitFor({ timeout: 10_000 });
	await connection.locator(".irc-channel-add input").fill("#nowhere");
	await connection.locator('.irc-channel-add button:has-text("Join")').click();
	const replacement = connection.locator('.irc-channel-list li:has-text("#nowhere")');
	await replacement.waitFor({ timeout: 10_000 });
	await replacement.getByRole("button", { name: "Part…" }).click();
	await replacement.getByRole("button", { name: "Part channel" }).waitFor();
	await replacement.getByRole("button", { name: "Keep channel" }).click();
	await replacement.getByRole("button", { name: "Open room" }).click();
	await tab.waitForFunction(
		() => document.querySelector<HTMLTextAreaElement>("#line")?.disabled === false,
		undefined,
		{
			timeout: 10_000,
		},
	).catch(() => fail("a recreated IRC bridge inherited the retired room's disabled membership"));
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	await tab.click("#opsBtn");
	await connection.getByRole("button", { name: "Close connection…" }).click();
	await connection.getByRole("button", { name: "Close connection", exact: true }).click();
	await connection.waitFor({ state: "detached", timeout: 10_000 });
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	await tab.click("#holdingsTab");
	await tab.waitForSelector("#holdingsPanel", { state: "attached" });
	await removeCapability(tab, "#opsIrcToggle");
}
