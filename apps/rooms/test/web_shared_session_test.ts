/// <reference lib="dom" />

// Two browser profiles attached to one durable Rooms session. The browsers do
// not join the directory themselves: they mirror one capability-owned member,
// one checkpoint, and one operation-capability vault.

import { chromium } from "playwright";
import { establishLocalSession } from "./support/session_setup.ts";
import { Buffer } from "node:buffer";
import {
	DEFAULT_ROOMS_VIEW_STATE,
	ROOMS_SESSION_STATE_VERSION,
	WORKSPACE_STATE_KEY,
	WORKSPACE_STATE_VERSION,
} from "../lib/rooms_state.ts";
import { Directory, Room } from "../lib/room_client.ts";
import { dial, loopbackTcpDesignator, roomsLocator } from "../lib/locator.ts";
import { roomsPeerAuthority } from "../lib/routes.ts";
import { openRoomsRuntime } from "../lib/runtime.ts";
import { fail, freePort, ROOT, waitForHttp, WEB } from "./page/harness.ts";
import { reapOwned, spawnOwned, stopOwned } from "./support/children.ts";
import { announcedSturdyref } from "./support/standalone_peer.ts";
import { nextMessage, within } from "./support/rooms_server.ts";
import { png } from "./page/png.ts";
import { proveSharedMixedDirect } from "./page/shared_mixed_dm.ts";
import { namedRoomRow } from "./support/conversation_row.ts";

const SESSION = new URL("../session/main.ts", import.meta.url).pathname;
const httpPort = freePort();
const roomPort = freePort();
const sessionPort = freePort();
const adoptionSessionPort = freePort();
const setupSessionPort = freePort();
const roomState = await Deno.makeTempDir({ prefix: "pancake-rooms-shared-web-room-" });
const sessionState = await Deno.makeTempDir({ prefix: "pancake-rooms-shared-web-session-" });
const adoptionState = await Deno.makeTempDir({ prefix: "pancake-rooms-adoption-web-session-" });
const setupState = await Deno.makeTempDir({ prefix: "pancake-rooms-setup-web-session-" });
const checkpointPath = `${sessionState}/checkpoint.json`;
const locator = loopbackTcpDesignator(roomPort);
const directory = roomsPeerAuthority(roomsLocator(locator));

let browser: Awaited<ReturnType<typeof chromium.launch>> | null = null;
let witnessRuntime: Awaited<ReturnType<typeof openRoomsRuntime>> | null = null;
let witnessDirectory: Directory | null = null;
let witness: Room | null = null;

function startSessionPeer(state: string, port: number, checkpoint?: string): Deno.ChildProcess {
	return spawnOwned("deno", {
		args: [
			"run",
			"--allow-ffi",
			"--unstable-ffi",
			`--allow-read=${ROOT},${state}`,
			`--allow-write=${state}`,
			"--allow-net=127.0.0.1",
			"--allow-env=PANCAKE_LIB_DIR",
			SESSION,
			`--state=${state}`,
			...(checkpoint == null ? [] : [`--checkpoint=${checkpoint}`]),
			"--transport=tcp",
			`--port=${port}`,
		],
		cwd: ROOT,
		env: { PANCAKE_ROOMS_SESSION_RELAY_URL: `ws://127.0.0.1:${httpPort}/relay` },
		stdout: "piped",
		stderr: "inherit",
	});
}

