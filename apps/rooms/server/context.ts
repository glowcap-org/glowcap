// The explicit owner graph one Rooms server passes into its behaviors.
//
// A JavaScript isolate can construct more than one of these. Each holds its
// own live tables, watchers, retained history, file bytes, journal, operator
// revision, pending peering, and IRC gateway tables; none of those inventories
// live on a module.

import type { RoomFileStore } from "./files.ts";
import type { RoomHistory } from "./history.ts";
import type { IrcGatewayTables } from "./irc_gateway/tables.ts";
import type { TroubleJournal } from "./journal.ts";
import type { RoomLiveIndex } from "./live_index.ts";
import type { OperatorRevision } from "./operator/revision.ts";
import type { PendingPeering } from "./peering.ts";
import type { WatcherTable } from "./watchers.ts";

export interface RoomServerContext {
	readonly operator: OperatorRevision;
	readonly journal: TroubleJournal;
	readonly live: RoomLiveIndex;
	readonly files: RoomFileStore;
	readonly peering: PendingPeering;
	readonly irc: IrcGatewayTables;
	readonly history: RoomHistory;
	readonly watchers: WatcherTable;
}
