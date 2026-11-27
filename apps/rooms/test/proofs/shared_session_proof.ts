import { proveRefusedAttachFocus, watchAttachHandoff } from "../page/attach_handoff.ts";
import { proveColdWorkspace } from "../page/cold_workspace.ts";
import { spawnWeb, webPort } from "../support/web_front.ts";
import * as tcp from "@glowcap/tcp";
import type { Argument } from "@glowcap/runtime";
/// <reference lib="dom" />
// Two production pages consume one managed process workspace. Setup selects a
// strong use field; reload and process restart must recover that exact owner.
import { chromium, type Page } from "playwright";
import { fail } from "../support/fail.ts";
import { ROOT, SESSION } from "../support/paths.ts";
import { nonEphemeralPort } from "../../../../bindings/ts/test/ports.ts";
import { roomPortOf } from "../support/rooms_server.ts";
import { keptItself, markKept, say } from "../page/harness.ts";
import { reapOwned, stopOwned } from "../support/children.ts";
import { startSessionPeer } from "../support/session_peer.ts";
import { readAnnounced } from "../support/announce.ts";
import { namedRoomRow } from "../support/conversation_row.ts";
import { proveSharedMixedDirect } from "../page/shared_mixed_dm.ts";
import { proveRoomPresence } from "../page/room_presence.ts";
import { proveSharedRoomAuthorityRotation } from "../page/shared_room_authority.ts";
import { proveManagedAccessEditor } from "../page/shared_session_access.ts";
import { proveSharedSessionMoveLayout } from "../page/shared_session_moves.ts";
import { proveReloadMidUpload, proveSharedImage } from "../page/shared_session_files.ts";
import { png } from "../page/png.ts";
import { managedAccessText } from "../../lib/text/managed_access.ts";
import { sessionReconnecting } from "../../lib/text/page.ts";
import { rosterWaiting } from "../../lib/text/conversation.ts";
import { Directory } from "../../lib/room/client.ts";
import { dial } from "../../lib/locator.ts";
import { openRoomsRuntime } from "../../lib/runtime.ts";
import { ask } from "../../lib/ask.ts";
import {
	proveHeldAccessOffline,
	proveSharedDraftConflict,
	proveSharedSessionHalfOpen,
	proveSharedSessionOffline,
	RelayWire,
} from "../page/shared_session_offline.ts";
import { proveSharedRoomLink } from "../page/shared_room_link.ts";
import { proveSharedDirectoryRecovery } from "../page/shared_directory_recovery.ts";
import { proveAttachedSessionHolding, provePrivateRoomHolding } from "../page/holdings.ts";
import { proveSessionReplacement } from "../page/shared_session_reset.ts";
import { loginRelay } from "../support/login_relay.ts";

