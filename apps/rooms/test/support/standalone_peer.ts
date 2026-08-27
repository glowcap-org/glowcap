import { spawnOwned } from "./children.ts";
import { ROOT } from "./rooms_server.ts";

const ROOMS_SESSION_PEER = new URL("../../session/main.ts", import.meta.url).pathname;

function parentDirectory(path: string): string {
	const slash = path.lastIndexOf("/");
	return slash < 0 ? "." : slash === 0 ? "/" : path.slice(0, slash);
}

export function startRoomsSessionPeer(
	directory: string,
	port: number,
	checkpoint?: string,
	readinessFile?: string,
): Deno.ChildProcess {
	const readinessDirectory = readinessFile == null ? undefined : parentDirectory(readinessFile);
	const readable = [ROOT, directory, ...(readinessDirectory == null ? [] : [readinessDirectory])].join(",");
	const writable = [directory, ...(readinessDirectory == null ? [] : [readinessDirectory])].join(",");
	return spawnOwned("deno", {
		args: [
			"run",
			"--allow-ffi",
			"--unstable-ffi",
			`--allow-read=${readable}`,
			`--allow-write=${writable}`,
			"--allow-net=127.0.0.1",
			"--allow-env=PANCAKE_LIB_DIR",
			ROOMS_SESSION_PEER,
			`--state=${directory}`,
			...(checkpoint == null ? [] : [`--checkpoint=${checkpoint}`]),
			...(readinessFile == null ? [] : [`--readiness-file=${readinessFile}`]),
			"--transport=tcp",
			`--port=${port}`,
		],
		cwd: ROOT,
		stdout: "piped",
		stderr: "piped",
	});
}

export async function announcedSturdyref(
	process: Deno.ChildProcess,
	token: string,
	label: string,
): Promise<string> {
	const reader = process.stdout.getReader();
	const deadline = Date.now() + 10_000;
	const decoder = new TextDecoder();
	let text = "";
	try {
		while (Date.now() < deadline) {
			const remaining = deadline - Date.now();
			let timeout: ReturnType<typeof setTimeout> | undefined;
			const chunk = await Promise.race([
				reader.read(),
				new Promise<undefined>((resolve) => timeout = setTimeout(() => resolve(undefined), remaining)),
			]);
			clearTimeout(timeout);
			if (chunk == null || chunk.done) break;
			text += decoder.decode(chunk.value, { stream: true });
			const match = text.match(new RegExp(`${token} (\\S+)`));
			if (match != null) return match[1];
		}
	} finally {
		reader.releaseLock();
	}
	throw new Error(`${label} did not announce before its deadline`);
}
