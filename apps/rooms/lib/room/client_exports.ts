// The public client package surface that accompanies the Room implementation.

export { Directory, signalingRoute } from "../directory.ts";
export { readRoomEvent, type RoomEvent, type RoomInfo, type RoomPage } from "../directory_publications.ts";
export { DirectMessage } from "../direct_message.ts";
export { DirectoryPeering, type DurableRoom, RoomPublication } from "../peering.ts";
export { PostedLine } from "../posted_line.ts";
export { RoomInvitation } from "./invitation.ts";
export { RoomManager } from "./manager.ts";
export { type DiagnosticRow, snapshotDiagnostics, takeDiagnostics } from "../diagnostics.ts";
export type { BridgeGateway, GatewayConnection, GatewayLease, GatewayStatus } from "../bridge/gateway.ts";
export {
	addBridgeLease,
	closeBridgeConnection,
	openBridgeConnection,
	removeBridgeLease,
	snapshotBridgeGateway,
	takeBridgeGateway,
} from "../bridge/gateway_client.ts";
export { listenerDown, type ListenerRow, listenerUp, listListeners, takeListeners } from "../listeners.ts";
export {
	clearOperatorTrouble,
	disconnectSession,
	giveRoomManager,
	giveStewardship,
	type OperatorCategory,
	type OperatorLinkRow,
	operatorPage,
	type OperatorReferenceKind,
	type OperatorReferenceRow,
	type OperatorRegistrationRow,
	type OperatorResetScope,
	type OperatorRetireBatch,
	operatorRetireMatching,
	type OperatorRoomKind,
	type OperatorRoomRow,
	type OperatorSessionRow,
	type OperatorSnapshot,
	type OperatorTroubleRow,
	releaseOperatorReference,
	removeOperatorRoom,
	resetOperatorScope,
	revokeNick,
	revokeRoomAuthority,
	revokeRoomLink,
	revokeStewardship,
	snapshotOperator,
	type StewardshipRow,
	subscribeOperator,
	takeRoomsOperator,
} from "../operator.ts";
export {
	type Message,
	readCarries,
	readLineBytes,
	readLineChange,
	readLineId,
	readListed,
	readPresence,
	readRoomFacts,
	readSubject,
	type RoomCarries,
	type RoomFacts,
	roomRecordAt,
} from "./message.ts";
export { isSubjectEmpty, type Subject, subject, subjectRefusal, SubjectSchema } from "./subject.ts";
export { linkRoomReference, roomCalledAs, roomIsPrivate, roomPolicy } from "./entrance.ts";
