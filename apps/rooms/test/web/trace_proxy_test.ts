// The page-origin door to the live timeline: `/trace` and `/publish` on the
// web server carry a WebSocket to the endpoint itself, so a browser reaches
// the timeline without knowing the endpoint's own port, which may be
// container-side and unpublished to the browser's host. The endpoint still
// judges every socket: its admission mark and its typed refusal must both
// arrive through the carried leg unchanged.

import { TRACE_REFUSED_CLOSE_CODE } from "../../lib/application_data.ts";
import { assert } from "../assert.ts";
import { ROOT, WEB } from "../support/paths.ts";
import { nonEphemeralPort } from "../../../../bindings/ts/test/ports.ts";
import { until, within } from "../support/wait.ts";
import { roomsTest, waitForHttp } from "../support/rooms_server.ts";
import { spawnOwned, stopOwned } from "../support/children.ts";
import { connectTraceViewer } from "../../lib/trace_view.ts";
import { formatRoomsSturdyref, roomsLocator } from "../../lib/locator.ts";

async function readSwiss(stateDir: string): Promise<string> {
	for (let i = 0; i < 200; i++) {
		try {
			const swiss = (await Deno.readTextFile(`${stateDir}/trace`)).trim();
			if (swiss !== "") return swiss;
		} catch {
			// The server has not written it.
		}
		await new Promise((resolve) => setTimeout(resolve, 100));
	}
	throw new Error("the room server never persisted its trace swiss");
}

/** Open `url`, presenting `swiss` as the first message when there is one
 * (the only place the endpoint reads a producer's capability), and settle with
 * what the far side did first: the first text frame, or the close it answered
 * instead. A refusal can close the socket before the presented swiss is
 * written, which fails that send; the close that follows still carries the
 * far side's code, so the answer is read from it rather than from the error. */
function firstAnswer(
	url: string,
	swiss: string | null = null,
): Promise<{ kind: "message"; text: string } | { kind: "close"; code: number }> {
	return new Promise((resolve) => {
		const socket = new WebSocket(url);
		if (swiss != null) socket.addEventListener("open", () => socket.send(swiss), { once: true });
		socket.addEventListener("message", (event) => {
			resolve({ kind: "message", text: String(event.data) });
			socket.close();
		}, { once: true });
		socket.addEventListener("close", (event) => resolve({ kind: "close", code: event.code }), { once: true });
	});
}

roomsTest("the page origin carries trace sockets, admission and refusal alike", async () => {
	const stateDir = await Deno.makeTempDir();
	// The front advertises a trace route through its own address, so its HTTP port
	// is named before it starts. The room and the trace endpoint choose theirs.
	const httpPort = nonEphemeralPort();
	const web = spawnOwned(WEB, {
		args: ["--transport=tcp", String(httpPort), "0"],
		cwd: ROOT,
		env: {
			GLOWCAP_ROOMS_STATE: stateDir,
			GLOWCAP_ROOMS_CAPABILITIES: "trace",
			GLOWCAP_ROOMS_TRACE_PORT: "0",
			GLOWCAP_ROOMS_TRACE_CONNECT: `ws://127.0.0.1:${httpPort}/trace/captp`,
		},
		stdout: "null",
		stderr: "null",
	});
	try {
		await within(waitForHttp(httpPort), "the web server to serve", 60_000);
		const swiss = await within(readSwiss(stateDir), "the trace swiss", 30_000);

		// A wrong capability's typed refusal crosses the carried leg intact,
		// so the browser can erase a dead secret.
		const refused = await within(
			firstAnswer(`ws://127.0.0.1:${httpPort}/publish`, "cd".repeat(32)),
			"the carried refusal",
			15_000,
		);
		assert(
			refused.kind === "close" && refused.code === TRACE_REFUSED_CLOSE_CODE,
			`expected the endpoint's ${TRACE_REFUSED_CLOSE_CODE} through the origin: ${JSON.stringify(refused)}`,
		);

		// The right capability hears the endpoint's own admission mark.
		const admitted = await within(
			firstAnswer(`ws://127.0.0.1:${httpPort}/publish`, swiss),
			"the carried admission",
			15_000,
		);
		assert(
			admitted.kind === "message" && admitted.text.includes("trace.publish-ready"),
			`expected the admission mark through the origin: ${JSON.stringify(admitted)}`,
		);
		// A capability in the URL is refused outright, even the right one, so no
		// route admits a secret that a proxy log or browser history kept.
		const queried = await within(
			firstAnswer(`ws://127.0.0.1:${httpPort}/publish?cap=${swiss}`, swiss),
			"the carried query refusal",
			15_000,
		);
		assert(
			queried.kind === "close" && queried.code === TRACE_REFUSED_CLOSE_CODE,
			`expected a query to be refused through the origin: ${JSON.stringify(queried)}`,
		);
		const response = await fetch(`http://127.0.0.1:${httpPort}/trace/locator`);
		assert(response.ok, "the current trace locator is discoverable without its capability");
		const locator = roomsLocator((await response.text()).trim());
		const link = formatRoomsSturdyref(locator, swiss);
		const deniedLink = formatRoomsSturdyref(locator, "cd".repeat(32));
		let denied = false;
		let leaked = 0;
		try {
			const invalid = await within(
				connectTraceViewer(deniedLink, () => {
					leaked++;
				}),
				"the carried capability refusal",
				15_000,
			);
			await invalid.close();
		} catch (error) {
			if (String(error).includes("timed out")) throw error;
			denied = true;
		}
		assert(denied, "opening the carried byte channel granted trace authority");
		assert(leaked === 0, "a refused viewer received trace records");
		const records: Record<string, unknown>[] = [];
		const subscription = await within(
			connectTraceViewer(link, (record) => records.push(record)),
			"the advertised trace channel",
			15_000,
		);
		try {
			await until(
				() => records.some((record) => record.kind === "trace.replay-end"),
				"the carried replay",
				5_000,
			);
		} finally {
			await subscription.close();
		}
	} finally {
		await stopOwned(web);
		await Deno.remove(stateDir, { recursive: true });
	}
});
