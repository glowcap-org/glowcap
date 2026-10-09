// Shipped-page proofs keep one prepared generation for the entire journey.
// Source compilation and refresh are exercised by the web process tests.
import { ROOT, SERVER, WEB } from "./paths.ts";
import { spawnOwned } from "./children.ts";

export function spawnWeb(options: Deno.CommandOptions = {}): Deno.ChildProcess {
	const assets = Deno.realPathSync(`${ROOT}zig-out/rooms-web/current`);
	return spawnOwned(WEB, {
		...options,
		args: ["--prepared", `--assets=${assets}`, `--server=${SERVER}`, ...options.args ?? []],
	});
}
