// Every archive process proof exercises the installed native service.
import { spawnOwned } from "./children.ts";
const ROOT = new URL("../../../../", import.meta.url).pathname;
export function startArchivePeer(
	directory: string,
	args: string[],
	stderr: "piped" | "inherit" = "piped",
): Deno.ChildProcess {
	return spawnOwned(Deno.env.get("GLOWCAP_ROOMS_ARCHIVE_TEST_BIN") ?? `${ROOT}zig-out/bin/rooms-archive`, {
		args: [`--state=${directory}`, ...args],
		cwd: ROOT,
		stdout: "piped",
		stderr,
	});
}
