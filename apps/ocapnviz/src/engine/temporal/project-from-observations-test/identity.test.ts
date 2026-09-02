/**
 * What observations write onto entities besides spans: a live name,
 * an end that attaches when something backs it, a designator, a
 * netlayer — and the authored value that outranks the wire.
 */

import { assertEquals } from "@std/assert";
import { attachedEndpoint, sessionEndpoint } from "../../../schema/session-end.ts";
import type { TimelineEvent } from "../../timeline.ts";
import { projectFromObservations } from "../project-from-observations.ts";
import { peerLabelAt, sessionEffective, sessionEndpointPlaceAt } from "../doc-resolver.ts";
import { emptyDoc, joinedPeerDoc, withEvents } from "./harness.ts";

Deno.test("live: a late-arriving peer-updated keyframes the new name", () => {
	// The annotation arrives after the join by construction (the app
	// learns the nick at registration), so the name is a temporal
	// fact: the peer answers to its locator until t=50 and to "carol"
	// from there on. Folding the last label into the def instead would
	// rewrite the whole timeline, and a replay would never show the
	// locator the live viewer saw.
	const once = projectFromObservations(joinedPeerDoc());
	assertEquals(once.entities?.peers?.["127.0.0.1:0"]?.label, "127.0.0.1:0");
	once.recording?.sources[0]?.observations.push({
		id: "e2",
		kind: "peer-updated",
		t: 50,
		peerId: "127.0.0.1:0",
		label: "carol",
	});
	const twice = projectFromObservations(once);
	const def = twice.entities?.peers?.["127.0.0.1:0"];
	assertEquals(def?.label, "127.0.0.1:0");
	assertEquals(def?.keyframes?.label, [{ t: 50, value: "carol" }]);
	assertEquals(peerLabelAt(twice, "127.0.0.1:0", 49), "127.0.0.1:0");
	assertEquals(peerLabelAt(twice, "127.0.0.1:0", 50), "carol");
});

Deno.test("live: every peer-updated lands, in time order", () => {
	const doc = joinedPeerDoc();
	doc.recording?.sources[0]?.observations.push(
		{
			id: "e2",
			kind: "peer-updated",
			t: 50,
			peerId: "127.0.0.1:0",
			label: "carol",
		},
		{
			id: "e3",
			kind: "peer-updated",
			t: 70,
			peerId: "127.0.0.1:0",
			label: "carol-away",
		},
	);
	const out = projectFromObservations(doc);
	assertEquals(out.entities?.peers?.["127.0.0.1:0"]?.keyframes?.label, [
		{ t: 50, value: "carol" },
		{ t: 70, value: "carol-away" },
	]);
	assertEquals(peerLabelAt(out, "127.0.0.1:0", 60), "carol");
	assertEquals(peerLabelAt(out, "127.0.0.1:0", 80), "carol-away");
});

Deno.test("live: dropping the renaming observation drops its keyframe", () => {
	// The observation stream is the authority in both directions —
	// a track that outlived the observation behind it would keep
	// renaming the peer with nothing left to point at.
	const doc = joinedPeerDoc();
	const observations = doc.recording?.sources[0]?.observations;
	observations?.push({
		id: "e2",
		kind: "peer-updated",
		t: 50,
		peerId: "127.0.0.1:0",
		label: "carol",
	});
	const named = projectFromObservations(doc);
	assertEquals(peerLabelAt(named, "127.0.0.1:0", 60), "carol");

	observations?.pop();
	const unnamed = projectFromObservations(named);
	assertEquals(
		unnamed.entities?.peers?.["127.0.0.1:0"]?.keyframes,
		undefined,
	);
	assertEquals(peerLabelAt(unnamed, "127.0.0.1:0", 60), "127.0.0.1:0");
});

Deno.test("live: re-projecting an unchanged label track keeps the doc", () => {
	// The projection runs every engine tick; a quiet run must return
	// the same doc object, because the engine rebinds layout on
	// identity change.
	const doc = joinedPeerDoc();
	doc.recording?.sources[0]?.observations.push({
		id: "e2",
		kind: "peer-updated",
		t: 50,
		peerId: "127.0.0.1:0",
		label: "carol",
	});
	const once = projectFromObservations(doc);
	assertEquals(projectFromObservations(once), once);
});

