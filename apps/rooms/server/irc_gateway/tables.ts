// One server's IRC bridge and network identity tables.
//
// The gateway verbs live in `irc_gateway.ts`; this is the inventory those
// verbs mutate. Constructing another server constructs another set of maps.

import type { Ref, Session } from "@pancake/runtime";
import type { IrcBridgeRoom } from "../../irc/bridge/room.ts";
import type { IrcChannelMembership, IrcMemberConnection } from "../../irc/bridge/reader_connection.ts";
import type { SaslPlainCredentials } from "../../irc/registration.ts";
import type { SeatPhase } from "../../lib/protocol_irc.ts";
import type { TroubleJournal } from "../journal.ts";
import type { OperatorRevision } from "../operator/revision.ts";
import type { IrcBridgeAuthorities } from "./authority.ts";
import { type OperatorIrcNetwork, OperatorIrcNetworks } from "./networks.ts";

export interface ReaderSeat {
	readonly identity: IrcNetworkIdentity;
	/** The nick this shared network connection actually wears. */
	liveNick: string;
	phase: SeatPhase;
	/** False after an explicit disconnect. A Rooms-only member must not be
	 * silently reconnected by their next post. */
	enabled: boolean;
	/** This channel's JOIN/PART and targeted-message authority. */
	membership: IrcChannelMembership | null;
}

export interface BridgedChannel {
	readonly tables: IrcGatewayTables;
	readonly network: OperatorIrcNetwork;
	readonly channel: string;
	readonly roomName: string;
	entryId: string;
	readonly room: IrcBridgeRoom;
	readonly seats: Map<Session, ReaderSeat>;
	readonly invitations: Set<{ session: Session; ref: Ref | null; active: boolean }>;
	status: "connecting" | "up" | "backoff";
	problem: string;
	stopped: boolean;
	forgetIntent(): Promise<void>;
	readonly authorities: IrcBridgeAuthorities | null;
}

export interface IrcNetworkIdentity {
	readonly tables: IrcGatewayTables;
	readonly key: string;
	readonly session: Session;
	ircNick: string;
	liveNick: string;
	identityChosen: boolean;
	enabled: boolean;
	sasl?: SaslPlainCredentials;
	connection: IrcMemberConnection | null;
	opening: Promise<IrcMemberConnection> | null;
	openingAbort: AbortController | null;
	readonly seats: Map<BridgedChannel, ReaderSeat>;
	stopClose: () => void;
}

export class IrcGatewayTables {
	readonly bridged = new Map<string, BridgedChannel>();
	readonly networks: OperatorIrcNetworks;
	readonly identities = new Map<Session, Map<string, IrcNetworkIdentity>>();

	constructor(readonly journal: TroubleJournal, readonly operator: OperatorRevision) {
		this.networks = new OperatorIrcNetworks(journal);
	}
}
