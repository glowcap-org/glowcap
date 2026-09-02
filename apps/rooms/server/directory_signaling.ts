// WebRTC signaling relayed between exact live directory registrations.

import { type Argument, type Behavior, Ref, type Session } from "@glowcap/runtime";
import { NOT_REGISTERED, PEER_OFFLINE, RoomError } from "../lib/errors.ts";
import { MAX_SIGNAL_EXCHANGES, MAX_SIGNAL_SDP, relayedSignalFits, SIGNAL_EXCHANGE_TIMEOUT_MS } from "../lib/limits.ts";
import {
	OFFER_SIGNALING,
	SIG_ACCEPTED,
	SIG_ANSWER,
	SIG_CANDIDATE,
	SIG_OFFER,
	SIGNAL_ANSWER,
	SIGNAL_CANDIDATE,
	SIGNAL_DONE,
	SIGNAL_OFFER,
} from "../lib/protocol.ts";
import { throwAfterReleasingCapabilities } from "../lib/argument_custody.ts";
import { dropSignalExchange, originatedExchange, registeredNickOf } from "./introductions.ts";
import type { RoomLiveIndex } from "./live_index.ts";
import { nickKey } from "./registry.ts";

export const DIRECTORY_SIGNALING_UNHANDLED = Symbol("directory signaling unhandled");
export const DIRECTORY_SIGNALING_CAPABILITY_VERBS = [OFFER_SIGNALING, SIGNAL_OFFER] as const;

function refuse(session: Session, args: readonly Argument[], error: unknown): never {
	throwAfterReleasingCapabilities(session, args, error);
}

function failDelivery(live: RoomLiveIndex, id: string, what: string, error: unknown): void {
	live.journal.note(`${what} delivery failed`, error);
	if (live.signalExchanges.has(id)) dropSignalExchange(live, id, `${what} could not be delivered`);
}

export function dispatchDirectorySignaling(
	live: RoomLiveIndex,
	verb: string,
	args: Argument[],
	session: Session,
): ReturnType<Behavior> | typeof DIRECTORY_SIGNALING_UNHANDLED {
	if (verb === OFFER_SIGNALING) {
		const offered = args[0];
		if (args.length !== 1 || !(offered instanceof Ref)) {
			refuse(session, args, new Error("offerSignaling needs one inbox capability"));
		}
		const ownNick = registeredNickOf(live, session);
		if (ownNick == null) {
			live.journal.release(session, offered, "unregistered signaling inbox");
			throw new RoomError(NOT_REGISTERED, "offerSignaling needs a registered name");
		}
		const intro = live.introductions.get(nickKey(ownNick));
		if (intro == null) {
			live.journal.release(session, offered, "unfiled signaling inbox");
			throw new Error("offerSignaling found no registration");
		}
		if (intro.signaling != null) live.journal.release(session, intro.signaling);
		intro.signaling = offered;
		return null;
	}
	if (verb === SIGNAL_OFFER) {
		const toDesignator = typeof args[0] === "string" ? args[0] : "";
		const sdp = typeof args[1] === "string" ? args[1] : "";
		const reply = args[2];
		if (args.length !== 3 || !relayedSignalFits("description", toDesignator, sdp) || !(reply instanceof Ref)) {
			refuse(
				session,
				args,
				new Error(
					`signalOffer needs a designator, an offer sdp of at most ${MAX_SIGNAL_SDP} bytes, and one reply capability`,
				),
			);
		}
		if (registeredNickOf(live, session) == null) {
			live.journal.release(session, reply, "unregistered signaling reply");
			throw new RoomError(NOT_REGISTERED, "signalOffer needs a registered name");
		}
		const targetKey = live.webrtcDesignators.get(toDesignator);
		const target = targetKey == null ? undefined : live.introductions.get(targetKey);
		if (targetKey == null || target == null || target.signaling == null) {
			live.journal.release(session, reply, "unroutable signaling reply");
			throw new RoomError(PEER_OFFLINE, "no signaling inbox for that designator");
		}
		const targetSignaling = target.signaling;
		const prior = originatedExchange(live, session, toDesignator);
		if (prior != null) dropSignalExchange(live, prior, "signaling exchange was replaced");
		const id = live.mintSignalExchangeId();
		const expires = setTimeout(
			() => dropSignalExchange(live, id, "signaling exchange timed out"),
			SIGNAL_EXCHANGE_TIMEOUT_MS,
		);
		live.signalExchanges.set(id, { originator: session, reply, targetKey, expires });
		while (live.signalExchanges.size > MAX_SIGNAL_EXCHANGES) {
			const oldest = live.signalExchanges.keys().next();
			if (oldest.done) throw new Error("signal exchange cap accounting drift");
			dropSignalExchange(live, oldest.value, "signaling exchange was evicted");
		}
		// Admission is not observable to the originator until the target has
		// taken the offer. Otherwise the originator can replace an accepted
		// exchange while its offer is still queued, and retirement suppresses a
		// delivery that `accepted` already promised. This order also means early
		// ICE cannot overtake the offer: candidates wait for `accepted`.
		void target.registrar.tell(targetSignaling, SIG_OFFER, [id, sdp]).then(() => {
			if (!live.signalExchanges.has(id)) return;
			return session.tell(reply, SIG_ACCEPTED, [id]);
		}).catch((error) => failDelivery(live, id, "signaling offer", error));
		return null;
	}
	if (verb === SIGNAL_ANSWER) {
		const id = typeof args[0] === "string" ? args[0] : "";
		const sdp = typeof args[1] === "string" ? args[1] : "";
		if (args.length !== 2 || !relayedSignalFits("description", id, sdp)) {
			throw new Error(`a signaling answer may be at most ${MAX_SIGNAL_SDP} bytes`);
		}
		const exchange = live.signalExchanges.get(id);
		if (exchange == null) return null;
		const target = live.introductions.get(exchange.targetKey);
		if (target == null || target.registrar !== session) {
			throw new Error("signalAnswer from a session that does not answer this exchange");
		}
		void exchange.originator.tell(exchange.reply, SIG_ANSWER, [sdp]).catch((error) =>
			failDelivery(live, id, "signaling answer", error)
		);
		return null;
	}
	if (verb === SIGNAL_CANDIDATE) {
		const key = typeof args[0] === "string" ? args[0] : "";
		const ice = typeof args[1] === "string" ? args[1] : "";
		if (args.length !== 2 || !relayedSignalFits("candidate", key, ice)) {
			throw new Error("signalCandidate needs one exchange id and bounded ICE candidate");
		}
		const exchange = live.signalExchanges.get(key);
		if (exchange == null) return null;
		if (exchange.originator === session) {
			const target = live.introductions.get(exchange.targetKey);
			if (target?.signaling == null) return null;
			void target.registrar.tell(target.signaling, SIG_CANDIDATE, [key, ice]).catch((error) =>
				failDelivery(live, key, "signaling candidate", error)
			);
			return null;
		}
		const target = live.introductions.get(exchange.targetKey);
		if (target == null || target.registrar !== session) return null;
		void exchange.originator.tell(exchange.reply, SIG_CANDIDATE, [ice]).catch((error) =>
			failDelivery(live, key, "signaling candidate", error)
		);
		return null;
	}
	if (verb === SIGNAL_DONE) {
		if (args.length !== 1 || typeof args[0] !== "string" || args[0] === "") {
			throw new Error("signalDone needs one exchange id");
		}
		const id = args[0];
		const exchange = live.signalExchanges.get(id);
		if (exchange != null && exchange.originator === session) dropSignalExchange(live, id);
		return null;
	}
	return DIRECTORY_SIGNALING_UNHANDLED;
}
