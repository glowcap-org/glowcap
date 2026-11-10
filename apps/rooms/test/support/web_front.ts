// Shipped-page proofs keep one prepared generation for the entire journey.
// Source compilation and refresh are exercised by the web process tests.
import { ROOT, SERVER, WEB } from "./paths.ts";
import { Announcements, asPort, exitedBeforeAnnouncing } from "./announce.ts";
import { spawnOwned } from "./children.ts";

export function spawnWeb(options: Deno.CommandOptions = {}): Deno.ChildProcess {
	const assets = Deno.realPathSync(`${ROOT}zig-out/rooms-web/current`);
	return spawnOwned(WEB, {
		...options,
		args: ["--prepared", `--assets=${assets}`, `--server=${SERVER}`, ...options.args ?? []],
	});
}

const announced = new WeakMap<Deno.ChildProcess, Announcements>();

/** The front's `ROOMS-*` lines: its own port and the links of the directory it
 * runs, which it prints in its startup block. One reader owns the child's
 * stdout for its whole life, so the child's stdout must be piped and a caller
 * reads no stdout of its own. */
export function webAnnouncements(proc: Deno.ChildProcess): Announcements {
	const kept = announced.get(proc);
	if (kept != null) return kept;
	const made = new Announcements(proc.stdout);
	announced.set(proc, made);
	return made;
}

/** The HTTP port a front started with port 0 bound, read from its announcement. */
export async function webPort(proc: Deno.ChildProcess): Promise<number> {
	const lines = webAnnouncements(proc);
	let port: string;
	try {
		port = await lines.line("ROOMS-WEB-LISTENING", "rooms-web");
	} catch (error) {
		throw lines.ended ? await exitedBeforeAnnouncing(proc, "rooms-web") : error;
	}
	return asPort(port, "rooms-web");
}
