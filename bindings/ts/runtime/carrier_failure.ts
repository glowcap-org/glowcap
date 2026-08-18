import {
	CARRIER_DETAIL_ENGINE_CODE,
	CARRIER_DETAIL_PEER_ALERT,
	CARRIER_PHASE_CONNECT,
	CARRIER_PHASE_NONE,
	CARRIER_PHASE_RECEIVE,
	CARRIER_PHASE_REGISTRATION,
	CARRIER_PHASE_RESOLVE,
	CARRIER_PHASE_SECURE_HANDSHAKE,
	CARRIER_PHASE_SHUTDOWN,
	CARRIER_PHASE_TRANSMIT,
	CARRIER_PHASE_WEBSOCKET_UPGRADE,
	INTERNAL,
} from "@pancake/abi";
import { PancakeError } from "./errors.ts";

export type CarrierPhase =
	| "resolve"
	| "connect"
	| "secureHandshake"
	| "webSocketUpgrade"
	| "registration"
	| "receive"
	| "transmit"
	| "shutdown";

export interface CarrierFailure {
	readonly phase: CarrierPhase;
	readonly verificationFlags: number;
	readonly peerAlert: number | null;
	readonly engineCode: number | null;
}

const phases = new Map<number, CarrierPhase>([
	[CARRIER_PHASE_RESOLVE, "resolve"],
	[CARRIER_PHASE_CONNECT, "connect"],
	[CARRIER_PHASE_SECURE_HANDSHAKE, "secureHandshake"],
	[CARRIER_PHASE_WEBSOCKET_UPGRADE, "webSocketUpgrade"],
	[CARRIER_PHASE_REGISTRATION, "registration"],
	[CARRIER_PHASE_RECEIVE, "receive"],
	[CARRIER_PHASE_TRANSMIT, "transmit"],
	[CARRIER_PHASE_SHUTDOWN, "shutdown"],
]);

export function decodeCarrierFailure(
	phase: number,
	detailFlags: number,
	verificationFlags: number,
	peerAlert: number,
	engineCode: number,
): CarrierFailure | null {
	if (phase === CARRIER_PHASE_NONE) {
		if (detailFlags === 0 && verificationFlags === 0 && peerAlert === 0 && engineCode === 0) return null;
		throw invalid("carrier detail without a carrier phase");
	}
	const decoded = phases.get(phase);
	if (decoded === undefined) throw invalid(`unknown carrier phase ${phase}`);
	const known = CARRIER_DETAIL_PEER_ALERT | CARRIER_DETAIL_ENGINE_CODE;
	const hasAlert = (detailFlags & CARRIER_DETAIL_PEER_ALERT) !== 0;
	const hasEngine = (detailFlags & CARRIER_DETAIL_ENGINE_CODE) !== 0;
	if (
		(detailFlags & ~known) !== 0 || (!hasAlert && peerAlert !== 0) ||
		(hasAlert && peerAlert > 0xff) || (!hasEngine && engineCode !== 0)
	) throw invalid("inconsistent carrier failure detail");
	return {
		phase: decoded,
		verificationFlags,
		peerAlert: hasAlert ? peerAlert : null,
		engineCode: hasEngine ? engineCode : null,
	};
}

function invalid(detail: string): PancakeError {
	return new PancakeError(INTERNAL, `driver returned ${detail}`);
}
