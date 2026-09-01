// The explicit owner graph one Rooms browser page passes into its net layer.
//
// A JavaScript isolate can construct more than one of these. Each holds its
// own directory sessions, connection lifecycle (including a staged first join),
// locator/runtime wait, connection inventories, the presentation projection,
// and the persistence working copies that outlive any one directory session.
// None of those inventories live on a module.

import { MAX_WORKSPACE_DIRECTORIES } from "../../lib/rooms_state.ts";
import { PageArchiveRefs } from "./archive.ts";
import { PageArchiveDatabase } from "./archive_database.ts";
import { TabArchiveBackend } from "./archive_store.ts";
import { PageHistoryRecorder } from "./history.ts";
import { PageArchiveShares } from "./net/archive_shares.ts";
import { PageBootstrap } from "./net/bootstrap.ts";
import { PageDirects } from "./net/direct.ts";
import { PageDirectOffers } from "./net/direct_offers.ts";
import { PageInspect } from "./net/diagnostics.ts";
import { DirectoryConnectionLifecycle } from "./net/directory_connection_lifecycle.ts";
import { PageHistoryCoords } from "./net/history.ts";
import { PageIrcGateway } from "./net/irc.ts";
import { PageListeners } from "./net/listeners.ts";
import { PageLiveIndex } from "./net/live.ts";
import { PageOperator } from "./net/operator.ts";
import { PagePeering } from "./net/peering.ts";
import { PageReachable } from "./net/reachable.ts";
import { PageTyping } from "./net/typing.ts";
import { PageViz } from "./net/viz.ts";
import { PageOpsInvalidation } from "./ops/invalidation.ts";
import { PageAttachedSession } from "./session/attached_hold.ts";
import { PageHostedSession } from "./session/hosted_hold.ts";
import { PageProjection } from "./store/core.ts";
import { PageWorkspace } from "./workspace_state.ts";

export interface RoomsPageContext {
	readonly live: PageLiveIndex;
	readonly connections: DirectoryConnectionLifecycle;
	readonly bootstrap: PageBootstrap;
	readonly directs: PageDirects;
	readonly offers: PageDirectOffers;
	readonly reachable: PageReachable;
	readonly peering: PagePeering;
	readonly history: PageHistoryCoords;
	readonly shares: PageArchiveShares;
	readonly typing: PageTyping;
	readonly inspect: PageInspect;
	readonly listeners: PageListeners;
	readonly irc: PageIrcGateway;
	readonly operator: PageOperator;
	readonly viz: PageViz;
	readonly opsInvalidation: PageOpsInvalidation;
	readonly workspace: PageWorkspace;
	readonly archiveDb: PageArchiveDatabase;
	readonly archive: TabArchiveBackend;
	readonly archiveRefs: PageArchiveRefs;
	readonly recorder: PageHistoryRecorder;
	readonly attachedSession: PageAttachedSession;
	readonly hostedSession: PageHostedSession;
	readonly projection: PageProjection;
}

export class RoomsPage implements RoomsPageContext {
	readonly live: PageLiveIndex = new PageLiveIndex(this);
	readonly connections = new DirectoryConnectionLifecycle(MAX_WORKSPACE_DIRECTORIES);
	readonly bootstrap = new PageBootstrap();
	readonly directs = new PageDirects();
	readonly offers = new PageDirectOffers();
	readonly reachable = new PageReachable();
	readonly peering = new PagePeering();
	readonly history = new PageHistoryCoords();
	readonly shares = new PageArchiveShares();
	readonly typing = new PageTyping();
	readonly inspect = new PageInspect();
	readonly listeners = new PageListeners();
	readonly irc = new PageIrcGateway();
	readonly operator = new PageOperator();
	readonly viz = new PageViz();
	readonly opsInvalidation = new PageOpsInvalidation();
	readonly workspace = new PageWorkspace();
	readonly archiveDb = new PageArchiveDatabase();
	readonly archive = new TabArchiveBackend(this.archiveDb);
	readonly archiveRefs = new PageArchiveRefs();
	readonly recorder = new PageHistoryRecorder(this.archive);
	readonly attachedSession = new PageAttachedSession();
	readonly hostedSession = new PageHostedSession();
	readonly projection = new PageProjection();
}
