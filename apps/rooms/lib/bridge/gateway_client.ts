// Speaking to a bridge gateway over CapTP.
//
// The verbs and the description are generic: a gateway answers `snapshot` with
// its whole description, opens a connection from a submitted answers record,
// and hands back a connection capability whose leases are added and removed by
// the same answer-or-id shape. Nothing here knows IRC; the bridge behind the
// capability does.

import { Ref, retainCleanupFailures, type Session } from "@glowcap/runtime";
import { SNAPSHOT } from "../protocol.ts";
import {
	ADD_LEASE,
	type BridgeGateway,
	CLOSE_CONNECTION,
	GATEWAY_CONNECTION,
	OPEN_CONNECTION,
	parseBridgeGateway,
	REMOVE_LEASE,
} from "./gateway.ts";
import { ask } from "../ask.ts";
import { takeOperationsCap } from "../operations.ts";

/** Fetch the gateway and read its whole description. */
export async function takeBridgeGateway(session: Session, pasted: string): Promise<{
	cap: Ref;
	gateway: BridgeGateway;
}> {
	const { cap, taken } = await takeOperationsCap(
		session,
		pasted,
		(fetched) => snapshotBridgeGateway(session, fetched),
	);
	return { cap, gateway: taken };
}

/** Ask a gateway already in hand for its current description. */
export async function snapshotBridgeGateway(session: Session, cap: Ref): Promise<BridgeGateway> {
	const raw = await ask(session, cap, SNAPSHOT, [], "the bridge gateway did not answer");
	return parseBridgeGateway(raw);
}

async function withConnection<T>(session: Session, connection: Ref, use: (connection: Ref) => Promise<T>): Promise<T> {
	let answer: T;
	try {
		answer = await use(connection);
	} catch (error) {
		throw await retainCleanupFailures(error, [() => session.release(connection)]);
	}
	session.release(connection);
	return answer;
}

async function connectionCap(session: Session, gateway: Ref, connectionId: string): Promise<Ref> {
	const connection = await ask(
		session,
		gateway,
		GATEWAY_CONNECTION,
		[connectionId],
		"the gateway did not answer with the connection",
	);
	if (!(connection instanceof Ref)) throw new Error("the gateway did not return a connection capability");
	return connection;
}

/** Open a connection from the answers a reader filled into the gateway's
 * connection form. Resolves with the connection's id. */
export async function openBridgeConnection(session: Session, gateway: Ref, answers: string): Promise<string> {
	const id = await ask(
		session,
		gateway,
		OPEN_CONNECTION,
		[answers],
		"the gateway did not open the connection",
	);
	if (typeof id !== "string" || id === "") throw new Error("the gateway did not name the opened connection");
	// The gateway answers only after its durable work commits, so the id is
	// already re-readable; nothing further to await.
	return id;
}

/** Add a lease under a connection from the answers a reader filled into the
 * gateway's lease form. Resolves with the lease's own name when it has one. */
export async function addBridgeLease(
	session: Session,
	gateway: Ref,
	connectionId: string,
	answers: string,
): Promise<string> {
	const connection = await connectionCap(session, gateway, connectionId);
	return await withConnection(session, connection, async (cap) => {
		const name = await ask(session, cap, ADD_LEASE, [answers], "the connection did not answer the lease");
		return typeof name === "string" ? name : "";
	});
}

/** Remove one lease from a connection by its id. */
export async function removeBridgeLease(
	session: Session,
	gateway: Ref,
	connectionId: string,
	leaseId: string,
): Promise<void> {
	const connection = await connectionCap(session, gateway, connectionId);
	await withConnection(session, connection, async (cap) => {
		await ask(session, cap, REMOVE_LEASE, [leaseId], "the connection did not answer the lease removal");
	});
}

/** Close one connection and every lease beneath it. */
export async function closeBridgeConnection(session: Session, gateway: Ref, connectionId: string): Promise<void> {
	const connection = await connectionCap(session, gateway, connectionId);
	await withConnection(session, connection, async (cap) => {
		await ask(session, cap, CLOSE_CONNECTION, [], "the connection did not close");
	});
}
