// One accepted session's life on this server, for every listener alike.
//
// The boot listener and any listener the admin capability brings up later
// (`listeners.ts`) serve sessions the same way, so the loop lives here rather
// than inside either caller: presence is retired at the transport's terminal
// boundary, and the session shell itself is closed when its serve settles.

import type { Session } from "@pancake/runtime";
import { scheduleDisconnect } from "./presence.ts";

/** Serve every session `server` accepts until it stops admitting. */
export async function serveAccepted(server: AsyncIterable<Session>): Promise<void> {
	for await (const session of server) {
		// Presence is indexed by connection, so retire it at the transport's own
		// terminal boundary. Learning this from a later failed notify leaves stale
		// membership between closure and the next broadcast.
		const stopClose = session.onClose(() => scheduleDisconnect(session));
		// When the member's connection ends, the membership cleanup runs and
		// then the session itself is retired. Without the close, the native
		// session shell outlives its dead transport: the host accumulates one
		// shell per departed member, and the live timeline never hears this
		// side of the wire end, so a vanished member's session lingers on the
		// picture until the room server restarts.
		session.serve().catch((error) => {
			console.error(`[room] session failed: ${error}`);
		}).finally(() => {
			stopClose();
			scheduleDisconnect(session); // pre-transport serve refusal joins the same cleanup batch
			session.close().catch((error) => {
				console.error(`[room] session retirement failed: ${error}`);
			});
		});
	}
}
