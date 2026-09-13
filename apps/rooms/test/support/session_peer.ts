// Every session-peer proof exercises the installed native executable, the
// same one the deployment runs.
import { spawnOwned } from "./children.ts";
import { ROOT, SESSION } from "./paths.ts";

export function startSessionPeer(
	directory: string,
	args: string[],
	env: Record<string, string> = {},
	stderr: "piped" | "inherit" = "inherit",
): Deno.ChildProcess {
	return spawnOwned(SESSION, {
		args: [`--state=${directory}`, ...args],
		cwd: ROOT,
		env,
		stdout: "piped",
		stderr,
	});
}
