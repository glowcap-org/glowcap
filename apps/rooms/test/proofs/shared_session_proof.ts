import { spawnWeb } from "../support/web_front.ts";
/// <reference lib="dom" />
// Two production pages consume one managed process workspace. Setup selects a
// strong use field; reload and process restart must recover that exact owner.
import { chromium, type Page } from "playwright";
import { fail, freePort, ROOT, say, waitForHttp } from "../page/harness.ts";
import { SESSION } from "../support/paths.ts";
import { reapOwned, stopOwned } from "../support/children.ts";
import { startSessionPeer } from "../support/session_peer.ts";
import { announcedSturdyref } from "../support/standalone_peer.ts";
import { namedRoomRow } from "../support/conversation_row.ts";
import { proveSharedMixedDirect } from "../page/shared_mixed_dm.ts";
import { proveRoomPresence } from "../page/room_presence.ts";
import { proveSharedRoomAuthorityRotation } from "../page/shared_room_authority.ts";
import { proveManagedAccessEditor } from "../page/shared_session_access.ts";
import { proveSharedSessionMoveLayout } from "../page/shared_session_moves.ts";
import { proveReloadMidUpload, proveSharedImage } from "../page/shared_session_files.ts";
import { png } from "../page/png.ts";
import { managedAccessText } from "../../lib/text/managed_access.ts";
import { Directory } from "../../lib/room/client.ts";
import { dial } from "../../lib/locator.ts";
import { openRoomsRuntime } from "../../lib/runtime.ts";
import { ask } from "../../lib/ask.ts";
import { proveSharedRoomLink } from "../page/shared_room_link.ts";
import { proveSharedDirectoryRecovery } from "../page/shared_directory_recovery.ts";
import { proveAttachedSessionHolding, provePrivateRoomHolding } from "../page/holdings.ts";
import { proveSessionReplacement } from "../page/shared_session_reset.ts";
import { loginRelay } from "../support/login_relay.ts";

const httpPort = freePort();
const roomPort = freePort();
const sessionPort = freePort();
const foreignPort = freePort();
const ingress = loginRelay(httpPort);
const state = await Deno.makeTempDir({ prefix: "glowcap-managed-shared-page-" });
const serverState = await Deno.makeTempDir({ prefix: "glowcap-managed-shared-server-" });
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
async function attach(page: Page, link: string) {
	await page.goto(`http://127.0.0.1:${httpPort}/`);
	await page.waitForSelector("#sessionSetup");
	await page.fill("#sessionSetupCapability", link);
	await Promise.all([page.waitForNavigation(), page.click("#sessionAttach")]);
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
async function bubble(page: Page, text: string) {
	await page.locator(".bubble").filter({ hasText: text }).first().waitFor({ timeout: 15_000 }).catch(async () =>
		fail(
			`shared line did not project: ${text}; view=${await page.locator("body").innerText()}; ` +
				`draft=${await page.inputValue("#line")}; process=${JSON.stringify(await control("status", {}))}`,
		)
	);
}
try {
	spawnWeb({
		args: ["--transport=tcp", String(httpPort), String(roomPort)],
		cwd: ROOT,
		env: {
			GLOWCAP_RELAY_TCP_PEERS: `127.0.0.1:${sessionPort},127.0.0.1:${foreignPort}`,
			GLOWCAP_ROOMS_STATE: serverState,
		},
		stdout: "piped",
		stderr: "inherit",
	});
	await waitForHttp(httpPort);
	let peer = start();
	const link = await announcedSturdyref(peer, "ROOMS-SESSION-LISTENING", "managed session process");
	for (const room of ["mirror-one", "mirror-two"]) {
		await control("join", { locator: [`127.0.0.1:${roomPort}`], nick: ["durable-member"], room: [room] });
	}
	browser = await chromium.launch({ args: ["--no-sandbox"] });
	const firstContext = await browser.newContext();
	const secondContext = await browser.newContext();
	const first = await firstContext.newPage();
	const second = await secondContext.newPage();
	const errors: string[] = [];
	for (const page of [first, second]) {
		page.on("pageerror", (error) => errors.push(error.message));
		page.on("console", (message) => console.error("SHARED-CONSOLE", message.text()));
	}
	await attach(first, link);
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
	await second.waitForFunction(() =>
		(document.querySelector("#line") as HTMLTextAreaElement)?.value === "shared unfinished draft"
	).catch(async () => {
		const views = await Promise.all([first, second].map((page) =>
			page.evaluate(() => ({
				text: document.body.innerText.slice(0, 6000),
				draft: (document.querySelector("#line") as HTMLTextAreaElement)?.value,
			}))
		));
		fail(`shared draft did not project: ${JSON.stringify({ views, errors, status: await control("status", {}) })}`);
	});
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
			const runtime = await openRoomsRuntime();
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
	const runtime = await openRoomsRuntime();
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
			return selected?.textContent?.trim() === "mirror-one" &&
				(document.getElementById("line") as HTMLTextAreaElement | null)?.disabled === false;
		},
		undefined,
		{ timeout: 30_000 },
	);
	// The actual session process restores its graph, publications and receipts.
	await stopOwned(peer);
	peer = start();
	const restored = await announcedSturdyref(peer, "ROOMS-SESSION-LISTENING", "reopened managed session process");
	if (restored !== link) fail("managed process publication changed across restart");
	for (const page of [first, second]) {
		await page.reload();
		await page.waitForSelector("#line:not([disabled])", { timeout: 30_000 }).catch(async () =>
			fail(
				`process restart view did not settle: view=${await page.locator("body").innerText()} process=${
					JSON.stringify(await control("status", {}))
				}`,
			)
		);
		await bubble(page, "One managed member, two views");
	}
	await say(first, "After managed process restart");
	await bubble(second, "After managed process restart");
	await proveSharedRoomAuthorityRotation(first);
	await namedRoomRow(first, "mirror-two").click();
	// The native process has no browser cookie. Public ingress must refuse its
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
		(await Deno.readTextFile(`${state}/control.sturdyref`)).trim(),
	);
	// Destroy only this proof's owned state, as deployment reset session does.
	await stopOwned(peer);
	await Deno.remove(state, { recursive: true });
	await Deno.mkdir(state);
	peer = start();
	const replacement = await announcedSturdyref(peer, "ROOMS-SESSION-LISTENING", "replacement managed session");
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
