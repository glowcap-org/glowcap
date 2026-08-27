// The Operations flow: capabilities the reader can hold over the server.
//
// The saved capability set is the authority: a toggle opens its value modal,
// text mode edits the same bundle, and saving reconciles live possession.
// While anything is held, an Operations control leads the Settings head's
// toggle row from the left and stands the reader on the /ops page: one
// address per held capability, a pane nav from two onward, never a take form
// inside a held pane — and an address arrived at cold gates on possession.
// The page keeps the shell: the rail stays, Settings opens over it, and the
// rail's active row is the way back. The listeners
// pane then has to tell the truth twice over: the listener serving this very
// page wears a marker and a disabled switch instead of a control that could
// succeed, and a refused `up` comes back as the server's own sentence in the
// row that asked. Flipping a toggle off drops that capability, pane and
// swiss with it. The Peering scene lives in its own browser module: it proves
// the source room, session-scoped foreign listing, disconnect cleanup, and
// exact revoke as one lifecycle.

import type { Page } from "playwright";
import { Buffer } from "node:buffer";
import { fail } from "./harness.ts";
import { verifyCompleteOperationsNav } from "./operations_nav.ts";
import { runOperatorScene } from "./operations_operator.ts";
import { runIrcScene } from "./operations_irc.ts";
import { addCapability, removeCapability, saveCapabilitySet, takeCapability } from "./capability_set.ts";
import { runPeeringScene } from "./operations_peering.ts";
import { namedDirectRow, namedRoomRow } from "../support/conversation_row.ts";

