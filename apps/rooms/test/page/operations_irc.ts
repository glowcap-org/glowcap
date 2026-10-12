// The IRC gateway scene of the Operations proof, end to end at the UI.
//
// Its toggle takes the capability, the pane retains a zero-channel connection,
// then leases a channel from it (a dead endpoint is fine, joining registers
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
	await tab.waitForSelector("#gatewayConnectionsTitle", { timeout: 60_000 });
	if (!new URL(tab.url()).pathname.endsWith("/ops/irc")) {
		fail(`restoring the active room replaced the IRC Operations deep link with ${tab.url()}`);
	}
	if (await tab.$("#opsNav") !== null) fail("one held capability still drew pane navigation");
	await tab.waitForSelector("#gatewayConnectionsTitle");
	await tab.fill("#gatewayConnection-name", "deadnet");
	await tab.fill("#gatewayConnection-host", "127.0.0.1");
	await tab.fill("#gatewayConnection-port", "1");
	await tab.fill("#gatewayConnection-nick", "proofbot");
	await tab.fill("#gatewayConnection-realname", "Rooms proof bridge bot; admin: fixture-admin");
	await tab.click("#gatewayConnection-tls");
	await tab.click("#gatewayConnectionAct-open");
	const connection = tab.locator('.irc-connection[data-network="deadnet"]');
	await connection.waitFor({ timeout: 10_000 });
	// The TLS toggle is an answer, not only disclosure: turning it off must reach
	// the gateway, so this cleartext connection reports itself cleartext.
	if (!(await connection.textContent())?.includes("cleartext")) {
		fail("the connection did not carry the TLS toggle's off state to the gateway");
	}
	if (!(await connection.textContent())?.includes("Rooms proof bridge bot; admin: fixture-admin")) {
		fail("the connection did not retain the public bot real name");
	}
	if (!(await connection.textContent())?.includes("No channels")) {
		fail("an opened IRC connection did not exist independently of a channel");
	}
	await connection.locator('.irc-channel-add input[type="text"]').fill("nowhere");
	await connection.getByLabel("The channel's operators permit this bridge").check();
	await connection.locator('.irc-channel-add button:has-text("Join")').click();
	await connection.locator('.irc-channel-list li:has-text("#nowhere")').waitFor({ timeout: 10_000 });
	await connection.locator(':scope > .said:has-text("Connection refused")').waitFor({ timeout: 10_000 })
		.catch(async () =>
			fail(`the connection card did not surface its IRC registration failure: ${await connection.textContent()}`)
		);
	// Entered through the ordinary rail field, the bridged room stands as a
	// room with an IRC badge. Its second line remains directory context, the
	// same as every other room on that directory.
	await tab.click("#newRoomBtn");
	// Operations has no selected conversation. Its rail names the first held
	// directory, which can be foreign; explicitly choose the gateway's home.
	await tab.click("#newRoomElsewhere");
	await tab.waitForSelector("#locator");
	await tab.fill("#locator", "");
	await tab.fill("#newRoomInput", "deadnet");
	await tab.waitForSelector('#newRoomOffers .complete-row:has-text("deadnet/#nowhere")', { timeout: 10_000 })
		.catch(() => fail("the rail field does not offer the bridged channel's name"));
	await tab.click('#newRoomOffers .complete-row:has-text("deadnet/#nowhere")');
	await tab.press("#newRoomInput", "Enter");
	const bridgedRow = namedRoomRow(tab, "deadnet/#nowhere");
	// The rail chip wears the bridge's own badge word, which for this IRC
	// fixture is "IRC"; a second bridge would put its own badge here.
	if ((await bridgedRow.locator(".bridge-chip").textContent()) !== "IRC") {
		fail("the bridged room's primary rail line carries no bridge badge");
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
	await tab.waitForSelector('#convcardTabs[data-count="4"]', { timeout: 10_000 }).catch(async () => {
		const tabs = await tab.locator("#convcardTabs .tab").allTextContents();
		const members = (await tab.locator("#members").textContent()) ?? "";
		fail(
			`the bridged room did not reconcile its four real detail choices: tabs=${JSON.stringify(tabs)} ` +
				`members=${JSON.stringify(members)}`,
		);
	});
	await tab.click("#convcardCapabilitiesTab");
	if (await tab.locator("#convcardManagerTake").count() !== 0) {
		fail("the IRC bridge exposed a room-manager form it cannot satisfy");
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
	// The identity tab wears the bridge's own badge, not a hardcoded "IRC", so
	// it is reached by its stable dom id rather than by a label.
	await tab.click("#convcardBridgeTab");
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
	// The badge the bridge declares labels this control, so it reads as the
	// service rather than as a hardcoded "IRC".
	await ownBridge.getByRole("button", { name: "Manage your IRC identity" }).click();
	await tab.waitForSelector("#convcardBridgePanel").catch(() =>
		fail("the reader's member row did not open the bridge identity panel")
	);
	if ((await tab.getAttribute("#convcardBridgeTab", "aria-selected")) !== "true") {
		fail("the member row opened room details somewhere other than the bridge identity tab");
	}
	// Pressing a declared action drives the whole rendered form: the button
	// submits its scope and action through the session's bridge-form command to
	// the live room, and the seat's reported state moves. Disconnecting from a
	// failed IRC link is the one transition this fixture can prove, because the
	// bridge's own IRC reach is unavailable to it. Disconnect takes a member off
	// IRC, so the bridge marks it a confirmed act: the press opens a second step.
	await tab.click("#convcardBridgeAct-disconnect");
	await tab.locator("#convcardBridgeConfirm-disconnect").waitFor({ state: "visible", timeout: 10_000 })
		.catch(() => fail("the destructive disconnect acted without a confirmation step"));
	await tab.click("#convcardBridgeConfirm-disconnect");
	await tab.waitForFunction(() => document.getElementById("convcardBridgeState")?.textContent?.includes("Rooms only"))
		.catch(() => fail("disconnecting IRC did not leave the membership visibly Rooms-only"));
	// The bridge declares its form for the state it is in: over cleartext it
	// refuses a SASL password, so the registered-account half is absent rather
	// than offered and refused after the fact. It says why, rather than leaving a
	// reader hunting for a login that was silently withheld. The nick field it
	// does offer is present and editable.
	if (await tab.locator("#convcardBridge-registered").count() !== 0) {
		fail("a cleartext bridge offered a registered-account login it would refuse");
	}
	const cleartextState = (await tab.textContent("#convcardBridgeState")) ?? "";
	if (!cleartextState.includes("needs an encrypted connection")) {
		fail(`the cleartext identity form did not explain the missing login: ${JSON.stringify(cleartextState)}`);
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
	).catch(async () => {
		const composer = await tab.locator("#line").evaluate((input: HTMLTextAreaElement) => ({
			disabled: input.disabled,
			value: input.value,
		}));
		const availability = (await tab.locator("#composerAvailability").textContent()) ?? "";
		const row = await namedRoomRow(tab, "deadnet/#nowhere", true).getAttribute("class");
		fail(
			`a parted IRC bridge left its retired room composer writable: composer=${JSON.stringify(composer)} ` +
				`availability=${JSON.stringify(availability)} row=${JSON.stringify(row)}`,
		);
	});
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
	await tab.fill("#gatewayConnection-name", "deadnet");
	await tab.fill("#gatewayConnection-host", "127.0.0.1");
	await tab.fill("#gatewayConnection-port", "1");
	await tab.fill("#gatewayConnection-nick", "proofbot");
	await tab.fill("#gatewayConnection-realname", "Rooms proof bridge bot; admin: fixture-admin");
	// This time leave TLS on. A checked TLS box has to reach the gateway, or a
	// registered account is refused and its per-member login never appears, the
	// exact break a reader hit with the box selected.
	await tab.click("#gatewayConnectionAct-open");
	await connection.waitFor({ timeout: 10_000 });
	if (!(await connection.textContent())?.includes("TLS")) {
		fail("a TLS connection reported itself cleartext; the TLS toggle's on state was lost");
	}
	await connection.locator('.irc-channel-add input[type="text"]').fill("#nowhere");
	await connection.getByLabel("The channel's operators permit this bridge").check();
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
	// Over TLS the per-member registered-account login is offered: the half a
	// cleartext connection withholds and explains.
	const ownTls = tab.locator('#members li[data-network="rooms-failed"]');
	await ownTls.getByRole("button", { name: "Manage your IRC identity" }).click();
	await tab.waitForSelector("#convcardBridge-registered", { timeout: 10_000 })
		.catch(() => fail("a TLS connection did not offer the per-member registered-account login"));
	await tab.click("#convcardClose");
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
