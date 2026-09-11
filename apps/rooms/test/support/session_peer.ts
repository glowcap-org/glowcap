// Every session-peer proof exercises the installed native executable, the
// same one the deployment runs.
import { spawnOwned } from "./children.ts";
const ROOT = new URL("../../../../", import.meta.url).pathname;
export function startSessionPeer(
	directory: string,
	args: string[],
	env: Record<string, string> = {},
	stderr: "piped" | "inherit" = "inherit",
): Deno.ChildProcess {
	return spawnOwned(Deno.env.get("GLOWCAP_ROOMS_SESSION_TEST_BIN") ?? `${ROOT}zig-out/bin/rooms-session`, {
		args: [`--state=${directory}`, ...args],
		cwd: ROOT,
		env: { LD_LIBRARY_PATH: `${ROOT}zig-out/lib`, ...env },
		stdout: "piped",
		stderr,
	});
}