export async function run(tab: Page, statePath: string, foreignLocator: string): Promise<void> {
	const listenersSwiss = (await Deno.readTextFile(`${statePath}/admin-listeners`)).trim();
	const diagnosticsSwiss = (await Deno.readTextFile(`${statePath}/diagnostics`)).trim();
	const peeringSwiss = (await Deno.readTextFile(`${statePath}/peering`)).trim();
	const vizSwiss = (await Deno.readTextFile(`${statePath}/viz`)).trim();
	const ircSwiss = (await Deno.readTextFile(`${statePath}/irc`)).trim();
	const operatorSwiss = (await Deno.readTextFile(`${statePath}/operator`)).trim();
	if (
		listenersSwiss === "" || diagnosticsSwiss === "" || peeringSwiss === "" || vizSwiss === "" ||
		ircSwiss === "" || operatorSwiss === ""
	) {
		fail("the room server did not persist its operations swiss numbers");
	}

	// Nothing held yet: Settings opens without an Operations control.
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	if (await tab.$("#opsBtn") !== null) {
		fail("the Operations control was drawn before any capability was held");
	}
	await tab.click("#settingsTab");
	await tab.waitForSelector("#settingsPanel", { state: "attached" });

	// The namespace is real: /ops can be arrived at cold. With nothing held
	// it is the asks; a pane address it cannot name says so where it stands,
	// a 404 in the page's own voice; and a gate's take returns to the page,
	// never to Settings.
	await tab.click("#settingsClose");
	await tab.waitForSelector("#settingsTitle", { state: "hidden" });
	await tab.goto(new URL("/ops/nope", tab.url()).href);
	await tab.waitForSelector("#opsNotFound");
	if (!(await tab.url()).endsWith("/ops/nope")) {
		fail("an unknown pane address was silently rewritten instead of answered");
	}
	// The rail's lockup is a link: from anywhere in /ops it stands the reader
	// back at the front page.
	await tab.click(".wordmark-link");
	await tab.waitForFunction(() => location.pathname === "/");
	await tab.goto(new URL("/ops/peering", tab.url()).href);
	await tab.waitForSelector("#opsGate-peering");
	await tab.click("#opsGateTake-peering");
	await tab.waitForSelector("#settingsTitle");
	await tab.waitForSelector("#settingsPanel", { state: "visible" });
	await tab.click("#settingsClose");
	await tab.waitForSelector("#settingsTitle", { state: "hidden" });
	// The shell stands under the namespace: the rail and its Settings control
	// are right here, so nothing has to be left to reach them.
	if (await tab.$("#roomList") === null) fail("the operations surface dropped the rail");
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	await tab.click("#settingsTab");
	await tab.waitForSelector("#settingsPanel", { state: "attached" });

	await runIrcScene(tab, ircSwiss);

	await runOperatorScene(tab, operatorSwiss);

	// Flipping a toggle on asks, it does not grant: the value modal opens, and
	// dismissing it leaves the toggle off and the control absent.
	const listenerRowHeight = await tab.locator("#opsListenersToggle").evaluate((toggle) =>
		(toggle.closest(".capability-set-row") as HTMLElement | null)?.offsetHeight ?? 0
	);
	await tab.click("#opsListenersToggle");
	await tab.waitForSelector("#capabilityValueTitle");
	await tab.click("#capabilityValueClose");
	await tab.waitForSelector("#settingsPanel", { state: "attached" });
	const afterCancel = await tab.evaluate(() => ({
		checked: document.getElementById("opsListenersToggle")?.getAttribute("aria-checked"),
		ops: document.getElementById("opsBtn") !== null,
	}));
	if (afterCancel.checked !== "false" || afterCancel.ops) {
		fail(`a dismissed take still granted something: ${JSON.stringify(afterCancel)}`);
	}
	await addCapability(tab, "#opsListenersToggle", "discarded-listeners-swiss");
	const enabledListenerRowHeight = await tab.locator("#opsListenersToggle").evaluate((toggle) =>
		(toggle.closest(".capability-set-row") as HTMLElement | null)?.offsetHeight ?? 0
	);
	if (listenerRowHeight !== enabledListenerRowHeight) {
		fail(`the capability row changed height from ${listenerRowHeight} to ${enabledListenerRowHeight}`);
	}
	if (!await tab.isEnabled("#opsCapabilitySetSave") || !await tab.isEnabled("#opsCapabilitySetDiscard")) {
		fail("editing the capability set did not enable save and discard");
	}
	const actionOrder = await tab.evaluate(() => {
		const discard = document.getElementById("opsCapabilitySetDiscard")?.getBoundingClientRect();
		const save = document.getElementById("opsCapabilitySetSave")?.getBoundingClientRect();
		return discard != null && save != null && discard.left < save.left && Math.abs(discard.top - save.top) < 2;
	});
	if (!actionOrder) fail("the capability-set footer did not separate discard on the left from save on the right");
	await tab.click("#opsCapabilitySetDiscard");
	if (
		await tab.getAttribute("#opsListenersToggle", "aria-checked") !== "false" ||
		await tab.isEnabled("#opsCapabilitySetSave") || await tab.isEnabled("#opsCapabilitySetDiscard")
	) {
		fail("discarding the capability draft did not restore its committed baseline");
	}

	// Stale values are separate, visible failures rather than one neutral line
	// of protocol text. Each names the capability and the current server token
	// that repairs it.
	await addCapability(tab, "#opsListenersToggle", "stale-listeners-swiss");
	await addCapability(tab, "#opsDiagnosticsToggle", "stale-diagnostics-swiss");
	await tab.click("#opsCapabilitySetSave");
	const staleFailures = tab.locator('.capability-set-errors .said[data-kind="failure"]');
	await staleFailures.first().waitFor({ timeout: 15_000 });
	if (await staleFailures.count() !== 2) fail("two stale capabilities did not produce two failure rows");
	if (await tab.locator("#opsCapabilitySetSaved").count() !== 0) {
		fail("a partially refused capability set reported successful saving");
	}
	if (
		!await tab.isEnabled("#opsCapabilitySetSave") ||
		await tab.textContent("#opsCapabilitySetSave") !== "Retry"
	) {
		fail("a partially refused capability set offered no explicit retry");
	}
	const staleText = await staleFailures.allTextContents();
	if (
		!staleText.some((text) => text.includes("Administer listeners:") && text.includes("ROOMS-ADMIN-LISTENERS")) ||
		!staleText.some((text) => text.includes("Inspect this directory:") && text.includes("ROOMS-DIAGNOSTICS")) ||
		staleText.some((text) => !text.includes("does not recognize that swiss number"))
	) {
		fail(`stale capability guidance was incomplete: ${JSON.stringify(staleText)}`);
	}
	await tab.click("#opsListenersToggle");
	await tab.click("#opsDiagnosticsToggle");
	await saveCapabilitySet(tab);

	// Ask again and save it into the session capability bundle. The toggle
	// lands on, the live capability arrives, and reload can redeem it again.
	await takeCapability(tab, "#opsListenersToggle", listenersSwiss);
	await tab.waitForSelector("#opsBtn");
	const granted = await tab.evaluate(() => ({
		checked: document.getElementById("opsListenersToggle")?.getAttribute("aria-checked"),
		leads: (() => {
			const ops = document.getElementById("opsBtn")?.getBoundingClientRect();
			const theme = document.getElementById("themeToggle")?.getBoundingClientRect();
			return ops !== undefined && theme !== undefined ? ops.left < theme.left : null;
		})(),
	}));
	if (granted.checked !== "true") fail("a successful take did not land the toggle on");
	if (granted.leads !== true) fail("the Operations control does not lead the toggle row from the left");

	// One held capability: the page is that pane alone — no pane navigation, no take
	// form, one row per transport seat the server itself listed, each with the
	// owning package's description. The serving tcp listener is up with a
	// disabled switch and the marker, its locator there to copy; a seat the
	// server already knows cannot come up (onion, with no Tor) is disabled
	// with the standing sentence; the rest are down with live switches.
	await tab.click("#opsBtn");
	await tab.waitForSelector("#operationsTitle");
	// The control navigates: Operations is its own screen at its own address,
	// and one held capability stands directly on that pane's address.
	await tab.waitForFunction(() => location.pathname === "/ops/admin-listeners");
	if (await tab.$("dialog[open]") !== null) fail("the Operations page still opened under a dialog");
	if (await tab.$('#roomList .room-open[aria-current="page"]') !== null) {
		fail("standing on operations still marks a room selected in the rail");
	}
	if (await tab.$("#opsNav") !== null) fail("one held capability still drew pane navigation");
	if (await tab.$("#capabilityValueSwiss") !== null) fail("a held pane still carried the bundle value editor");
	await tab.waitForSelector("#listenersList");
	const shown = await tab.evaluate(() => {
		const row = (transport: string) => {
			const li = document.querySelector(`#listenersList .entry[data-transport="${transport}"]`);
			const swtch = document.getElementById(`listenerSwitch-${transport}`) as HTMLButtonElement | null;
			return {
				up: li?.getAttribute("data-up"),
				serving: li?.querySelector('[data-serving="true"]') !== null,
				checked: swtch?.getAttribute("aria-checked"),
				disabled: swtch?.disabled,
				locator: li?.querySelector(".copy-field-text")?.textContent ?? "",
				said: li?.textContent ?? "",
			};
		};
		return {
			count: document.querySelectorAll("#listenersList .entry").length,
			described: [...document.querySelectorAll("#listenersList .entry .hint")]
				.every((hint) => (hint.textContent ?? "").length > 0),
			tcp: row("tcp"),
			iroh: row("iroh"),
			onion: row("onion"),
			relay: row("keyed-relay"),
		};
	});
	if (shown.count < 5) fail(`the listeners pane did not draw the server's seat list: ${JSON.stringify(shown)}`);
	if (!shown.described) fail("a listener seat arrived without its package's description");
	if (shown.tcp.up !== "true" || !shown.tcp.serving || shown.tcp.checked !== "true" || shown.tcp.disabled !== true) {
		fail(`the serving tcp row is not up, marked, and unswitchable: ${JSON.stringify(shown.tcp)}`);
	}
	if (!/:\d+/.test(shown.tcp.locator)) {
		fail(`the serving listener's row does not carry its copyable locator: ${JSON.stringify(shown.tcp)}`);
	}
	if (shown.iroh.up !== "false" || shown.iroh.checked !== "false" || shown.iroh.disabled !== false) {
		fail(`the iroh row is not a live switch sitting off: ${JSON.stringify(shown.iroh)}`);
	}
	// The onion seat's standing answer: no Tor reached this server, the row
	// says so, and its switch is the disabled affordance rather than a press
	// that could only refuse.
	if (shown.onion.disabled !== true || !/running Tor/.test(shown.onion.said)) {
		fail(`the onion seat does not stand disabled with its reason: ${JSON.stringify(shown.onion)}`);
	}

	// The switches are real controls, and a refusal lands in the row that
	// asked: a keyed-relay up pointed at a dead relay comes back as the
	// server's sentence, in that row, with the switch still off.
	// Each down seat draws one field per knob the server listed; the tcp
	// family's three are there to fill.
	for (const knob of ["bind", "port", "advertise"]) {
		if (await tab.$(`#listenerOpt-keyed-tcp-${knob}`) === null) {
			fail(`the keyed-tcp seat is missing its ${knob} field`);
		}
	}
	await tab.fill("#listenerOpt-keyed-relay-relay", "ws://127.0.0.1:9/");
	await tab.click("#listenerSwitch-keyed-relay");
	await tab.waitForSelector("#listenerWhy-keyed-relay");
	const said = await tab.textContent("#listenerWhy-keyed-relay");
	if (said === null || !/relay/.test(said)) {
		fail(`the dead-relay refusal did not surface the typed sentence: "${said}"`);
	}
	if (await tab.getAttribute("#listenerSwitch-keyed-relay", "aria-checked") !== "false") {
		fail("a refused up still landed the keyed-relay switch on");
	}

	// Pointed back at this page's own relay — the field's prefilled default —
	// the same switch brings a real rendezvous listener up, its locator
	// naming the relay route, and takes it down again.
	const ownRelay = await tab.evaluate(() =>
		`${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/relay`
	);
	await tab.fill("#listenerOpt-keyed-relay-relay", ownRelay);
	await tab.click("#listenerSwitch-keyed-relay");
	await tab.waitForFunction(
		() =>
			document.getElementById("listenerSwitch-keyed-relay")?.getAttribute("aria-checked") ===
				"true",
		undefined,
		{ timeout: 15_000 },
	).catch(() => fail("the keyed-relay listener did not come up on this page's own relay"));
	const relayLocator = await tab.evaluate(() =>
		document.querySelector('#listenersList .entry[data-transport="keyed-relay"] .copy-field-text')
			?.textContent ?? ""
	);
	if (!relayLocator.includes("rendezvous-relay")) {
		fail(`the keyed-relay locator does not carry its relay route: "${relayLocator}"`);
	}
	await tab.click("#listenerSwitch-keyed-relay");
	await tab.waitForFunction(
		() =>
			document.getElementById("listenerSwitch-keyed-relay")?.getAttribute("aria-checked") ===
				"false",
		undefined,
		{ timeout: 15_000 },
	).catch(() => fail("the keyed-relay listener did not come down"));

	// Take diagnostics too: the page grows its pane navigation, and the diagnostics
	// pane arrives holding its table.
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	await tab.click("#settingsTab");
	await tab.waitForSelector("#settingsPanel", { state: "attached" });
	await takeCapability(tab, "#opsDiagnosticsToggle", diagnosticsSwiss);
	await tab.waitForSelector("#settingsPanel", { state: "attached" });
	await tab.click("#opsBtn");
	await tab.waitForSelector("#opsNav");
	await tab.click("#directoryOpsLink");
	await tab.waitForFunction(() => location.pathname === "/ops/directory");
	await tab.waitForFunction(
		() => {
			const cells = [...document.querySelectorAll("#directoryOpsPanel td")]
				.map((cell) => cell.textContent ?? "");
			return cells.includes("directory");
		},
		undefined,
		{ timeout: 10_000 },
	).catch(() => fail("the diagnostics pane did not list the directory"));
	// The page's own trouble journal stands beside the directory's holdings,
	// present even when it has nothing to say.
	await tab.waitForSelector("#pageTrouble");
	await tab.click("#listenersOpsLink");
	await tab.waitForSelector("#listenersList");

	// The protocol visualizer. Its swiss is presented to
	// the live timeline endpoint rather than fetched on the directory session,
	// and taking it is what arms this tab's own trace publishing. With three
	// held, the navigation counts three.
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	await tab.click("#settingsTab");
	await tab.waitForSelector("#settingsPanel", { state: "attached" });
	await takeCapability(tab, "#opsVizToggle", vizSwiss);
	await tab.waitForFunction(
		() => document.getElementById("opsVizToggle")?.getAttribute("aria-checked") === "true",
		undefined,
		{ timeout: 15_000 },
	).catch(() => fail("taking the viz capability did not land its toggle on"));
	await tab.click("#opsBtn");
	await tab.waitForSelector("#opsNav");
	const three = await tab.getAttribute("#opsNav", "data-count");
	if (three !== "3") fail(`three held capabilities drew a pane nav of ${three}`);
	await tab.click("#vizOpsLink");
	await tab.waitForSelector("#vizPublishing");
	const publishing = await tab.evaluate(() => ({
		connected: document.getElementById("vizPublishing")?.getAttribute("data-connected"),
		endpoint: document.querySelector("#vizOpsPanel code")?.textContent ?? "",
	}));
	if (publishing.connected !== "true") {
		fail(`the held viz capability is not publishing: ${JSON.stringify(publishing)}`);
	}
	if (!publishing.endpoint.startsWith("ws")) {
		fail(`the viz pane does not name its endpoint: ${JSON.stringify(publishing)}`);
	}

	// The endpoint override moved here from Advanced, and its save arms only
	// on a change: typing enables it, restoring the saved value disables it
	// again. Saving itself reloads the window, so this scene leaves it alone.
	const saveDisabled = () =>
		tab.evaluate(() => (document.getElementById("vizUrlSave") as HTMLButtonElement | null)?.disabled);
	if (await saveDisabled() !== true) fail("the viz endpoint save was armed with nothing changed");
	await tab.fill("#vizUrl", "ws://127.0.0.1:1/");
	if (await saveDisabled() !== false) fail("typing a viz endpoint did not arm its save");
	await tab.fill("#vizUrl", "");
	if (await saveDisabled() !== true) fail("restoring the viz endpoint did not disarm its save");

	// Dropping the viz capability erases the swiss it was asked to remember,
	// in the same breath as the toggle falling off.
	const rememberedCaps = () =>
		tab.evaluate(() => {
			const state = JSON.parse(localStorage.getItem("rooms.workspace-state") ?? "null");
			const operations = state?.session?.capabilities?.operations;
			return Array.isArray(operations) ? operations.map((row: { capability: string }) => row.capability) : [];
		});
	if (!(await rememberedCaps()).includes("viz")) fail("the viz take with Remember kept no swiss");
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	await tab.click("#settingsTab");
	await tab.waitForSelector("#settingsPanel", { state: "attached" });
	await removeCapability(tab, "#opsVizToggle");
	if ((await rememberedCaps()).includes("viz")) fail("dropping the viz capability kept its secret");

	// Dropping a capability takes its pane with it: with only listeners
	// held, the page has no pane navigation and nothing of the diagnostics left.
	// Removing diagnostics from the one bundle releases the live capability and
	// its durable recovery word together.
	await removeCapability(tab, "#opsDiagnosticsToggle");
	await tab.click("#opsBtn");
	await tab.waitForSelector("#operationsTitle");
	if (await tab.$("#opsNav") !== null) fail("one remaining capability still drew pane navigation");
	if (await tab.$("#directoryOpsPanel") !== null) fail("a dropped capability's pane still answered");
	await tab.waitForSelector("#listenersList");
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	await tab.click("#settingsTab");
	await tab.waitForSelector("#settingsPanel", { state: "attached" });
	await tab.click("#settingsClose");
	await tab.waitForSelector("#settingsTitle", { state: "hidden" });

	// The workspace document is application state, not only remembered operation
	// secrets. Seed independently addressed room and direct histories and drafts,
	// then return to this explicit operations address before reloading.
	await tab.click("#newRoomBtn");
	await tab.fill("#newRoomInput", "workspace-persistence");
	await tab.press("#newRoomInput", "Enter");
	await namedRoomRow(tab, "workspace-persistence", true).waitFor({ timeout: 10_000 });
	await tab.click("#roomAbout");
	await tab.click("#convcardCapabilitiesTab");
	if (await tab.locator("#convcardSteward").count() === 0) {
		await tab.click("#convcardStewardClaim");
		await tab.waitForSelector("#convcardSteward", { timeout: 10_000 });
	}
	await tab.click("#convcardClose");
	await tab.fill("#line", "workspace room history proof");
	await tab.press("#line", "Enter");
	await tab.waitForSelector('.bubble:has-text("workspace room history proof")');
	await tab.fill("#line", "workspace room draft proof");
	await tab.click("#railFilter");
	const clearFilter = tab.locator("#railFilterClear");
	if (await clearFilter.isEnabled()) await clearFilter.click();
	await tab.click("#railFilter");
	if (await tab.locator("#dmList li:has(.dm-open)").count() === 0) {
		const reachableMember = tab.locator("#members li:has(.dm-btn)").first();
		await reachableMember.locator(".dm-btn").click();
		await tab.waitForSelector("#dmList li:has(.dm-open)");
	}
	const persistedDm = tab.locator("#dmList li:has(.dm-open)").first();
	const persistedDmName = await persistedDm.locator(".rname").textContent();
	if (persistedDmName == null || persistedDmName === "") fail("the workspace proof found no direct conversation");
	await persistedDm.locator(".dm-open").click();
	await tab.fill("#line", "workspace dm history proof");
	await tab.press("#line", "Enter");
	await tab.waitForSelector('.bubble:has-text("workspace dm history proof")');
	await tab.setInputFiles("#filePick", {
		name: "workspace-archive.txt",
		mimeType: "text/plain",
		buffer: Buffer.from("workspace archive bytes"),
	});
	await tab.click("#sendBtn");
	await tab.waitForSelector('.attach-file:has(.name:text-is("workspace-archive.txt"))', { timeout: 20_000 });
	await tab.fill("#line", "workspace dm draft proof");
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	await tab.click("#opsBtn");
	await tab.waitForFunction(() => location.pathname.startsWith("/ops/"));
	const workspaceRows = await tab.evaluate(() => ({
		rooms: [...document.querySelectorAll("#roomList li:not(.dirrow) .rname")].map((node) => node.textContent),
		dms: [...document.querySelectorAll("#dmList li .rname")].map((node) => node.textContent),
	}));

	// A reload keeps only what the reader asked this browser to remember: the
	// listeners swiss auto-redeems on the home session coming up, so its
	// toggle is simply on; diagnostics was removed from the saved set.
	const before = await rememberedCaps();
	if (before.length !== 1) fail(`expected exactly the listeners swiss remembered: ${JSON.stringify(before)}`);
	await tab.reload();
	await tab.waitForSelector("#settingsBtn", { timeout: 30_000 });
	await tab.waitForSelector("#opsPage");
	const restoredRows = await tab.evaluate(() => ({
		rooms: [...document.querySelectorAll("#roomList li:not(.dirrow) .rname")].map((node) => node.textContent),
		dms: [...document.querySelectorAll("#dmList li .rname")].map((node) => node.textContent),
	}));
	if (JSON.stringify(restoredRows) !== JSON.stringify(workspaceRows)) {
		fail(`the workspace reload changed its conversations: ${JSON.stringify({ workspaceRows, restoredRows })}`);
	}
	await namedRoomRow(tab, "workspace-persistence").locator(".room-open").click();
	if (await tab.inputValue("#line") !== "workspace room draft proof") fail("the room draft did not survive reload");
	await tab.waitForSelector('.bubble:has-text("workspace room history proof")', { timeout: 20_000 })
		.catch(() => fail("the member's room history did not survive reload"));
	await tab.click("#roomAbout");
	await tab.click("#convcardCapabilitiesTab");
	await tab.waitForSelector("#convcardSteward", { timeout: 10_000 })
		.catch(() => fail("the held room moderator capability did not survive reload"));
	await tab.click("#convcardClose");
	await namedDirectRow(tab, persistedDmName).locator(".dm-open").click();
	if (await tab.inputValue("#line") !== "workspace dm draft proof") fail("the direct draft did not survive reload");
	await tab.waitForSelector('.bubble:has-text("workspace dm history proof")', { timeout: 20_000 })
		.catch(() => fail("the member's direct history did not survive reload"));
	const restoredFile = tab.locator('.attach-file:has(.name:text-is("workspace-archive.txt"))').last();
	await restoredFile.waitFor({ state: "visible", timeout: 20_000 })
		.catch(() => fail("the direct file metadata did not survive the device archive reload"));
	const [download] = await Promise.all([
		tab.waitForEvent("download", { timeout: 30_000 }),
		restoredFile.locator("button").click(),
	]);
	const downloaded = await download.path();
	if (downloaded == null || await Deno.readTextFile(downloaded) !== "workspace archive bytes") {
		fail("the device archive did not restore the direct file bytes after reload");
	}
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	await tab.click("#opsBtn");
	await tab.waitForSelector("#opsPage");
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	await tab.click("#settingsTab");
	await tab.waitForSelector("#settingsPanel", { state: "attached" });
	await tab.waitForFunction(
		() => document.getElementById("opsListenersToggle")?.getAttribute("aria-checked") === "true",
		undefined,
		{ timeout: 20_000 },
	).catch(() => fail("a remembered swiss did not redeem itself after a reload"));
	const afterReload = await tab.evaluate(() => ({
		diagnostics: document.getElementById("opsDiagnosticsToggle")?.getAttribute("aria-checked"),
		ops: document.getElementById("opsBtn") !== null,
	}));
	if (afterReload.diagnostics !== "false" || !afterReload.ops) {
		fail(`the reload held more or less than it remembered: ${JSON.stringify(afterReload)}`);
	}

	// Toggling off erases the memory with the capability: nothing is held
	// after the next reload, and this browser keeps no swiss at all.
	await removeCapability(tab, "#opsListenersToggle");
	await tab.waitForSelector("#opsBtn", { state: "detached" });
	const afterDrop = await rememberedCaps();
	if (afterDrop.length !== 0) fail(`the drop kept a secret: ${JSON.stringify(afterDrop)}`);
	await tab.reload();
	await tab.waitForSelector("#settingsBtn", { timeout: 30_000 });
	const afterSecondReload = await rememberedCaps();
	if (afterSecondReload.length !== 0) fail(`a reload reminted a secret: ${JSON.stringify(afterSecondReload)}`);
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	await tab.click("#settingsTab");
	await tab.waitForSelector("#settingsPanel", { state: "attached" });
	const nothingHeld = await tab.evaluate(() => ({
		listeners: document.getElementById("opsListenersToggle")?.getAttribute("aria-checked"),
		diagnostics: document.getElementById("opsDiagnosticsToggle")?.getAttribute("aria-checked"),
		ops: document.getElementById("opsBtn") !== null,
	}));
	if (nothingHeld.listeners !== "false" || nothingHeld.diagnostics !== "false" || nothingHeld.ops) {
		fail(`an un-remembered reload still held something: ${JSON.stringify(nothingHeld)}`);
	}

	await tab.click("#settingsClose");
	await tab.waitForSelector("#settingsTitle", { state: "hidden" });

	await runPeeringScene(tab, peeringSwiss, foreignLocator);
	await verifyCompleteOperationsNav(tab, {
		listeners: listenersSwiss,
		diagnostics: diagnosticsSwiss,
		irc: ircSwiss,
		operator: operatorSwiss,
		peering: peeringSwiss,
		viz: vizSwiss,
	});
}