Deno.test("attributing an end attaches it, and keeps the session's span", () => {
	// The live shape this vocabulary exists for. A peer accepts a connection it
	// cannot attribute, so the session is drawn with that end attached to
	// nobody, carrying only what the far side claimed. When something finally
	// backs the claim, the end attaches to the peer it named. What must NOT
	// happen is the session ending — nothing on the wire closed.
	const doc = withEvents(emptyDoc(), [
		{
			id: "e1",
			t: 0,
			kind: "peer-joined",
			peerId: "alice",
			profile: "glowcap",
		},
		{
			id: "e2",
			t: 0,
			kind: "peer-joined",
			peerId: "bob",
			profile: "glowcap",
		},
		{
			id: "e4",
			t: 10,
			kind: "session-opened",
			sessionId: "w1",
			a: attachedEndpoint("bob"),
			b: sessionEndpoint({ designator: "alice" }),
			codec: "syrup",
			captpVersion: "v1_0",
			initialState: "open",
		},
		{
			id: "e5",
			t: 20,
			kind: "session-endpoint-attributed",
			sessionId: "w1",
			side: "b",
			peerId: "alice",
			attributedBy: "verified-handoff",
		},
	]);
	const out = projectFromObservations(doc);

	// The end is a track on the session, and the session opened with that end
	// attached to nobody.
	assertEquals(out.entities?.sessions?.w1?.b?.peer, undefined);
	assertEquals(out.entities?.sessions?.w1?.keyframes?.b, [{
		t: 20,
		value: { peer: "alice", attributedBy: "verified-handoff" },
	}]);
	assertEquals(sessionEndpointPlaceAt(out, "w1", "b", 15).peer, undefined);
	assertEquals(sessionEndpointPlaceAt(out, "w1", "b", 20).peer, "alice");
	assertEquals(sessionEndpointPlaceAt(out, "w1", "a", 20).peer, "bob");

	// No peer was born or died to carry the claim, which is the whole point:
	// the only thing that changed is which peer the session's end names.
	// Alice's row is open-ended — an implicit duration, the shape a peer
	// with no ending observation gets.
	assertEquals(out.entities?.peers?.["alice"]?.timing?.duration, {
		value: 0,
		explicit: false,
	});

	// And the session is still open past that moment.
	const eff = sessionEffective(out, "w1");
	assertEquals(eff.start, 10);
	assertEquals(eff.end, Infinity);
});

Deno.test("a peer that departs AND goes unobserved ends at the first of the two", () => {
	// Both dispositions on one row is not a shape the ledger produces, but the
	// projection reads whatever the recording holds, and a row has one end.
	const doc = withEvents(emptyDoc(), [
		{
			id: "e1",
			t: 0,
			kind: "peer-joined",
			peerId: "alice",
			profile: "glowcap",
		},
		{ id: "e2", t: 30, kind: "peer-left", peerId: "alice" },
		{ id: "e3", t: 20, kind: "peer-unobserved", peerId: "alice" },
	]);
	const out = projectFromObservations(doc);
	assertEquals(out.entities?.peers?.["alice"]?.timing?.duration, {
		value: 20,
		explicit: true,
	});
});

Deno.test("a peer's identifier comes from the join that drew it", () => {
	// The join is the only observation that states one, because a peer only
	// ever reaches the stage under a name somebody stated
	// (`StageLedger.ensurePeer`). A peer drawn without one has none, and
	// nothing arrives later to supply a first: an author edits the durable
	// name on the definition and the join beside it (`authoring/peer.ts`), so
	// the fact keeps one home.
	const doc = withEvents(emptyDoc(), [
		{
			id: "e1",
			kind: "peer-joined",
			t: 5,
			peerId: "alice",
			profile: "glowcap",
			designator: "joined-as",
		},
		{
			id: "e2",
			kind: "peer-joined",
			t: 5,
			peerId: "nobody",
			profile: "glowcap",
		},
	] as TimelineEvent[]);
	const peers = projectFromObservations(doc).entities?.peers;
	assertEquals(peers?.alice?.designator, "joined-as");
	assertEquals(peers?.nobody?.designator, undefined);
});

Deno.test("a session's netlayer comes from the open that reported it", () => {
	// One session runs over one netlayer, and the opening observation is
	// where a producer says which. The definition is what every reader
	// and the Build picker consult, so the fact has to arrive there; a
	// session whose open reported no transport carries none, which is a
	// real recording and not a missing value.
	const doc = withEvents(emptyDoc(), [
		{
			id: "e1",
			kind: "session-opened",
			t: 2,
			sessionId: "over-iroh",
			a: attachedEndpoint("alice"),
			b: attachedEndpoint("bob"),
			transport: "iroh",
			codec: "capnp",
			captpVersion: "v1_0",
		},
		{
			id: "e2",
			kind: "session-opened",
			t: 2,
			sessionId: "unstated",
			a: attachedEndpoint("alice"),
			b: attachedEndpoint("bob"),
			codec: "capnp",
			captpVersion: "v1_0",
		},
	] as TimelineEvent[]);
	const sessions = projectFromObservations(doc).entities?.sessions;
	assertEquals(sessions?.["over-iroh"]?.transport, "iroh");
	assertEquals(sessions?.["unstated"]?.transport, undefined);
});

Deno.test("an authored netlayer outranks the one the open reported", () => {
	// The cascade the codec and the CapTP version already take: a
	// declared entity entry wins, and the observation only fills a
	// session the document has not declared. Without it an author's
	// edit would be undone by the next projection run.
	const doc = withEvents({
		...emptyDoc(),
		entities: {
			sessions: {
				s1: {
					a: attachedEndpoint("alice"),
					b: attachedEndpoint("bob"),
					transport: "webrtc",
					codec: "capnp",
					captpVersion: "v1_0",
				},
			},
		},
	}, [
		{
			id: "e1",
			kind: "session-opened",
			t: 2,
			sessionId: "s1",
			a: attachedEndpoint("alice"),
			b: attachedEndpoint("bob"),
			transport: "tcp",
			codec: "capnp",
			captpVersion: "v1_0",
		},
	] as TimelineEvent[]);
	assertEquals(
		projectFromObservations(doc).entities?.sessions?.s1?.transport,
		"webrtc",
	);
});
