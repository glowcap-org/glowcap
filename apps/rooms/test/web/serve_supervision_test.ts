// Room-server supervision: refusal, attachment to an existing child, and
// takeover when the owning web front exits. Kept separate from the relay and
// asset tests so each deterministic process stays inside its 30-second bound.

import { spawnOwned, stopOwned } from "../support/children.ts";
import { freePort } from "../support/rooms_server.ts";
import { delay, reachRoomThroughRelay, ROOT, spawnWeb, waitForIndex, WEB } from "./serve_harness.ts";

function assert(condition: unknown, message: string): asserts condition {
	if (!condition) throw new Error(message);
}

Deno.test("the web front reports a room server that cannot start, and stops", async () => {
	// Startup must preserve the host storage refusal through child retirement.
	const dir = await Deno.makeTempDir();
	try {
		await Deno.writeTextFile(
			`${dir}/rooms.json`,
			JSON.stringify({ version: 1, identitySeed: "zz", roomLinkSecret: "zz", linkedRooms: [] }) + "\n",
		);
		const proc = spawnOwned(WEB, {
			args: ["--transport=tcp", String(freePort()), String(freePort())],
			cwd: ROOT,
			env: { GLOWCAP_ROOMS_STATE: dir },
			stdout: "piped",
			stderr: "piped",
		});
		const [status, said] = await Promise.all([
			proc.status,
			new Response(proc.stderr).text(),
			new Response(proc.stdout).text(),
		]);
		assert(!status.success, `the front exited ${status.code} when its room server could not start`);
		assert(
			said.includes("the server document is unusable"),
			`the front did not say why it stopped: ${said}`,
		);
	} finally {
		await Deno.remove(dir, { recursive: true });
	}
});

Deno.test("rooms web UI attaches to a room server already on its port", async () => {
	// Sharing a room port must not be fatal: the second instance's child cannot
	// bind, so the second instance attaches to the first.
	const roomPort = freePort();
	const httpFirst = freePort();
	const httpSecond = freePort();
	const first = spawnWeb(httpFirst, roomPort);
	let second: Deno.ChildProcess | null = null;
	try {
		await waitForIndex(httpFirst); // the first now owns roomPort
		second = spawnWeb(httpSecond, roomPort);
		const page = await waitForIndex(httpSecond);
		assert(
			page.includes("glowcap rooms"),
			"the attached instance should serve the page",
		);
		// A peer dialing through the second instance reaches the shared room.
		await reachRoomThroughRelay(httpSecond, roomPort);
	} finally {
		for (const proc of [second, first]) {
			if (proc) await stopOwned(proc);
		}
	}
});

Deno.test("rooms web UI takes over when an attached room server dies", async () => {
	// Attach must not leave the second instance forever pointing at a dead locator
	// after the owning rooms-web exits and tears down the shared child.
	const roomPort = freePort();
	const httpFirst = freePort();
	const httpSecond = freePort();
	const first = spawnWeb(httpFirst, roomPort);
	let second: Deno.ChildProcess | null = null;
	try {
		await waitForIndex(httpFirst);
		second = spawnWeb(httpSecond, roomPort);
		await waitForIndex(httpSecond);

		try {
			first.kill("SIGINT");
		} catch {
			// Already gone.
		}
		await first.status;

		// The second must take over the room and stay reachable through its relay.
		const deadline = Date.now() + 15_000;
		let reached = false;
		let lastError: unknown;
		while (Date.now() < deadline) {
			try {
				await reachRoomThroughRelay(httpSecond, roomPort, deadline);
				reached = true;
				break;
			} catch (err) {
				lastError = err;
				await delay(250);
			}
		}
		assert(
			reached,
			`attached web did not take over after owner exit: ${lastError}`,
		);
	} finally {
		for (const proc of [second, first]) {
			if (proc) await stopOwned(proc);
		}
	}
});
