// The Operations flow: capabilities the reader can hold over the server.
//
// The Capabilities toggle is the capability: flipping it on opens the take modal
// — paste the swiss number the server printed, fetch it on the live session —
// and only a successful take lands the toggle on. Cancel leaves nothing held.
// While anything is held, an Operations control leads the Settings head's
// toggle row from the left and stands the reader on the /ops page: one
// address per held capability, a pane nav only for two, never a take form
// inside a held pane — and an address arrived at cold gates on possession.
// The page keeps the shell: the rail stays, Settings opens over it, and the
// rail's active row is the way back. The listeners
// pane then has to tell the truth twice over: the listener serving this very
// page wears a marker and a disabled switch instead of a control that could
// succeed, and a refused `up` comes back as the server's own sentence in the
// row that asked. Flipping a toggle off drops that capability, pane and
// swiss with it. The peering pane closes the scene: a room joined on the
// second directory is published into this one, durably, and revoked from the
// same row that made it.

import type { Page } from "playwright";
import { fail } from "./harness.ts";

export async function run(tab: Page, statePath: string, foreignLocator: string): Promise<void> {
	const listenersSwiss = (await Deno.readTextFile(`${statePath}/admin-listeners`)).trim();
	const diagnosticsSwiss = (await Deno.readTextFile(`${statePath}/diagnostics`)).trim();
	const peeringSwiss = (await Deno.readTextFile(`${statePath}/peering`)).trim();
	const vizSwiss = (await Deno.readTextFile(`${statePath}/viz`)).trim();
	const ircSwiss = (await Deno.readTextFile(`${statePath}/irc`)).trim();
	if (
		listenersSwiss === "" || diagnosticsSwiss === "" || peeringSwiss === "" || vizSwiss === "" ||
		ircSwiss === ""
	) {
		fail("the room server did not persist its operations swiss numbers");
	}

	// Nothing held yet: Settings opens without an Operations control.
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	if (await tab.$("#opsBtn") !== null) {
		fail("the Operations control was drawn before any capability was held");
	}
	await tab.click("#capabilitiesTab");
	await tab.waitForSelector("#capabilitiesPanel", { state: "attached" });

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
	await tab.waitForSelector("#opsTakeTitle");
	await tab.click("#opsTakeClose");
	await tab.waitForSelector("#opsTakeTitle", { state: "detached" });
	if (await tab.$("#settingsTitle") !== null) fail("closing a gate's take fell back into Settings");
	// The shell stands under the namespace: the rail and its Settings control
	// are right here, so nothing has to be left to reach them.
	if (await tab.$("#roomList") === null) fail("the operations surface dropped the rail");
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	await tab.click("#capabilitiesTab");
	await tab.waitForSelector("#capabilitiesPanel", { state: "attached" });

	// The IRC gateway, end to end at the UI: its toggle takes the capability,
	// the pane bridges a channel (a dead endpoint is fine — joining registers
	// the room and the connection retries behind it), the bridged room stands
	// in the rail's namespace, and parting takes it down. Dropped again at the
	// end so the surrounding scenes keep their held-capability counts.
	await tab.click("#opsIrcToggle");
	await tab.waitForSelector("#opsTakeCap");
	await tab.fill("#opsTakeCap", ircSwiss);
	await tab.press("#opsTakeCap", "Enter");
	await tab.waitForSelector("#opsBtn", { timeout: 15_000 });
	await tab.click("#opsBtn");
	await tab.waitForFunction(() => location.pathname === "/ops/irc");
	if (await tab.$("#opsTabs") !== null) fail("one held capability still drew a pane nav");
	await tab.waitForSelector("#ircBridgedList");
	await tab.fill("#ircJoinNetwork", "deadnet");
	await tab.fill("#ircJoinChannel", "#nowhere");
	await tab.fill("#ircJoinHost", "127.0.0.1");
	await tab.fill("#ircJoinPort", "1");
	await tab.fill("#ircJoinNick", "proofbot");
	await tab.click("#ircJoinTls");
	await tab.click("#ircJoinBtn");
	await tab.waitForSelector('#ircBridgedList .ops-listener[data-room="deadnet/#nowhere"]', { timeout: 10_000 });
	// Entered through the ordinary rail field, the bridged room stands as a
	// room whose row says where its channel lives — and the field finishes
	// its name like any other room's, because a bridged channel is a
	// directory row like any other.
	await tab.click("#newRoomBtn");
	await tab.fill("#newRoomInput", "deadnet");
	await tab.waitForSelector('#newRoomOffers .complete-row:has-text("deadnet/#nowhere")', { timeout: 10_000 })
		.catch(() => fail("the rail field does not offer the bridged channel's name"));
	await tab.click('#newRoomOffers .complete-row:has-text("deadnet/#nowhere")');
	await tab.press("#newRoomInput", "Enter");
	await tab.waitForSelector("#roomList .rwhere-bridge", { timeout: 10_000 })
		.catch(() => fail("the bridged room's rail row does not say where its channel lives"));
	const bridgedSaid = await tab.textContent("#roomList .rwhere-bridge");
	if (bridgedSaid === null || !bridgedSaid.includes("127.0.0.1:1")) {
		fail(`the bridged row's caption does not name the network: "${bridgedSaid}"`);
	}
	const bridgedRow = tab.locator("#roomList li").filter({ has: tab.locator('.rname:text-is("deadnet/#nowhere")') });
	await bridgedRow.hover();
	await bridgedRow.locator(".room-leave").click();
	await bridgedRow.waitFor({ state: "detached", timeout: 10_000 })
		.catch(() => fail("the bridged room could not be left"));
	// Leaving the room stood us back at the front page; the Operations
	// control lives in the Settings head, so it opens through it.
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	await tab.click("#opsBtn");
	await tab.waitForSelector('#ircBridgedList .ops-listener[data-room="deadnet/#nowhere"]', { timeout: 10_000 });
	// The row's own door: Open enters the room and stands the reader in it.
	await tab.click('#ircBridgedList .ops-listener[data-room="deadnet/#nowhere"] button:has-text("Open")');
	await tab.waitForFunction(() => location.pathname === "/", undefined, { timeout: 10_000 });
	await tab.waitForSelector('#roomList li.here .rname:text-is("deadnet/#nowhere")', { timeout: 10_000 })
		.catch(() => fail("Open on the bridged row did not stand the reader in the room"));
	const reopenedRow = tab.locator("#roomList li").filter({
		has: tab.locator('.rname:text-is("deadnet/#nowhere")'),
	});
	await reopenedRow.hover();
	await reopenedRow.locator(".room-leave").click();
	await reopenedRow.waitFor({ state: "detached", timeout: 10_000 });
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	await tab.click("#opsBtn");
	await tab.waitForSelector('#ircBridgedList .ops-listener[data-room="deadnet/#nowhere"]', { timeout: 10_000 });
	await tab.click('#ircBridgedList .ops-listener[data-room="deadnet/#nowhere"] button:has-text("Part")');
	await tab.waitForFunction(
		() => document.querySelector('#ircBridgedList .ops-listener[data-room="deadnet/#nowhere"]') === null,
		undefined,
		{ timeout: 10_000 },
	).catch(() => fail("parting the bridged channel did not retire its row"));
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	await tab.click("#capabilitiesTab");
	await tab.waitForSelector("#capabilitiesPanel", { state: "attached" });
	await tab.click("#opsIrcToggle");
	await tab.waitForFunction(
		() => document.getElementById("opsIrcToggle")?.getAttribute("aria-checked") === "false",
	).catch(() => fail("dropping the gateway did not turn its toggle off"));

	// Flipping a toggle on asks, it does not grant: the take modal opens, and
	// dismissing it leaves the toggle off and the control absent.
	await tab.click("#opsListenersToggle");
	await tab.waitForSelector("#opsTakeTitle");
	await tab.click("#opsTakeClose");
	await tab.waitForSelector("#capabilitiesPanel", { state: "attached" });
	const afterCancel = await tab.evaluate(() => ({
		checked: document.getElementById("opsListenersToggle")?.getAttribute("aria-checked"),
		ops: document.getElementById("opsBtn") !== null,
	}));
	if (afterCancel.checked !== "false" || afterCancel.ops) {
		fail(`a dismissed take still granted something: ${JSON.stringify(afterCancel)}`);
	}

	// Ask again and take it — with Remember checked, so a reload below can
	// prove the swiss auto-redeems. The toggle lands on and the control
	// appears.
	await tab.click("#opsListenersToggle");
	await tab.waitForSelector("#opsTakeCap");
	await tab.fill("#opsTakeCap", listenersSwiss);
	await tab.check("#opsTakeRemember");
	await tab.press("#opsTakeCap", "Enter");
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

	// One held capability: the page is that pane alone — no tab bar, no take
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
	if (await tab.$("#opsTabs") !== null) fail("one held capability still drew a pane nav");
	if (await tab.$("#opsTakeCap") !== null) fail("a held pane still carried a take form");
	await tab.waitForSelector("#listenersList");
	const shown = await tab.evaluate(() => {
		const row = (transport: string) => {
			const li = document.querySelector(`#listenersList .ops-listener[data-transport="${transport}"]`);
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
			count: document.querySelectorAll("#listenersList .ops-listener").length,
			described: [...document.querySelectorAll("#listenersList .ops-listener .hint")]
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
		document.querySelector('#listenersList .ops-listener[data-transport="keyed-relay"] .copy-field-text')
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

	// Take diagnostics too: the page grows its tab bar, and the diagnostics
	// pane arrives holding its table.
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	await tab.click("#capabilitiesTab");
	await tab.waitForSelector("#capabilitiesPanel", { state: "attached" });
	await tab.click("#opsDiagnosticsToggle");
	await tab.waitForSelector("#opsTakeCap");
	await tab.fill("#opsTakeCap", diagnosticsSwiss);
	await tab.press("#opsTakeCap", "Enter");
	await tab.waitForSelector("#capabilitiesPanel", { state: "attached" });
	await tab.click("#opsBtn");
	await tab.waitForSelector("#opsTabs");
	await tab.click("#diagnosticsOpsTab");
	await tab.waitForFunction(() => location.pathname === "/ops/diagnostics");
	await tab.waitForFunction(
		() => {
			const cells = [...document.querySelectorAll("#diagnosticsOpsPanel td")]
				.map((cell) => cell.textContent ?? "");
			return cells.includes("directory");
		},
		undefined,
		{ timeout: 10_000 },
	).catch(() => fail("the diagnostics pane did not list the directory"));
	// The page's own trouble journal stands beside the directory's holdings,
	// present even when it has nothing to say.
	await tab.waitForSelector("#pageTrouble");
	await tab.click("#listenersOpsTab");
	await tab.waitForSelector("#listenersList");

	// The protocol visualizer. Its swiss is presented to
	// the live timeline endpoint rather than fetched on the directory session,
	// and taking it is what arms this tab's own trace publishing. With three
	// held, the tab bar counts three.
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	await tab.click("#capabilitiesTab");
	await tab.waitForSelector("#capabilitiesPanel", { state: "attached" });
	await tab.click("#opsVizToggle");
	await tab.waitForSelector("#opsTakeCap");
	await tab.fill("#opsTakeCap", vizSwiss);
	await tab.check("#opsTakeRemember");
	await tab.press("#opsTakeCap", "Enter");
	await tab.waitForFunction(
		() => document.getElementById("opsVizToggle")?.getAttribute("aria-checked") === "true",
		undefined,
		{ timeout: 15_000 },
	).catch(() => fail("taking the viz capability did not land its toggle on"));
	await tab.click("#opsBtn");
	await tab.waitForSelector("#opsTabs");
	const three = await tab.getAttribute("#opsTabs", "data-count");
	if (three !== "3") fail(`three held capabilities drew a pane nav of ${three}`);
	await tab.click("#vizOpsTab");
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
	const vizKeys = () =>
		tab.evaluate(() => Object.keys(localStorage).filter((key) => key.startsWith("rooms.ops-swiss.viz.")));
	if ((await vizKeys()).length !== 1) fail("the viz take with Remember kept no swiss");
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	await tab.click("#capabilitiesTab");
	await tab.waitForSelector("#capabilitiesPanel", { state: "attached" });
	await tab.click("#opsVizToggle");
	await tab.waitForFunction(
		() => document.getElementById("opsVizToggle")?.getAttribute("aria-checked") === "false",
	).catch(() => fail("dropping the viz capability did not turn its toggle off"));
	if ((await vizKeys()).length !== 0) fail("dropping the viz capability kept its secret");

	// Dropping a capability takes its pane with it: with only listeners
	// held, the page has no tab bar and nothing of the diagnostics left.
	// Diagnostics was taken without Remember, so its drop also leaves this
	// browser holding no memory of it.
	await tab.click("#opsDiagnosticsToggle");
	await tab.waitForFunction(
		() => document.getElementById("opsDiagnosticsToggle")?.getAttribute("aria-checked") === "false",
	).catch(() => fail("dropping the inspect capability did not turn its toggle off"));
	await tab.click("#opsBtn");
	await tab.waitForSelector("#operationsTitle");
	if (await tab.$("#opsTabs") !== null) fail("one remaining capability still drew a pane nav");
	if (await tab.$("#diagnosticsOpsPanel") !== null) fail("a dropped capability's pane still answered");
	await tab.waitForSelector("#listenersList");
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	await tab.click("#capabilitiesTab");
	await tab.waitForSelector("#capabilitiesPanel", { state: "attached" });
	await tab.click("#settingsClose");
	await tab.waitForSelector("#settingsTitle", { state: "hidden" });

	// A reload keeps only what the reader asked this browser to remember: the
	// listeners swiss auto-redeems on the home session coming up, so its
	// toggle is simply on; diagnostics, taken without Remember, is not held.
	const rememberedKeys = () =>
		tab.evaluate(() => Object.keys(localStorage).filter((key) => key.startsWith("rooms.ops-swiss.")));
	const before = await rememberedKeys();
	if (before.length !== 1) fail(`expected exactly the listeners swiss remembered: ${JSON.stringify(before)}`);
	await tab.reload();
	await tab.waitForSelector("#settingsBtn", { timeout: 30_000 });
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	await tab.click("#capabilitiesTab");
	await tab.waitForSelector("#capabilitiesPanel", { state: "attached" });
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
	await tab.click("#opsListenersToggle");
	await tab.waitForSelector("#opsBtn", { state: "detached" });
	const afterDrop = await rememberedKeys();
	if (afterDrop.length !== 0) fail(`the drop kept a secret: ${JSON.stringify(afterDrop)}`);
	await tab.reload();
	await tab.waitForSelector("#settingsBtn", { timeout: 30_000 });
	const afterSecondReload = await rememberedKeys();
	if (afterSecondReload.length !== 0) fail(`a reload reminted a secret: ${JSON.stringify(afterSecondReload)}`);
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	await tab.click("#capabilitiesTab");
	await tab.waitForSelector("#capabilitiesPanel", { state: "attached" });
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

	// ── Peering: a room from another directory becomes durable here ──────
	// Peering publishes across directories, so the pane needs a
	// room to offer: join one on the second server first, the way a reader
	// would, through the rail's own field.
	await tab.setViewportSize({ width: 1280, height: 800 });
	await tab.click("#newRoomBtn");
	await tab.fill("#newRoomInput", "annex");
	await tab.focus("#newRoomElsewhere");
	await tab.press("#newRoomElsewhere", "Enter");
	await tab.waitForSelector("#joinForm", { timeout: 10_000 })
		.catch(() => fail("the rail offered no way to reach a room on another server"));
	await tab.fill("#locator", foreignLocator);
	await tab.click("#joinBtn");
	await tab.waitForSelector("#line:not([disabled])", { timeout: 30_000 })
		.catch(() => fail("the second directory's room did not open for the peering scene"));

	// Take the peering capability from its Capabilities toggle, like its siblings.
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	await tab.click("#capabilitiesTab");
	await tab.waitForSelector("#capabilitiesPanel", { state: "attached" });
	await tab.click("#opsPeeringToggle");
	await tab.waitForSelector("#opsTakeCap");
	await tab.fill("#opsTakeCap", peeringSwiss);
	await tab.press("#opsTakeCap", "Enter");
	await tab.waitForSelector("#opsBtn", { timeout: 15_000 })
		.catch(() => fail("taking the peering capability did not land its toggle on"));

	// The pane offers exactly the room on the other directory, prefills the
	// published name with the room's own, and publishing lands a live row.
	await tab.click("#opsBtn");
	await tab.waitForSelector("#operationsTitle");
	await tab.waitForSelector("#peeringSource");
	const offered = await tab.evaluate(() => ({
		options: [...document.querySelectorAll("#peeringSource option")].map((opt) => opt.textContent ?? ""),
		name: (document.getElementById("peeringName") as HTMLInputElement | null)?.value ?? "",
	}));
	if (offered.options.length !== 1 || !offered.options[0].includes("annex")) {
		fail(`the peering pane does not offer the other directory's room: ${JSON.stringify(offered)}`);
	}
	if (offered.name !== "annex") {
		fail(`the published name does not follow the picked room: ${JSON.stringify(offered)}`);
	}
	await tab.fill("#peeringName", "annex-here");
	await tab.click("#peeringPublish");
	await tab.waitForSelector('#peeringList li[data-phase="live"]', { timeout: 30_000 })
		.catch(() => fail("publishing the room did not land a live publication row"));
	const published = await tab.evaluate(() => {
		const row = document.querySelector("#peeringList li");
		return {
			name: row?.querySelector(".ops-pub-name")?.textContent ?? "",
			source: row?.querySelector("code")?.textContent ?? "",
		};
	});
	if (published.name !== "annex-here" || published.source === "") {
		fail(`the publication row does not carry its name and source: ${JSON.stringify(published)}`);
	}

	// Revoking is the row's own act, and it removes the row with the listing.
	await tab.click("#peeringList li button");
	await tab.waitForSelector("#peeringList", { state: "detached", timeout: 15_000 })
		.catch(() => fail("revoking the publication did not retire its row"));

	// Leave the page as the surrounding scenes expect it: dialogs closed,
	// nothing held, nothing remembered, and the peering scene's room left.
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	await tab.click("#capabilitiesTab");
	await tab.waitForSelector("#capabilitiesPanel", { state: "attached" });
	await tab.click("#opsPeeringToggle");
	await tab.waitForFunction(
		() => document.getElementById("opsPeeringToggle")?.getAttribute("aria-checked") === "false",
	).catch(() => fail("dropping the peering capability did not turn its toggle off"));
	const peeringKeys = await tab.evaluate(() =>
		Object.keys(localStorage).filter((key) => key.startsWith("rooms.ops-swiss."))
	);
	if (peeringKeys.length !== 0) fail(`the peering scene left a secret behind: ${JSON.stringify(peeringKeys)}`);
	await tab.click("#settingsClose");
	await tab.waitForSelector("#settingsTitle", { state: "hidden" });
	// The rail is the way back: standing on operations marks no room, and
	// picking one is the transition that leaves the namespace.
	await tab.locator("#roomList li").filter({ has: tab.locator('.rname:text-is("annex")') })
		.locator(".room-open").click();
	await tab.waitForSelector("#opsPage", { state: "detached" });
	await tab.waitForSelector("#line");
	const annexRow = tab.locator("#roomList li").filter({ has: tab.locator('.rname:text-is("annex")') });
	await annexRow.hover();
	await annexRow.locator(".room-leave").click();
	await annexRow.waitFor({ state: "detached", timeout: 15_000 })
		.catch(() => fail("the peering scene could not leave its room"));
}