// The session process and the foreign directory each restart and must come back
// on the port their clients hold, so these two numbers are chosen ahead.
const sessionPort = nonEphemeralPort();
const foreignPort = nonEphemeralPort();
const state = await Deno.makeTempDir({ prefix: "glowcap-managed-shared-page-" });
const serverState = await Deno.makeTempDir({ prefix: "glowcap-managed-shared-server-" });
const front = spawnWeb({
	args: ["--transport=tcp", "0", "0"],
	cwd: ROOT,
	env: {
		GLOWCAP_RELAY_TCP_PEERS: `127.0.0.1:${sessionPort},127.0.0.1:${foreignPort}`,
		GLOWCAP_ROOMS_STATE: serverState,
	},
	stdout: "piped",
	stderr: "inherit",
});
const httpPort = await webPort(front);
const roomPort = await roomPortOf(httpPort);
const ingress = loginRelay(httpPort);
let browser: Awaited<ReturnType<typeof chromium.launch>> | null = null;
const deadline = setTimeout(() => fail("managed shared-page scenario timed out after 180s"), 180_000);
function start() {
	return startSessionPeer(state, [
		"--transport=tcp",
		`--port=${sessionPort}`,
		"--dial-transports=tcp",
		"--local-control",
	], {
		GLOWCAP_ROOMS_SESSION_RELAY_URL: `ws://127.0.0.1:${httpPort}/relay`,
		GLOWCAP_ROOMS_SESSION_RELAY_ALIAS_URL: ingress.relay,
	});
}
async function control(verb: string, named: Record<string, string[]>) {
	const output = await new Deno.Command(SESSION, {
		args: ["control", JSON.stringify({ verb, state, named, arguments: [] })],
		cwd: ROOT,
		stdout: "piped",
		stderr: "piped",
	}).output();
	if (!output.success) fail(`process ${verb} refused: ${new TextDecoder().decode(output.stderr)}`);
	return JSON.parse(new TextDecoder().decode(output.stdout));
}
async function attach(page: Page, link: string, phone = false) {
	const originalSize = page.viewportSize();
	if (phone) await page.setViewportSize({ width: 390, height: 844 });
	await page.goto(`http://127.0.0.1:${httpPort}/`);
	await page.waitForSelector("#sessionSetup");
	await page.fill("#sessionSetupCapability", link);
	if (phone) await proveRefusedAttachFocus(page);
	const checkHandoff = await watchAttachHandoff(page);
	await Promise.all([page.waitForNavigation(), page.click("#sessionAttach")]);
	await checkHandoff();
	if (phone && originalSize) await page.setViewportSize(originalSize);
	await namedRoomRow(page, "mirror-one").waitFor();
	await namedRoomRow(page, "mirror-one").click();
	await page.waitForSelector("#line:not([disabled])", { timeout: 30_000 }).catch(async () => {
		fail(`managed attachment did not become interactive: ${
			JSON.stringify(
				await page.evaluate(() => ({
					url: location.href,
					text: document.body.innerText.slice(0, 6000),
				})),
			)
		}`);
	});
}
/** How many lines the session records as sent, over every conversation of a
 * snapshot answer: a revision and the workspace's intent. */
function postedLines(answer: Argument): number {
	if (!Array.isArray(answer) || typeof answer[1] !== "string") {
		fail("a session snapshot was not a revision and an intent");
	}
	const intent: { conversations?: { lines?: unknown[] }[] } = JSON.parse(answer[1]);
	return (intent.conversations ?? []).reduce((sum, row) => sum + (row.lines?.length ?? 0), 0);
}
/** Wait for a line in a view. `context` adds what only the caller can read
 * when the wait runs out. */
