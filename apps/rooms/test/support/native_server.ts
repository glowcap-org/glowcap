// The installed server, owned by a demo or compatibility scenario. Members
// remain independent clients; no TypeScript server runs inside the harness.
import { spawnOwned, stopOwned } from "./children.ts";
import { readAnnounce, ROOT, SERVER } from "./rooms_server.ts";

export interface ServerEndpoint {
	locator: string;
	close(): Promise<void>;
}

export async function startServer(
	args: string[] = ["--transport=tcp", "--port=0"],
	deadlineMs = 20_000,
): Promise<ServerEndpoint> {
	const proc = spawnOwned(SERVER, { args, cwd: ROOT, stdout: "piped", stderr: "inherit" });
	try {
		const announced = await readAnnounce(proc, deadlineMs);
		const locator = /^\d+$/.test(announced) ? `127.0.0.1:${announced}` : announced;
		return { locator, close: () => stopOwned(proc) };
	} catch (error) {
		await stopOwned(proc);
		throw error;
	}
}
