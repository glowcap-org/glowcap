import { scrapeVizSturdyref, vizPortOf, vizUrlOf } from "./viewer.ts";
import { spawnOwned, stopOwned } from "../support/children.ts";

const SERVER = Deno.env.get("GLOWCAP_ROOMS_SERVER_BIN") ??
	new URL("../../../../zig-out/bin/rooms-server", import.meta.url).pathname;
const MAX_ANNOUNCEMENT_BYTES = 8 * 1024;

async function awaitServerAnnouncement(stdout: ReadableStream<Uint8Array>): Promise<void> {
	const decoder = new TextDecoder();
	let pending = "";
	for await (const chunk of stdout) {
		await Deno.stderr.write(chunk).catch(() => {});
		pending += decoder.decode(chunk, { stream: true });
		if (pending.length > MAX_ANNOUNCEMENT_BYTES) {
			throw new Error("rooms-server announcement exceeded its bound");
		}
		const newline = pending.indexOf("\n");
		if (newline === -1) continue;
		const line = pending.slice(0, newline).trim();
		if (!line.startsWith("ROOMS-SERVER-LISTENING ")) {
			throw new Error(`rooms-server made an invalid announcement: ${line}`);
		}
		return;
	}
	throw new Error("rooms-server exited before announcing its listener");
}

const server = spawnOwned(SERVER, {
	args: ["--transport=tcp", "--port=0", "--viz", "--viz-port=0"],
	stdout: "piped",
	stderr: "piped",
});

try {
	const [sturdyref] = await Promise.all([
		scrapeVizSturdyref(server.stderr),
		awaitServerAnnouncement(server.stdout),
	]);
	const publishUrl = new URL(vizUrlOf(sturdyref));
	publishUrl.pathname = "/publish";
	console.log(JSON.stringify({
		port: vizPortOf(sturdyref),
		sturdyref,
		publish: publishUrl.href,
	}));

	const status = await server.status;
	throw new Error(`rooms-server exited unexpectedly with status ${status.code}`);
} finally {
	await stopOwned(server);
}
