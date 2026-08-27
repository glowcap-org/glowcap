// The page-origin door to the live timeline: `/viz` and `/publish` on the
// web server carry a WebSocket to the endpoint itself, so a browser reaches
// the timeline without knowing the endpoint's own port — which may be
// container-side and unpublished to the browser's host. The endpoint still
// judges every socket: its admission mark and its typed refusal must both
// arrive through the carried leg unchanged.

import { publishViz, VIZ_REFUSED_CLOSE_CODE, vizCapUrl } from "../lib/viz_publish.ts";
import { assert, freePort, roomsTest, ROOT, waitForHttp, within } from "./support/rooms_server.ts";
import { spawnOwned, stopOwned } from "./support/children.ts";

const WEB = new URL("../web/serve.ts", import.meta.url).pathname;

async function readSwiss(stateDir: string): Promise<string> {
	for (let i = 0; i < 200; i++) {
		try {
			const swiss = (await Deno.readTextFile(`${stateDir}/viz`)).trim();
			if (swiss !== "") return swiss;
		} catch {
			// Not written yet.
		}
		await new Promise((resolve) => setTimeout(resolve, 100));
	}
	throw new Error("the room server never persisted its viz swiss");
}

/** Open `url` and settle with what the far side did first: the first text
 * frame, or the close it answered instead. */
function firstAnswer(url: string): Promise<{ kind: "message"; text: string } | { kind: "close"; code: number }> {
	return new Promise((resolve, reject) => {
		const socket = new WebSocket(url);
		socket.addEventListener("message", (event) => {
			resolve({ kind: "message", text: String(event.data) });
			socket.close();
		}, { once: true });
		socket.addEventListener("close", (event) => resolve({ kind: "close", code: event.code }), { once: true });
		socket.addEventListener("error", () => reject(new Error("the socket failed before answering")), {
			once: true,
		});
	});
}

roomsTest("the page origin carries viz sockets, admission and refusal alike", async () => {
	const stateDir = await Deno.makeTempDir();
	const httpPort = freePort();
	const roomPort = freePort();
	const vizPort = freePort();
	const web = spawnOwned("deno", {
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
			...Deno.env.toObject(),
			PANCAKE_ROOMS_STATE: stateDir,
			PANCAKE_ROOMS_VIZ: "1",
			PANCAKE_ROOMS_VIZ_PORT: String(vizPort),
		},
		stdout: "null",
		stderr: "null",
	});
	try {
		await within(waitForHttp(httpPort), "the web server to serve", 60_000);
		const swiss = await within(readSwiss(stateDir), "the viz swiss", 30_000);

		// A wrong capability's typed refusal crosses the carried leg intact,
		// which is what erases a dead secret in the browser.
		const refused = await within(
			firstAnswer(vizCapUrl(`ws://127.0.0.1:${httpPort}/publish`, "cd".repeat(32))),
			"the carried refusal",
			15_000,
		);
		assert(
			refused.kind === "close" && refused.code === VIZ_REFUSED_CLOSE_CODE,
			`expected the endpoint's ${VIZ_REFUSED_CLOSE_CODE} through the origin: ${JSON.stringify(refused)}`,
		);

		// The right capability hears the endpoint's own admission mark.
		const admitted = await within(
			firstAnswer(vizCapUrl(`ws://127.0.0.1:${httpPort}/publish`, swiss)),
			"the carried admission",
			15_000,
		);
		assert(
			admitted.kind === "message" && admitted.text.includes("trace.publish-ready"),
			`expected the admission mark through the origin: ${JSON.stringify(admitted)}`,
		);
		const held: { publisher?: ReturnType<typeof publishViz> } = {};
		await within(
			new Promise<void>((resolve, reject) => {
				held.publisher = publishViz(`ws://127.0.0.1:${httpPort}/viz`, {
					cap: swiss,
					onStatus: (connected) => {
						if (connected) resolve();
					},
					onRefused: reject,
				});
			}),
			"the publisher admission through the origin",
			15_000,
		);
		held.publisher?.stop();

		// The viewer path is the same door at `/viz`.
		const viewer = await within(
			firstAnswer(vizCapUrl(`ws://127.0.0.1:${httpPort}/viz`, "cd".repeat(32))),
			"the carried viewer refusal",
			15_000,
		);
		assert(
			viewer.kind === "close" && viewer.code === VIZ_REFUSED_CLOSE_CODE,
			`expected the viewer leg's refusal through the origin: ${JSON.stringify(viewer)}`,
		);
	} finally {
		await stopOwned(web);
		await Deno.remove(stateDir, { recursive: true });
	}
});
