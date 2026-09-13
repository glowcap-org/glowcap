// Connection supervision for standalone servers exercised by tests.

import { retainCleanupFailures, secondaryFailures, type Session } from "@glowcap/runtime";
import { routinePeerDisconnect } from "./session_failure.ts";

export interface ClosingServer extends AsyncIterable<Session> {
	close(): void;
}

function failureText(error: unknown): string {
	return error instanceof Error ? error.message : String(error);
}

async function serveConnection(session: Session): Promise<void> {
	try {
		await session.serve();
	} catch (error) {
		throw await retainCleanupFailures(error, [() => session.close()]);
	}
	await session.close();
}

function reportConnectionFailure(label: string, error: unknown): void {
	if (!routinePeerDisconnect(error)) {
		console.error(`${label}: a peer connection ended unexpectedly: ${failureText(error)}`);
	}
	for (const cleanup of secondaryFailures(error)) {
		console.error(`${label}: closing that connection also failed: ${failureText(cleanup)}`);
	}
}

export async function serveStandalone(server: ClosingServer, label: string): Promise<void> {
	const stop = () => server.close();
	Deno.addSignalListener("SIGINT", stop);
	Deno.addSignalListener("SIGTERM", stop);
	try {
		for await (const session of server) {
			// One failed client must not tear down the listener. Its detached task
			// still owns both the primary failure and every close consequence.
			void serveConnection(session).catch((error) => reportConnectionFailure(label, error));
		}
	} finally {
		Deno.removeSignalListener("SIGINT", stop);
		Deno.removeSignalListener("SIGTERM", stop);
	}
}