try {
	spawnOwned("deno", {
		args: [
			"run",
			"--allow-ffi",
			"--allow-read",
			"--allow-write",
			"--allow-net",
			"--allow-env",
			"--allow-run",
			WEB,
			String(httpPort),
			String(roomPort),
		],
		cwd: ROOT,
		env: {
			PANCAKE_RELAY_TCP_PEERS:
				`127.0.0.1:${sessionPort},127.0.0.1:${adoptionSessionPort},127.0.0.1:${setupSessionPort}`,
			PANCAKE_ROOMS_STATE: roomState,
			PANCAKE_ROOMS_OPERATOR: "1",
		},
		stdout: "piped",
		stderr: "inherit",
	});
	await waitForHttp(httpPort);
	const operatorSwiss = (await Deno.readTextFile(`${roomState}/operator`)).trim();
	const checkpoint = {
		version: ROOMS_SESSION_STATE_VERSION,
		directories: [{ id: directory, locator, home: true, nick: "durable-member", standing: null }],
		conversations: ["mirror-one", "mirror-two"].map((name) => ({
			kind: "room" as const,
			id: `room-${name}`,
			directory,
			name,
			held: false,
			standing: null,
			draft: "",
		})),
		invitations: [],
		active: "room-mirror-one",
		standing: "",
		ignored: [],
		keepHistory: true,
		join: { room: "", locator: "", nick: "" },
		dmMode: "webrtc" as const,
		vizOverride: "",
		capabilities: {
			operations: [{ capability: "operator" as const, scope: directory, swiss: operatorSwiss }],
			archivePeer: null,
		},
		peering: [],
	};
	await Deno.writeTextFile(checkpointPath, JSON.stringify(checkpoint));
	let sessionPeer = startSessionPeer(sessionState, sessionPort, checkpointPath);
	const sturdyref = await announcedSturdyref(sessionPeer, "ROOMS-SESSION-LISTENING", "Rooms session peer");
	const workspace = JSON.stringify({
		version: WORKSPACE_STATE_VERSION,
		controller: { kind: "attached", sturdyref },
		session: checkpoint,
		view: DEFAULT_ROOMS_VIEW_STATE,
	});

	browser = await chromium.launch({ args: ["--no-sandbox"] });
	const setupPeer = startSessionPeer(setupState, setupSessionPort);
	const setupSturdyref = await announcedSturdyref(
		setupPeer,
		"ROOMS-SESSION-LISTENING",
		"setup Rooms session peer",
	);
	const setupContext = await browser.newContext();
	const setupPage = await setupContext.newPage();
	setupPage.on("pageerror", (error) => console.error(`SETUP-PAGE-ERROR: ${error.message}`));
	await setupPage.goto(`http://127.0.0.1:${httpPort}/`);
	await setupPage.waitForSelector("#sessionSetup");
	await setupPage.fill("#sessionSetupCapability", setupSturdyref);
	await Promise.all([
		setupPage.waitForNavigation({ waitUntil: "domcontentloaded" }),
		setupPage.click("#sessionAttach"),
	]).catch(async (error) => {
		const state = await setupPage.evaluate((key) => ({
			controller: JSON.parse(localStorage.getItem(key) ?? "null")?.controller ?? null,
			setup: document.getElementById("sessionSetup")?.textContent ?? null,
		}), WORKSPACE_STATE_KEY);
		fail(
			`setup attachment did not navigate: ${error instanceof Error ? error.message : error}; ${
				JSON.stringify(state)
			}`,
		);
	});
	await setupPage.waitForSelector("#boot", { state: "detached", timeout: 30_000 })
		.catch(async () => {
			const state = await setupPage.evaluate((key) => ({
				controller: JSON.parse(localStorage.getItem(key) ?? "null")?.controller ?? null,
				setup: document.getElementById("sessionSetup")?.textContent ?? null,
			}), WORKSPACE_STATE_KEY);
			fail(`an admin capability attached from setup but never left the splash: ${JSON.stringify(state)}`);
		});
	await setupPage.waitForSelector("#settingsBtn", { timeout: 15_000 });
	const setupController = await setupPage.evaluate(
		(key) => JSON.parse(localStorage.getItem(key) ?? "null")?.controller ?? null,
		WORKSPACE_STATE_KEY,
	);
	if (setupController?.kind !== "attached" || setupController.sturdyref !== setupSturdyref) {
		fail(`setup attachment saved the wrong controller: ${JSON.stringify(setupController)}`);
	}
	await setupPage.fill("#room", "setup-room");
	await setupPage.fill("#nick", "setup-member");
	if (await setupPage.inputValue("#locator") !== "") {
		fail("a fresh attached session silently filled the directory locator field");
	}
	if (await setupPage.getAttribute("#locator", "placeholder") !== locator) {
		fail("a fresh attached session did not present the page directory behind its empty locator field");
	}
	if (!(await setupPage.locator('label[for="locator"]').textContent())?.includes("This page")) {
		fail("a fresh attached session did not identify its view-local page directory default");
	}
	await setupPage.click("#joinBtn");
	await namedRoomRow(setupPage, "setup-room", false, "membership-joined").waitFor({ timeout: 30_000 })
		.catch(() => fail("a fresh attached session could not join the page directory with an empty locator"));
	await setupPage.waitForSelector("#line:not([disabled])", { timeout: 30_000 })
		.catch(() => fail("a fresh attached session showed intended room state without a live room membership"));
	await setupContext.close();
	await stopOwned(setupPeer);
	const firstContext = await browser.newContext();
	const secondContext = await browser.newContext();
	for (const context of [firstContext, secondContext]) {
		await context.addInitScript(
			({ key, value }) => {
				if (localStorage.getItem(key) == null) localStorage.setItem(key, value);
			},
			{ key: WORKSPACE_STATE_KEY, value: workspace },
		);
	}
	const first = await firstContext.newPage();
	const second = await secondContext.newPage();
	for (const page of [first, second]) {
		page.on("pageerror", (error) => console.error(`PAGE-ERROR: ${error.message}`));
		await page.goto(`http://127.0.0.1:${httpPort}/`);
		await page.waitForSelector("#boot", { state: "detached", timeout: 60_000 });
		await page.waitForSelector("#line:not([disabled])", { timeout: 30_000 });
		await page.waitForFunction(() =>
			[...document.querySelectorAll("#members li")].some((row) => row.textContent?.includes("durable-member"))
		).catch(() => fail("an attached browser did not reconstruct the room roster from its initial snapshot"));
	}

	await namedRoomRow(first, "mirror-two").locator(".room-open").click();
	await second.waitForFunction(() =>
		[...document.querySelectorAll("#roomList li")]
			.find((row) => row.querySelector(".rname")?.textContent?.trim() === "mirror-two")
			?.querySelector(".room-open")?.getAttribute("aria-current") === "page"
	).catch(() => fail("selection from the first browser did not reach the second"));
	await first.fill("#line", "shared draft");
	await second.waitForFunction(
		() => (document.getElementById("line") as HTMLTextAreaElement | null)?.value === "shared draft",
	).catch(() => fail("the first browser's draft did not reach the second"));
	await first.press("#line", "Enter");
	for (const page of [first, second]) {
		await page.waitForSelector('.bubble:has-text("shared draft")', { timeout: 20_000 })
			.catch(() => fail("a line sent through the shared owner did not reach both browsers"));
	}
	await first.fill("#line", "/shrug shared command");
	await first.press("#line", "Enter");
	for (const page of [first, second]) {
		const bubble = page.locator('.bubble:has-text("shared command")').last();
		await bubble.waitFor({ timeout: 20_000 }).catch(async () => {
			const visible = await page.evaluate(() => ({
				composer: (document.getElementById("line") as HTMLTextAreaElement | null)?.value ?? null,
				caret: (document.getElementById("line") as HTMLTextAreaElement | null)?.selectionStart ?? null,
				expanded: document.getElementById("line")?.getAttribute("aria-expanded") ?? null,
				completion: document.getElementById("completePop")?.textContent ?? null,
				bubbles: [...document.querySelectorAll("#log .bubble")].map((row) => row.textContent),
				notices: [...document.querySelectorAll("#log .sys, .toast")].map((row) => row.textContent),
			}));
			fail(`the attached composer did not post its slash-command result: ${JSON.stringify(visible)}`);
		});
		const said = await bubble.textContent() ?? "";
		if (said.includes("/shrug")) {
			fail(`the attached composer produced the wrong slash-command line: ${JSON.stringify(said)}`);
		}
	}
	await first.setInputFiles("#filePick", {
		name: "shared-session.png",
		mimeType: "image/png",
		buffer: Buffer.from(png),
	});
	await first.waitForSelector('.composer-file:has-text("shared-session.png")');
	await first.click("#sendBtn");
	for (const page of [first, second]) {
		await page.waitForFunction(
			() => {
				const image = [...document.querySelectorAll<HTMLImageElement>(".bubble .attach-image img")]
					.find((candidate) => candidate.alt === "shared-session.png");
				return image?.src.startsWith("blob:") === true && image.naturalWidth === 4 && image.naturalHeight === 2;
			},
			undefined,
			{ timeout: 20_000 },
		).catch(() => fail("a shared-session image reserved its rectangle but never rendered its bytes"));
	}
	await proveSharedMixedDirect(browser, httpPort, [first, second], png);
	await second.click("#newRoomBtn");
	await second.fill("#newRoomInput", "mirror-three");
	await second.focus("#newRoomElsewhere");
	await second.press("#newRoomElsewhere", "Enter");
	await second.waitForSelector("#joinForm", { state: "visible" });
	await second.fill("#room", "mirror-three");
	await second.fill("#locator", "");
	await second.fill("#nick", "durable-member");
	await second.click("#joinBtn");
	for (const page of [first, second]) {
		await namedRoomRow(page, "mirror-three").waitFor({ timeout: 30_000 })
			.catch(() => fail("a room joined from one attached browser did not reach the other"));
	}
	await second.click("#newRoomBtn");
	await second.fill("#newRoomInput", "mirror-private");
	await second.focus("#newRoomElsewhere");
	await second.press("#newRoomElsewhere", "Enter");
	await second.waitForSelector("#joinForm", { state: "visible" });
	await second.fill("#room", "mirror-private");
	await second.fill("#locator", "");
	await second.fill("#nick", "durable-member");
	await second.click("#joinPrivate");
	await second.click("#joinBtn");
	for (const page of [first, second]) {
		await page.waitForFunction(() =>
			[...document.querySelectorAll("#roomList li")].some((row) =>
				row.querySelector(".rname")?.textContent?.trim() === "mirror-private" &&
				row.querySelector(".hash svg") !== null
			)
		).catch(() => fail("a private room created from one attached browser did not reach the other"));
	}

	for (const page of [first, second]) {
		await page.click("#settingsBtn");
		await page.waitForSelector("#settingsTitle");
		await page.click("#settingsTab");
		await page.waitForFunction(
			() => document.getElementById("opsOperatorToggle")?.getAttribute("aria-checked") === "true",
		).catch(() => fail("the durable session's saved operator capability did not reach an attached browser"));
	}
	await first.click("#opsOperatorToggle");
	await first.click("#opsCapabilitySetSave");
	await first.waitForSelector("#opsCapabilitySetSaved");
	await second.waitForFunction(
		() => document.getElementById("opsOperatorToggle")?.getAttribute("aria-checked") === "false",
	).catch(() => fail("the capability-vault change did not react across attached browsers"));
	for (const page of [first, second]) await page.click("#settingsClose");

	witnessRuntime = await openRoomsRuntime();
	witnessDirectory = await Directory.connect(locator, (address) => dial(address, witnessRuntime!));
	witness = await Room.subscribe(
		witnessDirectory.session,
		await witnessDirectory.enter("mirror-two"),
		"witness",
	);
	const roster = await within(
		nextMessage(witness, (message) => message.presence?.kind === "roster"),
		"the shared room roster",
	);
	if (
		roster.presence?.kind !== "roster" ||
		roster.presence.names.filter((name) => name === "durable-member").length !== 1
	) {
		fail(`two attached browsers did not remain one directory member: ${JSON.stringify(roster.presence)}`);
	}
	await namedRoomRow(first, "mirror-two").locator(".room-open").click();
	for (const page of [first, second]) {
		await page.waitForFunction(() =>
			[...document.querySelectorAll("#members li")].some((row) => row.textContent?.includes("witness"))
		).catch(() => fail("an attached browser did not apply a live roster join"));
		await page.waitForFunction(() =>
			[...document.querySelectorAll("#log .sys")].some((row) => row.textContent?.includes("witness joined"))
		).catch(() => fail("an attached browser did not draw a room announcement as a system line"));
		const announcementBubble = await page.locator('#log .bubble:has-text("witness joined")').count();
		if (announcementBubble !== 0) fail("an attached browser drew a room announcement as a user message");
	}
	await witness.leave();
	witness = null;
	await witnessDirectory.close();
	witnessDirectory = null;
	await witnessRuntime.close();
	witnessRuntime = null;
	await stopOwned(sessionPeer);
	await first.waitForSelector("#line:disabled", { timeout: 20_000 })
		.catch(() => fail("an attached browser did not enter its disconnected state when the session peer stopped"));
	sessionPeer = startSessionPeer(sessionState, sessionPort);
	const restartedSturdyref = await announcedSturdyref(
		sessionPeer,
		"ROOMS-SESSION-LISTENING",
		"restarted Rooms session peer",
	);
	if (restartedSturdyref !== sturdyref) fail("restarting the durable session changed its sturdyref");
	for (const page of [first, second]) {
		await page.waitForSelector("#line:not([disabled])", { timeout: 60_000 })
			.catch(() => fail("an attached browser did not reconnect to the restarted durable session"));
		await page.waitForFunction(() =>
			[...document.querySelectorAll("#roomList li")].some((row) =>
				row.querySelector(".rname")?.textContent?.trim() === "mirror-private" &&
				row.querySelector(".hash svg") !== null
			)
		).catch(() => fail("the private room did not survive the durable session restart"));
	}
	const restoredHistoryContext = await browser.newContext();
	await restoredHistoryContext.addInitScript(
		({ key, value }) => localStorage.setItem(key, value),
		{ key: WORKSPACE_STATE_KEY, value: workspace },
	);
	const restoredHistory = await restoredHistoryContext.newPage();
	await restoredHistory.goto(`http://127.0.0.1:${httpPort}/`);
	await restoredHistory.waitForSelector("#boot", { state: "detached", timeout: 60_000 });
	await namedRoomRow(restoredHistory, "mirror-two").locator(".room-open").click();
	await restoredHistory.waitForFunction(
		() => {
			const image = [...document.querySelectorAll<HTMLImageElement>(".bubble .attach-image img")]
				.find((candidate) => candidate.alt === "shared-session.png");
			return image?.src.startsWith("blob:") === true && image.naturalWidth === 4 && image.naturalHeight === 2;
		},
		undefined,
		{ timeout: 30_000 },
	).catch(() =>
		fail("a fresh attached browser could not reconstruct archived image bytes after the session restarted")
	);
	await restoredHistoryContext.close();
	await stopOwned(sessionPeer);
	const recoveryContext = await browser.newContext();
	await recoveryContext.addInitScript(
		({ key, value }) => {
			if (localStorage.getItem(key) == null) localStorage.setItem(key, value);
		},
		{ key: WORKSPACE_STATE_KEY, value: workspace },
	);
	const recovery = await recoveryContext.newPage();
	await recovery.goto(`http://127.0.0.1:${httpPort}/`);
	await recovery.waitForSelector("#sessionSetup .said[data-kind='failure']", { timeout: 30_000 })
		.catch(() => fail("an unavailable shared session left no actionable startup state"));
	if (!await recovery.locator("#sessionAttach").isVisible()) fail("shared-session recovery offered no retry");
	await recovery.click("#sessionUseLocal");
	const savedLocal = await recovery.waitForFunction((key) => {
		const saved = JSON.parse(localStorage.getItem(key) ?? "null");
		return saved?.controller?.kind === "local";
	}, WORKSPACE_STATE_KEY).then(() => true, () => false);
	if (!savedLocal) {
		const recoveryState = await recovery.evaluate((key) => ({
			saved: localStorage.getItem(key),
			detail: document.querySelector("#sessionSetup .said")?.textContent ?? "",
			url: location.href,
		}), WORKSPACE_STATE_KEY);
		fail(`shared-session recovery did not save the explicit local choice: ${JSON.stringify(recoveryState)}`);
	}
	await recoveryContext.close();

	const adoptionPeer = startSessionPeer(adoptionState, adoptionSessionPort);
	const adoptionSturdyref = await announcedSturdyref(
		adoptionPeer,
		"ROOMS-SESSION-LISTENING",
		"fresh Rooms session peer",
	);
	const localWorkspace = JSON.stringify({
		version: WORKSPACE_STATE_VERSION,
		controller: { kind: "local" },
		session: checkpoint,
		view: DEFAULT_ROOMS_VIEW_STATE,
	});
	const attachThroughSettings = async (page: import("playwright").Page) => {
		await page.click("#settingsBtn");
		await page.waitForSelector("#settingsTitle");
		await page.click("#sessionTab");
		await page.click("#sessionAttachOpen");
		await page.waitForSelector("#sessionAttachTitle");
		await page.fill("#sharedSessionCapability", adoptionSturdyref);
		await Promise.all([
			page.waitForNavigation({ waitUntil: "domcontentloaded" }),
			page.click("#sessionAttachGo"),
		]);
		await page.waitForSelector("#boot", { state: "detached", timeout: 60_000 });
	};

	const adoptingContext = await browser.newContext();
	await adoptingContext.addInitScript(
		({ key, value }) => {
			if (localStorage.getItem(key) == null) localStorage.setItem(key, value);
		},
		{ key: WORKSPACE_STATE_KEY, value: localWorkspace },
	);
	const adopting = await adoptingContext.newPage();
	await adopting.goto(`http://127.0.0.1:${httpPort}/`);
	await adopting.waitForSelector("#line:not([disabled])", { timeout: 60_000 });
	await adopting.fill("#line", "adopted through Settings");
	await attachThroughSettings(adopting);
	await adopting.waitForSelector("#line:not([disabled])", { timeout: 60_000 });

	const joiningContext = await browser.newContext();
	const joining = await joiningContext.newPage();
	await joining.goto(`http://127.0.0.1:${httpPort}/`);
	await establishLocalSession(joining);
	await attachThroughSettings(joining);
	await joining.waitForSelector("#line:not([disabled])", { timeout: 60_000 });
	await namedRoomRow(joining, "mirror-one").waitFor();
	if (await joining.inputValue("#line") !== "adopted through Settings") {
		fail("the second browser did not receive the workspace adopted through the first browser's attach action");
	}
	await joining.click("#settingsBtn");
	await joining.click("#sessionTab");
	await joining.getByText("Attached session", { exact: true }).waitFor();
	if ((await joining.textContent("#currentSessionCapability"))?.trim() !== adoptionSturdyref) {
		fail("an attached browser did not expose the exact session capability that owns its workspace");
	}
	await joining.click("#sessionAccessOpen");
	const accessModal = joining.locator(".session-access-modal");
	await accessModal.getByLabel("Name").fill("Read-only display");
	await accessModal.locator("select").selectOption("observe");
	await accessModal.getByRole("button", { name: "Issue capability" }).click();
	const issuedGrant = accessModal.locator(".session-grant").filter({ hasText: "Read-only display" });
	await issuedGrant.waitFor();
	const observeSturdyref = (await issuedGrant.locator(".copy-field-text").textContent())?.trim() ?? "";
	if (!observeSturdyref.startsWith("ocapn://") || !observeSturdyref.includes("/s/")) {
		fail(`session access returned no sturdyref: ${JSON.stringify(observeSturdyref)}`);
	}
	await accessModal.getByRole("button", { name: "Close" }).click();
	await joining.click("#sessionDataOpen");
	if ((await joining.textContent("#sessionDataTitle"))?.trim() !== "Shared session data") {
		fail("an attached browser did not identify the durable session as its data owner");
	}
	await joining.locator(".session-data-modal").getByRole("button", { name: "Close" }).click();
	await joining.click("#settingsTab");
	await joining.waitForFunction(
		() => document.getElementById("opsOperatorToggle")?.getAttribute("aria-checked") === "true",
	).catch(() => fail("the second browser did not receive the operator capability vault adopted by the first"));
	await joining.click("#settingsClose");
	const controllers = await Promise.all(
		[adopting, joining].map((page) =>
			page.evaluate((key) => JSON.parse(localStorage.getItem(key) ?? "null")?.controller, WORKSPACE_STATE_KEY)
		),
	);
	if (controllers.some((controller) => controller?.sturdyref !== adoptionSturdyref)) {
		fail(`the Settings attach flow did not retain one session capability: ${JSON.stringify(controllers)}`);
	}

	const observingContext = await browser.newContext();
	const observing = await observingContext.newPage();
	await observing.goto(`http://127.0.0.1:${httpPort}/`);
	await observing.waitForSelector("#sessionSetup");
	await observing.fill("#sessionSetupCapability", observeSturdyref);
	await Promise.all([
		observing.waitForNavigation({ waitUntil: "domcontentloaded" }),
		observing.click("#sessionAttach"),
	]);
	await observing.waitForSelector("#boot", { state: "detached", timeout: 60_000 });
	await namedRoomRow(observing, "mirror-one").waitFor();
	if (await observing.getAttribute("#line", "placeholder") !== "This session capability is read only.") {
		fail("an observe grant painted a composer that claimed it could send");
	}
	if (
		await observing.locator(
			"#newRoomBtn:visible, #newDmBtn:visible, #leaveBtn:visible, #roomList .room-leave:visible, #members .dm-btn:visible",
		).count() !== 0
	) {
		fail("an observe grant painted conversation mutation controls");
	}
	if (
		!await observing.locator("#roomStanding").isDisabled() || !await observing.locator("#standingBtn").isDisabled()
	) {
		fail("an observe grant offered a standing mutation");
	}
	await observing.click("#roomAbout");
	if (await observing.locator("#convcardCapabilitiesTab, #convcardLeaveAsk").count() !== 0) {
		fail("an observe grant painted room authority controls");
	}
	await observing.click("#convcardClose");
	await observing.click("#settingsBtn");
	await observing.click("#sessionTab");
	await observing.getByText("This capability is read only.", { exact: false }).waitFor();
	if (await observing.locator("#sessionAccessOpen").count() !== 0) {
		fail("an observe grant could open session administration");
	}
	if (await observing.locator("#settingsTab").count() !== 0) {
		fail("an observe grant painted mutation settings it cannot use");
	}
	await observing.click("#sessionDataOpen");
	if (await observing.locator("#stateImport").count() !== 0) {
		fail("an observe grant could replace the durable checkpoint");
	}
	await observing.locator(".session-data-modal").getByRole("button", { name: "Close" }).click();
	await observing.click("#settingsClose");

	await joining.click("#settingsBtn");
	await joining.click("#sessionTab");
	await joining.click("#sessionAccessOpen");
	const grantToRevoke = joining.locator(".session-grant").filter({ hasText: "Read-only display" });
	await grantToRevoke.getByRole("button", { name: "Revoke…" }).click();
	await grantToRevoke.getByRole("button", { name: "Revoke access" }).click();
	await observing.getByText("This session capability was revoked.", { exact: false }).waitFor();
	await observingContext.close();
	await joining.locator(".session-access-modal").getByRole("button", { name: "Close" }).click();
	await joining.click("#settingsClose");

	await attachThroughSettings(adopting);
	await adopting.waitForSelector("#line:not([disabled])", { timeout: 60_000 })
		.catch(() => fail("attaching an already-attached browser to the same session opened a duplicate CapTP pair"));
	await joiningContext.close();
	await adoptingContext.close();
	await stopOwned(adoptionPeer);

	console.log(
		"PASS: browser profiles mirrored one durable Rooms session, issued and revoked restart-stable attenuated access, and kept local, interaction, and administration state distinct",
	);
} finally {
	await witness?.leave().catch(() => {});
	await witnessDirectory?.close().catch(() => {});
	await witnessRuntime?.close().catch(() => {});
	await browser?.close().catch(() => {});
	await reapOwned();
	await Deno.remove(adoptionState, { recursive: true }).catch(() => {});
	await Deno.remove(setupState, { recursive: true }).catch(() => {});
	await Deno.remove(sessionState, { recursive: true }).catch(() => {});
	await Deno.remove(roomState, { recursive: true }).catch(() => {});
}
