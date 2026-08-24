import * as tcp from "@pancake/tcp";
import { Host, type Runtime } from "../../runtime/mod.ts";
import { assert, ok } from "./support.ts";

/** Prove the native trace veneer produces one coherent consumer timeline. */
export async function runTraceRoundtrip(managed: Runtime): Promise<void> {
	const { annotateSession, enableTrace } = await import("@pancake/runtime");
	const events: import("@pancake/runtime").TraceEvent[] = [];
	const traceFailure = new Error("trace sink failure must stay observer-only");
	const uninstall = enableTrace((event) => {
		events.push(event);
		throw traceFailure;
	}, {
		selfLabel: "smoke",
	});

	await using traceHost = new Host();
	traceHost.publishGiftable("greeter", (verb) => `hello ${verb}`);
	const server = await tcp.listen("127.0.0.1", 0, { host: traceHost });
	const port = server.port;
	const hosted = (async () => {
		for await (const session of server) {
			session.serve().catch(() => {});
			break;
		}
	})();
	const session = await managed.connect(tcp.locator("127.0.0.1", port));
	session.serve().catch(() => {});
	const greeter = await session.fetch("greeter");
	const reply = await session.send(greeter, "trace-me", []);
	assert(reply === "hello trace-me", `traced call still answers, got ${String(reply)}`);
	// The annotation channel: the application states which partner a session
	// carries, named for the same session row the tap names.
	annotateSession(session, { label: "greeter-server" });
	const clientHost = session.host;
	await session.close();
	await hosted;
	uninstall();
	const traceFailures = [...traceHost.takeFailures(), ...clientHost.takeFailures()];
	assert(traceFailures.length > 0, "trace sink failures remain observable");
	assert(
		traceFailures.every((failure) =>
			failure.operation === "trace.sink" && failure.primaryName === "Error" &&
			failure.primaryMessage === traceFailure.message && failure.scopeId > 0n
		),
		"trace sink failures use the central Context schema",
	);

	const opened = events.filter((event) => event.kind === "ocapn.session-opened");
	assert(opened.length >= 2, "both hosts' opens reached the one sink");
	assert(
		opened.every((event) => event.codec === "syrup" && event.a_label === "smoke"),
		"opens carry the negotiated codec and the application's display label",
	);
	// A consumer must not infer an implementation merely because a record
	// arrived, so a pancake host states its profile in words.
	assert(
		opened.every((event) => event.a_profile === "pancake"),
		"an open states the implementation this producer runs",
	);
	// Identity and label are separate facts. `a` is the host's own key
	// designator—the only name two producers can agree on.
	assert(
		opened.every((event) => /^[0-9a-f]{64}$/.test(event.a ?? "")),
		"an open's `a` endpoint is the reporting host's key designator",
	);
	// Both peers derive the OCapN Session ID, allowing a consumer to recognize
	// one session observed twice rather than two unrelated sessions.
	assert(
		opened.every((event) =>
			event.session_id === opened[0].session_id &&
			/^[0-9a-f]{64}$/.test(event.session_id ?? "")
		),
		"both peers of one session report the same OCapN Session ID",
	);
	const outbound = events.find((event) =>
		event.kind === "ocapn.message-decoded" && event.op === "trace-me" && event.outbound === true
	);
	assert(outbound !== undefined, "the client's send traced outbound");
	const inbound = events.find((event) =>
		event.kind === "ocapn.message-decoded" && event.op === "trace-me" && event.outbound === false
	);
	assert(inbound !== undefined, "the server's deliver traced inbound");
	assert(inbound.session !== outbound.session, "each host names its own session row");
	// Both fact sites sit at the wire boundary, so each record carries the whole
	// sub-cap frame with its true length and the verb inside it.
	for (const record of [inbound, outbound]) {
		assert(
			record.bytes_b64 !== undefined && record.len === atob(record.bytes_b64).length,
			"the record carries its whole frame with its true length",
		);
		assert(atob(record.bytes_b64).includes("trace-me"), "the frame bytes contain the delivered verb");
	}
	assert(events.some((event) => event.kind === "ocapn.session-closed"), "the close reached the sink");
	const meta = events.find((event) => event.kind === "ocapn.session-meta");
	assert(
		meta !== undefined && meta.meta?.label === "greeter-server",
		"the annotation reached the sink with its label",
	);
	assert(meta.session === outbound.session, "the annotation names the same session row the tap names");
	let last = -1;
	for (const event of events) {
		assert(event.sim_t_ns >= last, "sim_t_ns is monotone");
		last = event.sim_t_ns;
	}
	ok("the live trace produced the timeline schema for a whole conversation");
}
