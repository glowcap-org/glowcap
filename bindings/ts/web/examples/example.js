import { init, webrtc } from "./glowcap.js";

// This example makes one connection. Its signaling stays in the page because
// both peers live here. Across machines, carry these messages through a
// service that authenticates the peer keys, such as an existing CapTP session.
function signalingPair() {
	const sides = [0, 1].map(() => ({ sink: null, pending: [], answer: null }));
	return sides.map((own, index) => {
		const other = sides[1 - index];
		return {
			offer(_exchange, _target, sdp) {
				return new Promise((resolve) => {
					own.answer = resolve;
					answering.provideOffer(client.host.designator(), sdp);
				});
			},
			answer(_exchange, _target, sdp) {
				other.answer(sdp);
			},
			candidate(_exchange, ice) {
				if (other.sink) other.sink(ice);
				else other.pending.push(ice);
			},
			onCandidate(_exchange, _target, sink) {
				own.sink = sink;
				for (const ice of own.pending.splice(0)) sink(ice);
				return () => {
					own.sink = null;
				};
			},
		};
	});
}

const [outgoing, incoming] = signalingPair();
const web = await init({
	wasm: fetch(new URL("./glowcap_host.wasm", import.meta.url)),
	connectors: [webrtc.connector(outgoing)],
});
const client = web.runtime;
const server = await web.openRuntime();
const answering = webrtc.listener(server.host, incoming);
server.host.publish("greeter", (verb, args) => {
	if (verb !== "greet") throw new Error(`unknown method: ${verb}`);
	return `hello ${args[0]} over WebRTC`;
});
const serving = (async () => {
	for await (const session of answering) await session.serve();
})();
let reply;
try {
	const session = await client.connect(webrtc.locator(server.host.designator()));
	try {
		const greeter = await session.fetch("greeter");
		reply = await session.send(greeter, "greet", ["world"]);
	} finally {
		await session.close();
	}
} catch (error) {
	document.querySelector("#result").textContent = String(error);
	throw error;
} finally {
	await answering.close();
	await client.close();
	await server.close();
	await serving;
}

document.querySelector("#result").textContent = reply;
