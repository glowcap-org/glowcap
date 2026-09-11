// The actual native IRC front, owned and reaped even when a scenario fails.
import { spawnOwned, stopOwned } from "../support/children.ts";
import { ROOT, within } from "../support/rooms_server.ts";
const FRONT = Deno.env.get("GLOWCAP_ROOMS_IRC_FRONT_BIN") || `${ROOT}zig-out/bin/rooms-irc-front`;
export async function startFront(directory: string, args: string[] = []) {
	const proc = spawnOwned(FRONT, {
		args: [`--directory=${directory}`, "--port=0", "--server-name=rooms.test", ...args],
		cwd: ROOT,
		stdout: "piped",
		stderr: "piped",
	});
	const diagnostic = new Response(proc.stderr).text();
	let closed = false;
	const close = async () => {
		if (closed) return;
		closed = true;
		await stopOwned(proc);
		const status = await proc.status;
		const errors = await diagnostic;
		if (Deno.env.get("GLOWCAP_IRC_FRONT_TEST_DIAGNOSTICS")) console.error(errors);
		if (!status.success) throw new Error(`native IRC front exited ${status.code}: ${errors}`);
	};
	try {
		const reader = proc.stdout.getReader();
		try {
			let text = "";
			while (true) {
				const next = await within(reader.read(), "native IRC front announcement");
				if (next.done) throw new Error("IRC front exited before announcement");
				text += new TextDecoder().decode(next.value);
				const match = text.match(/ROOMS-IRC-FRONT-LISTENING (\d+) \S+ DM (\S+)\n/);
				if (match) return { port: Number(match[1]), dm: match[2], close, [Symbol.asyncDispose]: close };
			}
		} finally {
			reader.releaseLock();
		}
	} catch (error) {
		await close();
		throw error;
	}
}