async function bubble(page: Page, text: string, context?: () => Promise<string>) {
	await page.locator(".bubble").filter({ hasText: text }).first().waitFor({ timeout: 15_000 }).catch(async () =>
		fail(
			`shared line did not project: ${text}; ${context == null ? "" : `${await context()}; `}` +
				`view=${await page.locator("body").innerText()}; ` +
				`draft=${await page.inputValue("#line")}; process=${JSON.stringify(await control("status", {}))}`,
		)
	);
}
try {
	let peer = start();
	const link = await readAnnounced(peer, { token: "ROOMS-SESSION-LISTENING", who: "managed session process" });
	for (const room of ["mirror-one", "mirror-two"]) {
		await control("join", { locator: [`127.0.0.1:${roomPort}`], nick: ["durable-member"], room: [room] });
	}
	browser = await chromium.launch({ args: ["--no-sandbox"] });
	await proveColdWorkspace(browser, httpPort);
	const firstContext = await browser.newContext();
	const secondContext = await browser.newContext();
	let first = await firstContext.newPage();
	const second = await secondContext.newPage();
	const errors: string[] = [];
	const observe = (page: Page) => {
		page.on("pageerror", (error) => errors.push(error.message));
		page.on("console", (message) => console.error("SHARED-CONSOLE", message.text()));
	};
	observe(first);
	observe(second);
	await attach(first, link, true);
	const secondWire = new RelayWire();
	await secondWire.install(second);
	await attach(second, link);
	for (const page of [first, second]) {
		await namedRoomRow(page, "mirror-one").waitFor();
		await namedRoomRow(page, "mirror-two").waitFor();
		const tsHost = await page.evaluate(() =>
			Reflect.get(globalThis, Symbol.for("glowcap.runtime.adapter")) !== undefined
		);
		if (tsHost) fail("managed page opened a TypeScript Host");
	}
	await namedRoomRow(first, "mirror-one").click();
	await first.fill("#line", "shared unfinished draft");
	await second.waitForFunction(() => {
		const line = document.querySelector("#line");
		return line instanceof HTMLTextAreaElement && line.value === "shared unfinished draft";
	}).catch(async () => {
		const views = await Promise.all([first, second].map((page) =>
			page.evaluate(() => {
				const line = document.querySelector("#line");
				return {
					text: document.body.innerText.slice(0, 6000),
					draft: line instanceof HTMLTextAreaElement ? line.value : null,
				};
			})
		));
		fail(`shared draft did not project: ${JSON.stringify({ views, errors, status: await control("status", {}) })}`);
	});
	// Closing the last page drops sessionStorage. A new page must find its
	// saved access and reattach without anyone pasting that link again.
	await first.close();
	first = await firstContext.newPage();
	observe(first);
	await first.goto(`http://127.0.0.1:${httpPort}/`);
	await namedRoomRow(first, "mirror-one").waitFor();
	await first.waitForFunction(() =>
		document.querySelector<HTMLTextAreaElement>("#line")?.value === "shared unfinished draft"
	);
	await say(second, "One managed member, two views");
	for (const page of [first, second]) await bubble(page, "One managed member, two views");
	await proveRoomPresence(browser, httpPort, [first, second]);
	await proveSharedImage(first, second, png).catch(async (error) => {
		console.error("SHARED-FILE-FAILURE", error);
		try {
			for (const [index, page] of [first, second].entries()) {
				const review = page.getByRole("button", { name: "Review", exact: true });
				if (await review.count()) await review.click();
				console.error("SHARED-FILE-VIEW", index + 1, await page.locator("body").innerText());
			}
			console.error("SHARED-FILE-STATUS", JSON.stringify(await control("status", {})));
			const runtime = await openRoomsRuntime({ cleartext: [tcp.plain] });
			try {
				const session = await dial(`127.0.0.1:${sessionPort}`, runtime);
				const workspace = await session.enliven(link);
				console.error(
					"SHARED-FILE-EFFECTS",
					await ask(session, workspace, "effect-inventory", [], "effect inventory did not answer"),
				);
			} finally {
				await runtime.close();
			}
		} catch (diagnostic) {
			console.error("SHARED-FILE-DIAGNOSTIC", diagnostic);
		}
		throw error;
	});
	await proveReloadMidUpload(first, second);
	await second.reload();
	await second.waitForSelector("#line:not([disabled])");
	await bubble(second, "One managed member, two views");
	// A use endpoint does not turn its public inventory into management.
	await first.click("#settingsBtn");
	await first.click("#sessionTab");
	await proveSharedSessionMoveLayout(first);
	await proveAttachedSessionHolding(first, link);
	await provePrivateRoomHolding(first, "mirror-one");
	await first.click("#sessionTab");
	await first.click("#sessionAccessOpen");
	await first.locator(".session-access-modal").getByText(managedAccessText.noControl, { exact: true }).waitFor();
	await first.locator(".session-access-modal").getByRole("button", { name: "Close", exact: true }).click();
	await first.click("#settingsClose");
	const runtime = await openRoomsRuntime({ cleartext: [tcp.plain] });
	const directory = await Directory.connect(`127.0.0.1:${roomPort}`, (address) => dial(address, runtime));
	try {
		await proveSharedRoomLink(directory, [first, second]);
	} finally {
		await directory.close();
		await runtime.close();
	}
	await proveSharedDirectoryRecovery(first, foreignPort);
	await namedRoomRow(first, "mirror-one").click();
	// The other view observes committed selection. Killing the owner before
	// that observation would test an unfinished navigation gesture instead.
	await second.waitForFunction(
		() => {
			const selected = document.querySelector("#roomList li.here .rname");
			const line = document.getElementById("line");
			return selected?.textContent?.trim() === "mirror-one" && line instanceof HTMLTextAreaElement &&
				!line.disabled;
		},
		undefined,
		{ timeout: 30_000 },
	);
	// The actual session process restores its graph, publications and receipts.
	// Each page keeps its place and its draft, says it is reconnecting for as
	// long as the session is gone, and dials the restarted session by itself.
	const draft = "A draft typed before the session went away";
	// Drop this page's connection before the write can reach the old owner.
	// Its replacement restores the room's entrance and acquires a new seat.
	secondWire.cut();
	await second.fill("#line", draft);
	for (const page of [first, second]) await markKept(page);
	await stopOwned(peer);
	for (const page of [first, second]) {
		await page.locator(".session-link-notice").getByText(sessionReconnecting, { exact: true }).waitFor({
			timeout: 30_000,
		}).catch(async () =>
			fail(`a page did not say it was reconnecting: view=${await page.locator("body").innerText()}`)
		);
	}
	secondWire.restore();
	peer = start();
	const restored = await readAnnounced(peer, {
		token: "ROOMS-SESSION-LISTENING",
		who: "reopened managed session process",
	});
	if (restored !== link) fail("managed process publication changed across restart");
	for (const page of [first, second]) {
		await page.locator(".session-link-notice").waitFor({ state: "detached", timeout: 60_000 }).catch(async () =>
			fail(
				`a page did not reconnect: view=${await page.locator("body").innerText()} process=${
					JSON.stringify(await control("status", {}))
				}`,
			)
		);
		await page.waitForSelector("#line:not([disabled])", { timeout: 30_000 });
		if (!await keptItself(page)) fail("a page reloaded instead of reconnecting");
		await bubble(page, "One managed member, two views");
		// The restarted session rejoins the room on its own, after the page is back.
		await page.getByText(rosterWaiting, { exact: true }).waitFor({ state: "detached", timeout: 60_000 }).catch(
			async () =>
				fail(
					`the room did not rejoin after the session restarted: view=${await page.locator("body")
						.innerText()}`,
				),
		);
	}
	if (await second.inputValue("#line") !== draft) fail("the draft did not survive the outage");
	// The draft is the conversation's, so sending it is the one gesture that
	// proves it reached the restarted session, once, for both views.
	await second.press("#line", "Enter");
	// The sending view shows its own line at once and marks it as it settles,
	// so its row says whether the session took the line or a view missed it.
	const sent = async () => {
		const rows = second.locator(".bubble").filter({ hasText: draft });
		const classes = await rows.evaluateAll((found) => found.map((row) => row.className));
		const runtime = await openRoomsRuntime({ cleartext: [tcp.plain] });
		try {
			const session = await dial(`127.0.0.1:${sessionPort}`, runtime);
			const effects = await ask(
				session,
				await session.enliven(link),
				"effect-inventory",
				[],
				"effect inventory did not answer",
			);
			return `the sending view shows ${classes.length} such line: ${JSON.stringify(classes)}; ` +
				`session effects=${JSON.stringify(effects)}`;
		} finally {
			await runtime.close();
		}
	};
	await bubble(first, draft, async () => `the other view; ${await sent()}`);
	await bubble(second, draft, async () => `the sending view; ${await sent()}`);
	await second.waitForFunction(
		() => {
			const line = document.getElementById("line");
			return line instanceof HTMLTextAreaElement && line.value === "";
		},
		undefined,
		{ timeout: 30_000 },
	);
	if (await second.locator(".bubble").filter({ hasText: draft }).count() !== 1) {
		fail("the draft was sent more than once");
	}
	await say(first, "After managed process restart");
	await bubble(second, "After managed process restart");
	await proveSharedSessionOffline(second, secondContext, secondWire, "Typed while this device had no network", first);
	await proveSharedDraftConflict(second, secondContext, secondWire, first, async (text) => {
		const { workspace } = await control("status", {});
		return workspace.conversations.some((row: { id: string; draft: string }) =>
			row.id === workspace.active && row.draft === text
		);
	});
	await proveHeldAccessOffline(
		second,
		secondContext,
		secondWire,
		(await Deno.readTextFile(`${state}/management.sturdyref`)).trim(),
	);
	const reader = await openRoomsRuntime({ cleartext: [tcp.plain] });
	try {
		const session = await dial(`127.0.0.1:${sessionPort}`, reader);
		const workspace = await session.enliven(link);
		await proveSharedSessionHalfOpen(
			second,
			secondWire,
			"Sent over a connection that carried nothing",
			first,
			async () =>
				postedLines(await ask(session, workspace, "snapshot", [], "the session did not answer its snapshot")),
		);
	} finally {
		await reader.close();
	}
	await proveSharedRoomAuthorityRotation(first, async () => {
		const status = await control("status", {});
		console.error("ROOM-AUTHORITY-STATE", JSON.stringify(status));
		const runtime = await openRoomsRuntime({ cleartext: [tcp.plain] });
		try {
			const session = await dial(`127.0.0.1:${sessionPort}`, runtime);
			const workspace = await session.enliven(link);
			const inventory = await ask(session, workspace, "effect-inventory", [], "effect inventory did not answer");
			if (typeof inventory !== "string") throw new Error("effect inventory was not text");
			const effects: { operation: string; status: string; resumable: boolean }[] = JSON.parse(inventory);
			const retained = await Promise.all(
				effects.slice(-8).map(async (effect) => ({
					...effect,
					intent: await ask(
						session,
						workspace,
						"effect-intent",
						[effect.operation],
						"effect intent did not answer",
					),
				})),
			);
			return { status, effectCount: effects.length, lastRetainedEffects: retained };
		} finally {
			await runtime.close();
		}
	});
	await namedRoomRow(first, "mirror-two").click();
	// The host process has no browser cookie. Public ingress must refuse its
	// upgrade, while the configured alias reaches the same registry internally.
	const refusal = await fetch(`${ingress.relay.replace("ws:", "http:")}?rendezvous=${"a".repeat(64)}`, {
		headers: { Upgrade: "websocket" },
		redirect: "manual",
		signal: AbortSignal.timeout(5_000),
	});
	if (refusal.status !== 302) fail(`login ingress did not refuse the unauthenticated upgrade: ${refusal.status}`);
	await refusal.body?.cancel();
	const refusedBeforeDm = ingress.refused;
	await proveSharedMixedDirect(browser, httpPort, [first, second], png, ingress.origin);
	if (ingress.refused !== refusedBeforeDm) fail("the shared DM tried the login-protected public relay");
	await proveManagedAccessEditor(
		browser,
		first,
		httpPort,
		(await Deno.readTextFile(`${state}/management.sturdyref`)).trim(),
	);
	// Destroy only this proof's owned state, as deployment reset session does.
	await stopOwned(peer);
	await Deno.remove(state, { recursive: true });
	await Deno.mkdir(state);
	peer = start();
	const replacement = await readAnnounced(peer, {
		token: "ROOMS-SESSION-LISTENING",
		who: "replacement managed session",
	});
	if (replacement === link) fail("reset did not retire the old session capability");
	await proveSessionReplacement(first, replacement);
	if (errors.length !== 0) fail(`production page errors: ${JSON.stringify(errors)}`);
	console.log(
		"Managed process startup, two production pages, shared drafts, files, cold restart and reset recovery passed.",
	);
} finally {
	clearTimeout(deadline);
	await browser?.close();
	await ingress.close();
	await reapOwned();
	await Deno.remove(state, { recursive: true });
	await Deno.remove(serverState, { recursive: true });
}
