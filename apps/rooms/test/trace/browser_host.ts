import { scrapeTraceSturdyref, tracePortOf } from "./viewer.ts";
import { tracePublishUrlOf } from "../../lib/trace_view.ts";
import { spawnOwned, stopOwned } from "../support/children.ts";

const SERVER = Deno.env.get("GLOWCAP_ROOMS_SERVER_BIN") ??
	new URL("../../../../zig-out/libexec/rooms-server", import.meta.url).pathname;
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
	args: ["--transport=tcp", "--port=0", "--trace", "--trace-port=0"],
	stdout: "piped",
	stderr: "piped",
});

try {
	const [sturdyref] = await Promise.all([
		scrapeTraceSturdyref(server.stderr),
		awaitServerAnnouncement(server.stdout),
	]);
	console.log(JSON.stringify({
		port: tracePortOf(sturdyref),
		sturdyref,
		publish: tracePublishUrlOf(sturdyref),
	}));

	const status = await server.status;
	throw new Error(`rooms-server exited unexpectedly with status ${status.code}`);
} finally {
	await stopOwned(server);
}
