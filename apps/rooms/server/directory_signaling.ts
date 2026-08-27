// WebRTC signaling relayed between exact live directory registrations.

import { type Argument, type Behavior, Ref, type Session } from "@pancake/runtime";
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
import { noteTrouble } from "./journal.ts";
import {
	handBack,
	introductions,
	mintSignalExchangeId,
	nickKey,
	signalExchanges,
	webrtcDesignators,
} from "./registry.ts";

export const DIRECTORY_SIGNALING_UNHANDLED = Symbol("directory signaling unhandled");
export const DIRECTORY_SIGNALING_CAPABILITY_VERBS = [OFFER_SIGNALING, SIGNAL_OFFER] as const;

function refuse(session: Session, args: readonly Argument[], error: unknown): never {
	throwAfterReleasingCapabilities(session, args, error);
}

function failDelivery(id: string, what: string, error: unknown): void {
	noteTrouble(`${what} delivery failed`, error);
	if (signalExchanges.has(id)) dropSignalExchange(id, `${what} could not be delivered`);
}

export function dispatchDirectorySignaling(
	verb: string,
	args: Argument[],
	session: Session,
): ReturnType<Behavior> | typeof DIRECTORY_SIGNALING_UNHANDLED {
	if (verb === OFFER_SIGNALING) {
		const offered = args[0];
		if (args.length !== 1 || !(offered instanceof Ref)) {
			refuse(session, args, new Error("offerSignaling needs one inbox capability"));
		}
		const ownNick = registeredNickOf(session);
		if (ownNick == null) {
			handBack(session, offered, "unregistered signaling inbox");
			throw new RoomError(NOT_REGISTERED, "offerSignaling needs a registered name");
		}
		const intro = introductions.get(nickKey(ownNick));
		if (intro == null) {
			handBack(session, offered, "unfiled signaling inbox");
			throw new Error("offerSignaling found no registration");
		}
		if (intro.signaling != null) handBack(session, intro.signaling);
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
		if (registeredNickOf(session) == null) {
			handBack(session, reply, "unregistered signaling reply");
			throw new RoomError(NOT_REGISTERED, "signalOffer needs a registered name");
		}
		const targetKey = webrtcDesignators.get(toDesignator);
		const target = targetKey == null ? undefined : introductions.get(targetKey);
		if (targetKey == null || target == null || target.signaling == null) {
			handBack(session, reply, "unroutable signaling reply");
			throw new RoomError(PEER_OFFLINE, "no signaling inbox for that designator");
		}
		const targetSignaling = target.signaling;
		const prior = originatedExchange(session, toDesignator);
		if (prior != null) dropSignalExchange(prior, "signaling exchange was replaced");
		const id = mintSignalExchangeId();
		const expires = setTimeout(
			() => dropSignalExchange(id, "signaling exchange timed out"),
			SIGNAL_EXCHANGE_TIMEOUT_MS,
		);
		signalExchanges.set(id, { originator: session, reply, targetKey, expires });
		while (signalExchanges.size > MAX_SIGNAL_EXCHANGES) {
			const oldest = signalExchanges.keys().next();
			if (oldest.done) throw new Error("signal exchange cap accounting drift");
			dropSignalExchange(oldest.value, "signaling exchange was evicted");
		}
		void session.tell(reply, SIG_ACCEPTED, [id]).then(() => {
			if (!signalExchanges.has(id)) return;
			return target.registrar.tell(targetSignaling, SIG_OFFER, [id, sdp]);
		}).catch((error) => failDelivery(id, "signaling offer", error));
		return null;
	}
	if (verb === SIGNAL_ANSWER) {
		const id = typeof args[0] === "string" ? args[0] : "";
		const sdp = typeof args[1] === "string" ? args[1] : "";
		if (args.length !== 2 || !relayedSignalFits("description", id, sdp)) {
			throw new Error(`a signaling answer may be at most ${MAX_SIGNAL_SDP} bytes`);
		}
		const exchange = signalExchanges.get(id);
		if (exchange == null) return null;
		const target = introductions.get(exchange.targetKey);
		if (target == null || target.registrar !== session) {
			throw new Error("signalAnswer from a session that does not answer this exchange");
		}
		void exchange.originator.tell(exchange.reply, SIG_ANSWER, [sdp]).catch((error) =>
			failDelivery(id, "signaling answer", error)
		);
		return null;
	}
	if (verb === SIGNAL_CANDIDATE) {
		const key = typeof args[0] === "string" ? args[0] : "";
		const ice = typeof args[1] === "string" ? args[1] : "";
		if (args.length !== 2 || !relayedSignalFits("candidate", key, ice)) {
			throw new Error("signalCandidate needs one exchange id and bounded ICE candidate");
		}
		const exchange = signalExchanges.get(key);
		if (exchange == null) return null;
		if (exchange.originator === session) {
			const target = introductions.get(exchange.targetKey);
			if (target?.signaling == null) return null;
			void target.registrar.tell(target.signaling, SIG_CANDIDATE, [key, ice]).catch((error) =>
				failDelivery(key, "signaling candidate", error)
			);
			return null;
		}
		const target = introductions.get(exchange.targetKey);
		if (target == null || target.registrar !== session) return null;
		void exchange.originator.tell(exchange.reply, SIG_CANDIDATE, [ice]).catch((error) =>
			failDelivery(key, "signaling candidate", error)
		);
		return null;
	}
	if (verb === SIGNAL_DONE) {
		if (args.length !== 1 || typeof args[0] !== "string" || args[0] === "") {
			throw new Error("signalDone needs one exchange id");
		}
		const id = args[0];
		const exchange = signalExchanges.get(id);
		if (exchange != null && exchange.originator === session) dropSignalExchange(id);
		return null;
	}
	return DIRECTORY_SIGNALING_UNHANDLED;
}
