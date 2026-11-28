// A directory, a human sender, and an independently granted bot session.
// The first room requires operator review. The second has no operator online.
import { chromium } from "playwright";
import { nonEphemeralPort } from "../../../../bindings/ts/test/ports.ts";
import { provePrivateBotInvitation } from "../page/shared_bot_invitation.ts";
import { readAnnounced } from "../support/announce.ts";
import { reapOwned } from "../support/children.ts";
import { ROOT, SESSION } from "../support/paths.ts";
import { roomPortOf } from "../support/rooms_server.ts";
import { startSessionPeer } from "../support/session_peer.ts";
import { spawnWeb, webPort } from "../support/web_front.ts";

const sessionPort = nonEphemeralPort();
const state = await Deno.makeTempDir({ prefix: "rooms-bot-invitation-" });
const server = state + "/directory";
await Deno.mkdir(server);
const session = state + "/member";
await Deno.mkdir(session);
async function control(verb: string, named: Record<string, string[]> = {}) {
	const output = await new Deno.Command(SESSION, {
		args: ["control", JSON.stringify({ verb, state: session, named, arguments: [] })],
		cwd: ROOT,
		stdout: "piped",
		stderr: "piped",
	}).output();
	if (!output.success) throw new Error("session refused " + verb + ": " + new TextDecoder().decode(output.stderr));
	return JSON.parse(new TextDecoder().decode(output.stdout));
}
let browser: Awaited<ReturnType<typeof chromium.launch>> | undefined;
try {
	const front = spawnWeb({
		args: ["--transport=tcp", "0", "0"],
		cwd: ROOT,
		env: {
			GLOWCAP_RELAY_TCP_PEERS: "127.0.0.1:" + sessionPort,
			GLOWCAP_ROOMS_STATE: server,
		},
		stdout: "piped",
		stderr: "inherit",
	});
	const port = await webPort(front);
	const roomPort = await roomPortOf(port);
	const peer = startSessionPeer(session, [
		"--transport=tcp",
		"--port=" + sessionPort,
		"--dial-transports=tcp",
		"--local-control",
	], {
		GLOWCAP_ROOMS_SESSION_RELAY_URL: "ws://127.0.0.1:" + port + "/relay",
	});
	const access = await readAnnounced(peer, { token: "ROOMS-SESSION-LISTENING", who: "bot session" });
	await control("join", { locator: ["127.0.0.1:" + roomPort], nick: ["scout"], "exact-nick": ["true"] });
	const bot = await control("access-issue", { label: ["bot"], rights: ["collaborator"] });
	browser = await chromium.launch({ args: ["--no-sandbox"] });
	const operator = await browser.newPage();
	await operator.goto("http://127.0.0.1:" + port + "/");
	await operator.fill("#sessionSetupCapability", access);
	await Promise.all([operator.waitForNavigation(), operator.click("#sessionAttach")]);
	await operator.locator("#sessionSetup").waitFor({ state: "detached" });
	await provePrivateBotInvitation(browser, operator, port, state, bot.link, async () => {
		const { workspace } = await control("status");
		const home = workspace.directories.find((row: { home: boolean }) => row.home);
		if (!home) throw new Error("bot session has no registered home directory");
		await control("invitations", { directory: [home.id], mode: ["auto"] });
	});
	console.log("Reviewed and unattended invitations seated the bot in two private rooms.");
} finally {
	await browser?.close();
	await reapOwned();
	await Deno.remove(state, { recursive: true });
}
