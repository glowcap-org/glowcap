import { Connector, Session, TRANSPORT_WEBRTC } from "@glowcap/runtime";
import { bringUp, mintExchange, type PeerOptions, type SignalingAuthority, type SignalingTarget } from "./exchange.ts";

/** Configure an explicit WebRTC connector over caller-owned signaling. A dial
 * to a `webrtc` locator makes the offer, carries it through `signaling.offer`,
 * and runs the keyed session over the DataChannel once it opens. */
export function connector(
	signaling: Omit<SignalingAuthority, "answer">,
	options: PeerOptions = {},
): Connector {
	return new Connector([TRANSPORT_WEBRTC], async (host, locator, request) => {
		// The connector is not told which session introduced the dial.
		const target: SignalingTarget = { designator: locator.designator, introducer: null };
		const exchange = mintExchange();
		return await bringUp(host, signaling, exchange, target, options, request.signal, "webrtc dial", {
			offerer: true,
			async negotiate(peer, step) {
				const offer = await step(peer.createOffer(), "offer");
				const answer = await step(signaling.offer(exchange, target, offer), "signaling");
				await step(peer.setRemoteAnswer(answer), "remote-answer");
			},
			establish: (channel) =>
				Session.establishDialedLocator(
					host,
					locator,
					channel,
					request.handshakeTimeoutMs,
					// Directory signaling was scoped to this designator, and DTLS binds
					// the channel to the SDP that exchange ferried (ADR-0105).
					locator.designator,
				),
		});
	});
}
