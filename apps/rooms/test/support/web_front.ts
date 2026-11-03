// Shipped-page proofs keep one prepared generation for the entire journey.
// Source compilation and refresh are exercised by the web process tests.
import { ROOT, SERVER, WEB } from "./paths.ts";
import { drainStdout, readAnnouncedPort } from "./announce.ts";
import { spawnOwned } from "./children.ts";

export function spawnWeb(options: Deno.CommandOptions = {}): Deno.ChildProcess {
	const assets = Deno.realPathSync(`${ROOT}zig-out/rooms-web/current`);
	return spawnOwned(WEB, {
		...options,
		args: ["--prepared", `--assets=${assets}`, `--server=${SERVER}`, ...options.args ?? []],
	});
}

/** The HTTP port a front started with port 0 bound, read from its announcement.
 * The child's stdout must be piped. The rest of its stdout is drained, so a
 * caller reads no stdout of its own after this. */
export async function webPort(proc: Deno.ChildProcess): Promise<number> {
	const port = await readAnnouncedPort(proc, { token: "ROOMS-WEB-LISTENING", who: "rooms-web" });
	drainStdout(proc);
	return port;
}
