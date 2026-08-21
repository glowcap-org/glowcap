// The Operations flow: capabilities the reader can hold over the server.
//
// The Advanced toggle is the capability: flipping it on opens the take modal
// — paste the swiss number the server printed, fetch it on the live session —
// and only a successful take lands the toggle on. Cancel leaves nothing held.
// While anything is held, an Operations control leads the Settings head's
// toggle row from the left and opens the modal: one pane per held capability,
// a tab bar only for two, and never a take form inside a pane. The listeners
// pane then has to tell the truth twice over: the listener serving this very
// page wears a marker and a disabled switch instead of a control that could
// succeed, and a refused `up` comes back as the server's own sentence in the
// row that asked. Flipping a toggle off drops that capability, pane and
// swiss with it.

import type { Page } from "playwright";
import { fail } from "./harness.ts";

export async function run(tab: Page, statePath: string): Promise<void> {
	const listenersSwiss = (await Deno.readTextFile(`${statePath}/admin-listeners`)).trim();
	const diagnosticsSwiss = (await Deno.readTextFile(`${statePath}/diagnostics`)).trim();
	const vizSwiss = (await Deno.readTextFile(`${statePath}/viz`)).trim();
	if (listenersSwiss === "" || diagnosticsSwiss === "" || vizSwiss === "") {
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

	// Flipping a toggle on asks, it does not grant: the take modal opens, and
	// dismissing it leaves the toggle off and the control absent.
	await tab.click("#opsListenersToggle");
	await tab.waitForSelector("#opsTakeTitle");
	await tab.click("#opsTakeClose");
	await tab.waitForSelector("#settingsPanel", { state: "attached" });
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

	// One held capability: the modal is that pane alone — no tab bar, no take
	// form, one row per transport seat the server itself listed, each with the
	// owning package's description. The serving tcp listener is up with a
	// disabled switch and the marker, its locator there to copy; a seat the
	// server already knows cannot come up (onion, with no Tor) is disabled
	// with the standing sentence; the rest are down with live switches.
	await tab.click("#opsBtn");
	await tab.waitForSelector("#operationsTitle");
	// This card scrolls its own content, so its top stripe is a sticky cap
	// rather than a background layer and rows pass underneath it. The cap has
	// to be opaque for its whole height, the gradient over the card's own
	// paper: painting only the gradient leaves the pixels below it clear, and
	// a row sliding under shows straight through the card's top edge.
	const cap = await tab.evaluate(() => {
		const card = document.getElementById("operationsTitle")?.closest(".modal-card") ?? null;
		if (card === null) return null;
		const style = getComputedStyle(card, "::before");
		return { image: style.backgroundImage, ground: style.backgroundColor };
	});
	if (cap === null || !cap.image.includes("gradient")) {
		fail(`the operations card has no gradient stripe: ${JSON.stringify(cap)}`);
	}
	if (/^(transparent|rgba\(0, 0, 0, 0\))$/.test(cap.ground)) {
		fail("the scrolling card's stripe paints no ground under it, so rows slide through the card's top edge");
	}
	if (await tab.$("#opsTabs") !== null) fail("one held capability still drew a tab bar");
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

	// Take diagnostics too: the modal grows its tab bar, and the diagnostics
	// pane arrives holding its table.
	await tab.click("#operationsClose");
	await tab.waitForSelector("#settingsPanel", { state: "attached" });
	await tab.click("#opsDiagnosticsToggle");
	await tab.waitForSelector("#opsTakeCap");
	await tab.fill("#opsTakeCap", diagnosticsSwiss);
	await tab.press("#opsTakeCap", "Enter");
	await tab.waitForSelector("#settingsPanel", { state: "attached" });
	await tab.click("#opsBtn");
	await tab.waitForSelector("#opsTabs");
	await tab.click("#diagnosticsOpsTab");
	await tab.waitForFunction(
		() => {
			const cells = [...document.querySelectorAll("#diagnosticsOpsPanel td")]
				.map((cell) => cell.textContent ?? "");
			return cells.includes("directory");
		},
		undefined,
		{ timeout: 10_000 },
	).catch(() => fail("the diagnostics pane did not list the directory"));
	await tab.click("#listenersOpsTab");
	await tab.waitForSelector("#listenersList");

	// The third capability: the protocol visualizer. Its swiss is presented to
	// the live timeline endpoint rather than fetched on the directory session,
	// and taking it is what arms this tab's own trace publishing. With three
	// held, the tab bar counts three.
	await tab.click("#operationsClose");
	await tab.waitForSelector("#settingsPanel", { state: "attached" });
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
	if (three !== "3") fail(`three held capabilities drew a tab bar of ${three}`);
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
	await tab.click("#operationsClose");
	await tab.waitForSelector("#settingsPanel", { state: "attached" });
	await tab.click("#opsVizToggle");
	await tab.waitForFunction(
		() => document.getElementById("opsVizToggle")?.getAttribute("aria-checked") === "false",
	).catch(() => fail("dropping the viz capability did not turn its toggle off"));
	if ((await vizKeys()).length !== 0) fail("dropping the viz capability kept its secret");

	// Dropping a capability takes its pane with it: with only listeners
	// held, the modal has no tab bar and nothing of the diagnostics left.
	// Diagnostics was taken without Remember, so its drop also leaves this
	// browser holding no memory of it.
	await tab.click("#opsDiagnosticsToggle");
	await tab.waitForFunction(
		() => document.getElementById("opsDiagnosticsToggle")?.getAttribute("aria-checked") === "false",
	).catch(() => fail("dropping the inspect capability did not turn its toggle off"));
	await tab.click("#opsBtn");
	await tab.waitForSelector("#operationsTitle");
	if (await tab.$("#opsTabs") !== null) fail("one remaining capability still drew a tab bar");
	if (await tab.$("#diagnosticsOpsPanel") !== null) fail("a dropped capability's pane still answered");
	await tab.waitForSelector("#listenersList");
	await tab.click("#operationsClose");
	await tab.waitForSelector("#settingsPanel", { state: "attached" });
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

	// Leave the page as the surrounding scenes expect it: dialogs closed,
	// nothing held, nothing remembered.
	await tab.click("#settingsClose");
	await tab.waitForSelector("#settingsTitle", { state: "hidden" });
}
