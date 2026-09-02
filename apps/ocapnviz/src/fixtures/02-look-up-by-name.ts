import { TimelineDocument } from "../engine/timeline.ts";
import { payloadOf, wireFrames } from "./wire-frames.ts";

/**
 * Chapter 02 — Look up a service by name.
 *
 * A new client connects to a home hub hosting a thermostat, lights,
 * and music. It only knows the name "thermostat" and asks the
 * bootstrap object (export id 0) to fetch it. The hub's runtime
 * synthesizes the resolve from its bootstrap table.
 *
 * On the wire: the client is at `127.0.0.1:9201` and the hub at
 * `127.0.0.1:9202`, over plain `tcp`. The client's end is its own
 * report; the hub's end is attached because the hub publishes
 * its own trace of the same session and the two agree on the OCapN
 * Session ID. `tcp` itself proves nothing about who answered.
 * Both peers run glowcap, so this session settles on Cap'n Proto over
 * glowcap-next. That is the pairing a glowcap fleet configures
 * (`HostRuntime.Options.codec` / `.captp_version` in `src/driver/host_runtime.zig`); the
 * Syrup / OCapN 1.0 baseline is what a session settles on the moment a peer
 * at either end cannot follow.
 */

const AGENT = "ocapnviz:fixtures/02-look-up-by-name";

export const lookUpByName = TimelineDocument.parse({
	id: "02-look-up-by-name",
	metadata: {
		"dct:title": "02 · Look up a service by name",
		"dct:description":
			"A client knows one name, \"thermostat\", and nothing else about the server. It asks the server's bootstrap object for that name and gets a live reference back. No application code on the server runs at all: the session's own registry answers.",
		"dct:creator": "glowcap project",
		"dct:created": "2026-05-14T00:00:00Z",
	},
	provenance: { "prov:wasAttributedTo": AGENT },
	duration: 3000,
	events: [
		{
			id: "client-joins",
			t: 0,
			kind: "peer-joined",
			peerId: "127.0.0.1:9201",
			label: "Client",
			profile: "glowcap",
			designator: "127.0.0.1:9201",
		},
		{
			id: "server-joins",
			t: 0,
			kind: "peer-joined",
			peerId: "127.0.0.1:9202",
			label: "Home hub",
			profile: "glowcap",
			designator: "127.0.0.1:9202",
		},
		{
			id: "session-opens",
			t: 0,
			kind: "session-opened",
			sessionId: "59b79ed34e6ede4e56486b962eb594e572b6841841196bef3eb37d9949a3fa8c",
			a: {
				peer: "127.0.0.1:9201",
				designator: "127.0.0.1:9201",
				attributedBy: "self-reported",
			},
			b: {
				peer: "127.0.0.1:9202",
				designator: "127.0.0.1:9202",
				attributedBy: "viewer-correlated",
			},
			transport: "tcp",
			codec: "capnp",
			captpVersion: "next",
			initialState: "negotiating",
		},
		{
			id: "ss-out",
			t: 200,
			kind: "message-sent",
			messageId: "ss-out",
			sessionId: "59b79ed34e6ede4e56486b962eb594e572b6841841196bef3eb37d9949a3fa8c",
			from: "127.0.0.1:9201",
			to: "127.0.0.1:9202",
			arrivalT: 400,
			label: "op:start-session",
			...payloadOf(wireFrames.startSession, AGENT),
		},
		{
			id: "ss-out-d",
			t: 400,
			kind: "message-delivered",
			messageId: "ss-out",
		},
		{
			id: "ss-back",
			t: 500,
			kind: "message-sent",
			messageId: "ss-back",
			sessionId: "59b79ed34e6ede4e56486b962eb594e572b6841841196bef3eb37d9949a3fa8c",
			from: "127.0.0.1:9202",
			to: "127.0.0.1:9201",
			arrivalT: 700,
			label: "op:start-session",
			...payloadOf(wireFrames.startSession, AGENT),
		},
		{
			id: "ss-back-d",
			t: 700,
			kind: "message-delivered",
			messageId: "ss-back",
		},
		{
			id: "session-open",
			t: 700,
			kind: "session-state-changed",
			sessionId: "59b79ed34e6ede4e56486b962eb594e572b6841841196bef3eb37d9949a3fa8c",
			state: "open",
		},
		{
			id: "fetch",
			t: 1100,
			kind: "message-sent",
			messageId: "fetch",
			sessionId: "59b79ed34e6ede4e56486b962eb594e572b6841841196bef3eb37d9949a3fa8c",
			from: "127.0.0.1:9201",
			to: "127.0.0.1:9202",
			arrivalT: 1500,
			label: "op:deliver bootstrap.fetch('thermostat')",
		},
		{
			id: "fetch-d",
			t: 1500,
			kind: "message-delivered",
			messageId: "fetch",
		},
		{
			id: "fetch-resolve",
			t: 1800,
			kind: "message-sent",
			messageId: "fetch-resolve",
			sessionId: "59b79ed34e6ede4e56486b962eb594e572b6841841196bef3eb37d9949a3fa8c",
			from: "127.0.0.1:9202",
			to: "127.0.0.1:9201",
			arrivalT: 2200,
			label: "op:resolve fulfill(thermostat)",
		},
		{
			id: "fetch-resolve-d",
			t: 2200,
			kind: "message-delivered",
			messageId: "fetch-resolve",
		},
	],
});
