import { TimelineDocument } from "../engine/timeline.ts";
import { payloadOf, wireFrames } from "./wire-frames.ts";

/**
 * Chapter 06, Poke me when it's ready (op:listen).
 *
 * A video editor uploads a clip to a transcoder. Encode takes a
 * long time. Editor installs a listener on the unresolved answer
 * via `op:listen`. When the transcoder eventually resolves, the
 * runtime fires a Deliver to the editor's callback with the encoded
 * clip's reference.
 *
 * On the wire: the editor is at `127.0.0.1:9601` and the transcoder at
 * `127.0.0.1:9602`, over plain `tcp`. The editor's end is its own
 * report. The transcoder's end is attached by the two hosts' traces
 * agreeing on one OCapN Session ID.
 * Both peers run glowcap, so this session settles on Cap'n Proto over
 * glowcap-next. That is the pairing a glowcap fleet configures
 * (`HostRuntime.Options.codec` / `.captp_version` in `src/driver/host_runtime.zig`). The
 * Syrup / OCapN 1.0 baseline is what a session settles on the moment a peer
 * at either end cannot follow.
 */

const AGENT = "ocapnviz:fixtures/06-poke-me-when-ready";

export const pokeMeWhenReady = TimelineDocument.parse({
	id: "06-poke-me-when-ready",
	metadata: {
		"dct:title": "06 · Poke me when ready",
		"dct:description":
			'A video editor uploads a clip, and the transcode takes minutes. Rather than ask again and again, the editor leaves an op:listen on the answer that has not arrived. The transcoder resolves whenever it is ready, and the runtime delivers the result to the editor\'s callback. This is how a program says "tell me when".',
		"dct:creator": "glowcap project",
		"dct:created": "2026-05-14T00:00:00Z",
	},
	provenance: { "prov:wasAttributedTo": AGENT },
	duration: 5500,
	events: [
		{
			id: "editor-joins",
			t: 0,
			kind: "peer-joined",
			peerId: "127.0.0.1:9601",
			label: "Video editor",
			profile: "glowcap",
			designator: "127.0.0.1:9601",
		},
		{
			id: "transcoder-joins",
			t: 0,
			kind: "peer-joined",
			peerId: "127.0.0.1:9602",
			label: "Transcoder",
			profile: "glowcap",
			designator: "127.0.0.1:9602",
		},
		{
			id: "session-opens",
			t: 0,
			kind: "session-opened",
			sessionId: "3ee12f66aa2537fbbffdfacfa3c244b29652261abcbe52d53593bed44884b727",
			a: {
				peer: "127.0.0.1:9601",
				designator: "127.0.0.1:9601",
				attributedBy: "self-reported",
			},
			b: {
				peer: "127.0.0.1:9602",
				designator: "127.0.0.1:9602",
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
			sessionId: "3ee12f66aa2537fbbffdfacfa3c244b29652261abcbe52d53593bed44884b727",
			from: "127.0.0.1:9601",
			to: "127.0.0.1:9602",
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
			sessionId: "3ee12f66aa2537fbbffdfacfa3c244b29652261abcbe52d53593bed44884b727",
			from: "127.0.0.1:9602",
			to: "127.0.0.1:9601",
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
			sessionId: "3ee12f66aa2537fbbffdfacfa3c244b29652261abcbe52d53593bed44884b727",
			state: "open",
		},
		{
			id: "transcode",
			t: 1100,
			kind: "message-sent",
			messageId: "transcode",
			sessionId: "3ee12f66aa2537fbbffdfacfa3c244b29652261abcbe52d53593bed44884b727",
			from: "127.0.0.1:9601",
			to: "127.0.0.1:9602",
			arrivalT: 1500,
			label: "op:deliver transcode(clip)",
		},
		{
			id: "transcode-d",
			t: 1500,
			kind: "message-delivered",
			messageId: "transcode",
		},
		{
			id: "listen",
			t: 1700,
			kind: "message-sent",
			messageId: "listen",
			sessionId: "3ee12f66aa2537fbbffdfacfa3c244b29652261abcbe52d53593bed44884b727",
			from: "127.0.0.1:9601",
			to: "127.0.0.1:9602",
			arrivalT: 2000,
			label: "op:listen promise(transcode), callback",
		},
		{
			id: "listen-d",
			t: 2000,
			kind: "message-delivered",
			messageId: "listen",
		},
		// Long encode. The gap between t=2000 (listen lands) and
		// t=4000 (resolve) stands in for the 40s real-world transcode.
		{
			id: "transcode-resolve",
			t: 4000,
			kind: "message-sent",
			messageId: "transcode-resolve",
			sessionId: "3ee12f66aa2537fbbffdfacfa3c244b29652261abcbe52d53593bed44884b727",
			from: "127.0.0.1:9602",
			to: "127.0.0.1:9601",
			arrivalT: 4400,
			label: "op:resolve fulfill(encoded-clip)",
		},
		{
			id: "transcode-resolve-d",
			t: 4400,
			kind: "message-delivered",
			messageId: "transcode-resolve",
		},
		{
			id: "listener-fire",
			t: 4500,
			kind: "message-sent",
			messageId: "listener-fire",
			sessionId: "3ee12f66aa2537fbbffdfacfa3c244b29652261abcbe52d53593bed44884b727",
			from: "127.0.0.1:9602",
			to: "127.0.0.1:9601",
			arrivalT: 4800,
			label: "op:deliver callback(encoded-clip)  (listener fire)",
		},
		{
			id: "listener-fire-d",
			t: 4800,
			kind: "message-delivered",
			messageId: "listener-fire",
		},
	],
});
