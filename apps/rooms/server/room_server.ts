// The process-local owner of one Rooms server.
//
// CapTP sessions remain the runtime's authority for references and calls. This
// aggregate owns application state shared by those sessions. Every inventory
// that used to live on a module is an explicit resident of this graph.

import { type Host, type Session } from "@glowcap/runtime";
import { DIRECTORY } from "../lib/protocol.ts";
import type { RoomServerContext } from "./context.ts";
import { directoryBehavior } from "./directory_behavior.ts";
import { RoomFileStore } from "./files.ts";
import { RoomHistory } from "./history.ts";
import { IrcGatewayTables } from "./irc_gateway/tables.ts";
import { TroubleJournal } from "./journal.ts";
import { RoomLiveIndex } from "./live_index.ts";
import { OperatorRevision } from "./operator/revision.ts";
import { PendingPeering } from "./peering.ts";
import { RoomDisconnects } from "./presence.ts";
import type { RoomLinks } from "./room_links.ts";
import { RoomServerSessions } from "./sessions.ts";
import { WatcherTable } from "./watchers.ts";

export class RoomServer implements RoomServerContext {
	readonly operator = new OperatorRevision();
	readonly journal = new TroubleJournal(this.operator);
	readonly live = new RoomLiveIndex(this.operator, this.journal);
	readonly files = new RoomFileStore(this.journal);
	readonly peering = new PendingPeering(this.operator);
	readonly irc = new IrcGatewayTables(this.journal, this.operator);
	readonly history: RoomHistory;
	readonly watchers: WatcherTable;
	readonly #disconnects: RoomDisconnects;
	readonly sessions: RoomServerSessions;

	constructor() {
		this.history = new RoomHistory((source, error) => this.journal.note(source, error));
		this.watchers = new WatcherTable(this.journal);
		this.#disconnects = new RoomDisconnects(this);
		this.sessions = new RoomServerSessions(this.#disconnects);
	}

	/** Publish the Host-wide directory before admitting any connection, then
	 * give every accepted session to this server's lifecycle owner. */
	async serve(
		host: Host,
		accepted: AsyncIterable<Session>,
		links?: RoomLinks,
		advertisedLocation?: (session: Session) => string,
	): Promise<void> {
		host.publishGiftable(DIRECTORY, directoryBehavior(this, links, advertisedLocation));
		await this.sessions.serve(accepted);
	}

	/** Close server-owned storage after listeners and their sessions stop. */
	async close(): Promise<void> {
		await this.history.close();
	}
}
