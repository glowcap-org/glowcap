// Every archive process proof exercises the installed service.
import { spawnOwned } from "./children.ts";
import { ARCHIVE, ROOT } from "./paths.ts";

export function startArchivePeer(
	directory: string,
	args: string[],
	stderr: "piped" | "inherit" = "piped",
): Deno.ChildProcess {
	return spawnOwned(ARCHIVE, {
		args: [`--state=${directory}`, ...args],
		cwd: ROOT,
		stdout: "piped",
		stderr,
	});
}
