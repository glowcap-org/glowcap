// The Rooms server a page uses, as the page shows it: the directory a blank
// address means, the relay that carries a local session's Rooms, and the
// served directory a new local session opens in.
import { managedSessionText as managedText } from "../../lib/text/managed_session.ts";
import { NO_SERVER, roomsErrorIn } from "../../lib/error_codes.ts";
import type { RoomsPage } from "./page.ts";
import type { ManagedRoomsSession } from "./session/managed/session.ts";
import type { RoomsSessionController } from "./controller/session.ts";
import { membershipStatus } from "./session/managed/membership_status.ts";
import { relayAway } from "./store/projection.ts";
import { serverInUse } from "./server_choice.ts";
import { locateRoomsServer } from "./server_probe.ts";

type Report = (source: string, error: unknown) => void;

/** The directory the Rooms server at `base` names, or null while it does not answer. */
async function directoryOf(base: string): Promise<string | null> {
	const reply = await locateRoomsServer(base);
	return reply.kind === "answers" ? reply.directory : null;
}

/** Show the Rooms server this browser uses and the directory it names, and
 * return that directory. The server is the one this device chose, else the
 * one that sent this page. A static host is no server, so with no choice
 * there is none. */
export async function showServedDirectory(page: RoomsPage): Promise<string | null> {
	const server = serverInUse();
	const directory = server == null ? null : await directoryOf(server.base);
	page.projection.set({ server: server == null ? null : { ...server, directory } });
	return directory;
}

/** Name the served directory once a server that was not answering when the
 * page opened is reached, so a blank address finds it without a reload. */
async function readServedDirectory(page: RoomsPage): Promise<void> {
	const held = page.projection.get().server;
	if (held == null || held.directory != null) return;
	const directory = await directoryOf(held.base);
	if (directory != null) page.projection.set({ server: { ...held, directory } });
}

/** Start a local session's Rooms over the server in use, and return this
 * browser's address, or null with no Rooms server. The relay's state is a
 * fact on the page, and its reasons go to the trouble journal. */
export async function startLocalRooms(
	page: RoomsPage,
	managed: ManagedRoomsSession,
	report: Report,
): Promise<string | null> {
	const server = page.projection.get().server;
	let locator: string | null = null;
	try {
		locator = await managed.application.startRooms(membershipStatus(page.projection, report));
	} catch (error) {
		// Relay-only messages keep this browser's address off WebRTC, so a page
		// with no Rooms server has no address to give. That is the page's state,
		// not trouble: it stays open, and Settings is where a server is chosen.
		// Anything else is the failure it is.
		if (server != null || roomsErrorIn(error)?.code !== NO_SERVER) throw error;
	}
	// A page with no Rooms server registers nowhere, so it has no relay state.
	if (server == null) return locator;
	page.projection.set({ relay: "connecting" });
	await managed.application.observeRelay((reason: string | null) => {
		// Every seat retries on its own, so the journal records a change of
		// reason once rather than every attempt.
		const was = page.projection.get().relay;
		if (reason == null ? was === "reached" : relayAway(was) && was.away === reason) return;
		if (reason != null) report(managedText.roomsServer, reason);
		page.projection.set({ relay: reason == null ? "reached" : { away: reason } });
		if (reason == null) void readServedDirectory(page);
	});
	return locator;
}

/** Open a session that holds no directory in the served one, without
 * claiming a nickname, and take it as home. A session that holds any keeps
 * its own, and the join card offers the served one. */
export async function openServedDirectory(
	page: RoomsPage,
	managed: ManagedRoomsSession,
	session: RoomsSessionController,
	served: string | null,
	report: Report,
): Promise<void> {
	if (served == null || managed.current?.intent.directories.length !== 0) return;
	page.projection.set({ openingDirectory: true });
	const reason = await session.reachDirectory("", { kind: "exact", name: "" });
	page.projection.set({ openingDirectory: false });
	if (reason !== "") report(managedText.roomsConnection, reason);
}
