#!/usr/bin/env -S deno run -A
/**
 * A stand-in for the live timeline endpoint, for driving the viewer without
 * a room server behind it.
 *
 * It speaks what the real endpoint forwards: two producers, each reporting
 * its own side of one shared wire, replayed as a snapshot and closed with
 * `trace.replay-end`, then a steady trickle of messages. That is the rooms
 * shape, every peer publishes its own trace, so a viewer pointed here sees
 * the same topology it sees against a live room, at a rate you choose.
 *
 *     deno run -A scripts/fake-viz-endpoint.ts 9111 20
 *
 * The arguments are the port and the messages per second.
 */
const port = Number(Deno.args[0] ?? "9111");
const rate = Number(Deno.args[1] ?? "20");

/** Two hosts and the session identifier both of them derive. Spelled as
 *  64 hex digits because that is what a designator and a Session ID are. */
const HOST_A = "a".repeat(64);
const HOST_B = "b".repeat(64);
const WIRE = "c".repeat(64);

Deno.serve({ port, hostname: "127.0.0.1" }, (req) => {
	if (req.headers.get("upgrade") !== "websocket") {
		return new Response("fake viz endpoint", { status: 200 });
	}
	const { socket, response } = Deno.upgradeWebSocket(req);
	let seq = 0;
	let simT = 0;
	let timer: number | undefined;
	const send = (record: Record<string, unknown>) => {
		if (socket.readyState !== WebSocket.OPEN) return;
		socket.send(JSON.stringify({ v: 1, seq: ++seq, epoch: 1, ...record }));
	};
	socket.onopen = () => {
		// Each producer's own report of the same wire, which is what lets the
		// viewer put both ends on peers it can name.
		const open = (session: string, self: string, partner: string) => ({
			sim_t_ns: simT,
			kind: "ocapn.session-opened",
			session,
			a: self,
			b: partner,
			session_id: WIRE,
			transport: "keyed-tcp",
			provenance: "unauthenticated",
			codec: "capnp",
			// The handshake's own spelling, which is what a trace reports.
			captp_version: "glowcap-next",
			replay: true,
		});
		send(open("p1/s1", HOST_A, HOST_B));
		send(open("p2/s1", HOST_B, HOST_A));
		send({ sim_t_ns: simT, kind: "trace.replay-end" });
		let n = 0;
		timer = setInterval(() => {
			simT += 1_000_000 * (1000 / rate);
			n += 1;
			const outbound = n % 2 === 0;
			send({
				sim_t_ns: simT,
				kind: "ocapn.message-decoded",
				session: "p1/s1",
				outbound,
				op: outbound ? "op:deliver" : "op:resolve",
				codec: "capnp",
				len: 96,
				digest: `probe-${n}`,
			});
		}, 1000 / rate);
	};
	socket.onclose = () => {
		if (timer !== undefined) clearInterval(timer);
	};
	return response;
});
console.log(`fake viz endpoint on ws://127.0.0.1:${port}/ at ${rate}/s`);
