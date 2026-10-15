// The actual Rooms IRC server, owned and reaped even when a scenario fails.
import { spawnOwned, stopOwned } from "../support/children.ts";
import { IRC_SERVER, ROOT } from "../support/paths.ts";
import { within } from "../support/wait.ts";
export async function startIrcServer(directory: string, args: string[] = []) {
	const proc = spawnOwned(IRC_SERVER, {
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
		if (Deno.env.get("GLOWCAP_IRC_SERVER_TEST_DIAGNOSTICS")) console.error(errors);
		if (!status.success) throw new Error(`Rooms IRC server exited ${status.code}: ${errors}`);
	};
	try {
		const reader = proc.stdout.getReader();
		try {
			let text = "";
			while (true) {
				const next = await within(reader.read(), "Rooms IRC server announcement");
				if (next.done) throw new Error("IRC server exited before announcement");
				text += new TextDecoder().decode(next.value);
				const match = text.match(/ROOMS-IRC-SERVER-LISTENING (\d+) \S+ DM (\S+)\n/);
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
