// What a producer says it runs, and what the far end of a session is.

import { assert, assertEquals } from "@std/assert";
import { makeBaseEventConverter } from "../feed.ts";
import { GLOWCAP_PROFILE, GOBLINS_PROFILE, UNNAMED_PROFILE } from "../../../schema/topology.ts";
import { Observation } from "../../temporal/recording.ts";
import type { TimelineEvent } from "../../timeline.ts";
import { expectKind } from "./harness.ts";
import { joinedProfiles, opened, SAYS_GLOWCAP, wireName } from "./fixtures.ts";

/** Every profile a `peer-updated` stated, in order, as `peer@t=profile`. */
function profileUpdates(evs: readonly TimelineEvent[]): string[] {
	const out: string[] = [];
	for (const ev of evs) {
		if (ev.kind === "peer-updated" && ev.profile !== undefined) {
			out.push(`${ev.peerId}@${ev.t}=${ev.profile}`);
		}
	}
	return out;
}

Deno.test("a producer's own end runs what it says it runs", () => {
	// A producer states its implementation beside the designator it calls
	// itself by, and that statement is the whole of what names its own end.
	// What is on the FAR end of an OCapN v1.0 session is a different question
	// the record does not answer, so that end stays unknown.
	const convert = makeBaseEventConverter();
	const out = convert(
		opened(0, "p0/s1", "rooms-key", "vat-key", "wire-1", true, {
			profile: GLOWCAP_PROFILE,
		}),
	);
	assertEquals(joinedProfiles(out), {
		"rooms-key": GLOWCAP_PROFILE,
		"vat-key": UNNAMED_PROFILE,
	});
});

Deno.test("a Goblins vat publishing its own trace draws as a Goblins vat", () => {
	// The `ocapn.*` kinds are a schema, not glowcap's mark: the Goblins
	// conformance peer publishes the very same records. Its own end is drawn
	// as what it says it is, and the stage has to be able to say `goblins`
	// when a producer says `goblins` — the whole point of reading a statement
	// instead of guessing at one.
	const convert = makeBaseEventConverter();
	const out = convert(
		opened(0, "p0/s1", "vat-key", "rooms-key", "wire-1", true, {
			profile: GOBLINS_PROFILE,
		}),
	);
	assertEquals(joinedProfiles(out), {
		"vat-key": GOBLINS_PROFILE,
		"rooms-key": UNNAMED_PROFILE,
	});
});

Deno.test("a producer that states nothing draws its OWN end unknown", () => {
	// The defect this whole property exists to refuse, at the site it lived:
	// the viewer used to read "a record arrived" as "a glowcap host sent it",
	// so every producer's own end was drawn glowcap whatever it ran. A
	// producer that says nothing has said nothing about itself, and unknown
	// is the honest answer for a glowcap producer and any other alike.
	const convert = makeBaseEventConverter();
	const out = convert(
		opened(0, "p0/s1", "rooms-key", "vat-key", "wire-1", true),
	);
	assertEquals(joinedProfiles(out), {
		"rooms-key": UNNAMED_PROFILE,
		"vat-key": UNNAMED_PROFILE,
	});
	// And nothing arrives later to fill it in either: a second session from
	// the same silent producer is one more record that said nothing.
	assertEquals(
		profileUpdates(
			convert(
				opened(500, "p0/s2", "rooms-key", "other-key", "wire-2", true),
			),
		),
		[],
	);
});

Deno.test("an implementation this build has never heard of is drawn as itself", () => {
	// `PeerProfile` is any non-empty string on purpose, because OCapN is
	// implementation-plural and the set of implementations is not this
	// viewer's to close. A third implementation naming itself is drawn under
	// the name it gave, not folded into unknown.
	const convert = makeBaseEventConverter();
	const out = convert(
		opened(0, "p0/s1", "vat-key", "rooms-key", "wire-1", true, {
			profile: "some-other-captp",
		}),
	);
	assertEquals(joinedProfiles(out)["vat-key"], "some-other-captp");
});

Deno.test("a non-string implementation claim is ignored", () => {
	// The profile field is open-ended, but it is still a string field on a JSON
	// feed. A producer that sends a number has not named a future
	// implementation; it sent invalid data, so the peer stays unknown.
	const convert = makeBaseEventConverter();
	const out = convert({
		v: 1,
		sim_t_ns: 0,
		kind: "ocapn.session-opened",
		session: "p0/s1",
		a: "vat-key",
		b: "rooms-key",
		session_id: "wire-1",
		provenance: "authenticated-transport",
		codec: "syrup",
		a_profile: 1,
	});
	assertEquals(joinedProfiles(out)["vat-key"], UNNAMED_PROFILE);
});

Deno.test("a session on the glowcap-private profile names both its ends", () => {
	// `glowcap-next` travels only between glowcap peers (ADR-0003), so one
	// producer reporting it has said what runs at each end. It is the one
	// implementation a feed concludes without being told, so it holds even
	// when the producer stated nothing about itself.
	const convert = makeBaseEventConverter();
	const out = convert(
		opened(0, "p0/s1", "rooms-key", "member-key", "wire-1", true, {
			captp: "next",
		}),
	);
	assertEquals(joinedProfiles(out), {
		"rooms-key": GLOWCAP_PROFILE,
		"member-key": GLOWCAP_PROFILE,
	});
});

Deno.test("the v1.0 floor names neither of its ends", () => {
	// The converse of the profile above, and the reason it is not read: two
	// glowcap peers meeting on the OCapN interop floor speak `v1_0`, exactly
	// as a Goblins vat does. A session on it says nothing about either end,
	// so a feed that carries no statement draws two unknowns.
	const convert = makeBaseEventConverter();
	const out = convert(
		opened(0, "p0/s1", "rooms-key", "member-key", "wire-1", true, {
			captp: "v1_0",
		}),
	);
	assertEquals(joinedProfiles(out), {
		"rooms-key": UNNAMED_PROFILE,
		"member-key": UNNAMED_PROFILE,
	});
});

Deno.test("a partner nobody speaks for is never credited with an implementation", () => {
	// The defect this whole property guards against is the stage answering a
	// question the feed never asked. A v1.0 partner that publishes nothing has
	// to stay unknown for as long as the feed runs, however much traffic
	// crosses the session.
	const convert = makeBaseEventConverter();
	const out = [
		...convert(opened(0, "p0/s1", "rooms-key", "vat-key", "wire-1", true)),
		...convert({
			v: 1,
			sim_t_ns: 20_000_000,
			kind: "ocapn.message-decoded",
			session: "p0/s1",
			outbound: true,
			op: "op:deliver",
		}),
		...convert({
			v: 1,
			sim_t_ns: 40_000_000,
			kind: "ocapn.session-closed",
			session: "p0/s1",
		}),
	];
	assertEquals(joinedProfiles(out)["vat-key"], UNNAMED_PROFILE);
	assertEquals(profileUpdates(out), []);
});

Deno.test("a peer learns what it runs when it first speaks for itself", () => {
	// The rooms case: one host reports a member before that member has
	// published anything, so the member is drawn as somebody else's partner and
	// nothing yet says what it runs. When the member's own trace arrives it has
	// stated its implementation, and that lands as a moment on its trajectory —
	// the join keeps saying what was known then.
	const convert = makeBaseEventConverter();
	const first = convert(
		opened(
			0,
			"p0/s1",
			"rooms-key",
			"member-key",
			"wire-1",
			true,
			SAYS_GLOWCAP,
		),
	);
	assertEquals(joinedProfiles(first)["member-key"], UNNAMED_PROFILE);

	const later = convert(
		opened(
			750,
			"p1/s1",
			"member-key",
			"other-key",
			"wire-2",
			true,
			SAYS_GLOWCAP,
		),
	);
	assertEquals(profileUpdates(later), ["member-key@750=glowcap"]);
	// Learning is not a re-join: the peer keeps the one lifetime it had.
	assertEquals(
		later.filter((e) => e.kind === "peer-joined").map((e) => expectKind(e, "peer-joined").peerId),
		["other-key"],
	);
});

Deno.test("a named partner that then reports the same wire is known from there", () => {
	// A room server whose transport authenticated the member's durable name
	// draws that member straight away — named, but with nothing yet saying what
	// it runs. When the member publishes its own side of that same session it
	// states its implementation, and the second report of one wire is the only
	// thing that carries the statement. There is no new peer and no new edge
	// here, so the learning has nowhere else to land.
	const convert = makeBaseEventConverter();
	const first = convert(
		opened(
			0,
			"p0/s1",
			"rooms-key",
			"member-key",
			"shared-wire",
			true,
			SAYS_GLOWCAP,
		),
	);
	assertEquals(joinedProfiles(first)["member-key"], UNNAMED_PROFILE);

	const second = convert(
		opened(
			600,
			"p1/s1",
			"member-key",
			"rooms-key",
			"shared-wire",
			true,
			SAYS_GLOWCAP,
		),
	);
	assertEquals(second.filter((e) => e.kind === "peer-joined"), []);
	assertEquals(profileUpdates(second), ["member-key@600=glowcap"]);
});

Deno.test("an end a second producer speaks for is drawn as what that producer says it runs", () => {
	// Two browser tabs in a room, the shape the endpoint actually carries.
	// Neither can name the other: a tab dials as an ephemeral client and has no
	// listening address to prove, so the first report leaves its far end loose.
	// The second producer says it is that end AND says what it runs, so the end
	// attaches to a peer that is known from the moment it is drawn — known
	// because of the second half of that sentence, never the first.
	const convert = makeBaseEventConverter();
	const first = convert(
		opened(0, "p0/s1", "tab-a", "claimed:0", "shared-wire", false, {
			profile: GLOWCAP_PROFILE,
		}),
	);
	assertEquals(joinedProfiles(first), { "tab-a": GLOWCAP_PROFILE });

	const second = convert(
		opened(400, "p1/s1", "tab-b", "claimed:0", "shared-wire", false, {
			profile: GOBLINS_PROFILE,
		}),
	);
	// Speaking for the loose end draws the peer, and it is drawn as what its
	// own producer said — a Goblins vat here, which the old rule could not
	// have reported however loudly the vat said it.
	assertEquals(joinedProfiles(second), { "tab-b": GOBLINS_PROFILE });
	// Both ends now sit on peers, and neither had to learn anything after.
	assertEquals(profileUpdates(second), []);
});

Deno.test("speaking for a loose end says who is there, never what is there", () => {
	// The same shape with the second producer silent. It still attaches to the
	// end nobody could name — that is a fact about identity — and the peer it
	// draws stays unknown, because attaching an end is not a statement about
	// what runs on it.
	const convert = makeBaseEventConverter();
	convert(opened(0, "p0/s1", "tab-a", "claimed:0", "shared-wire", false));
	const second = convert(
		opened(400, "p1/s1", "tab-b", "claimed:0", "shared-wire", false),
	);
	assertEquals(joinedProfiles(second), { "tab-b": UNNAMED_PROFILE });
	assertEquals(profileUpdates(second), []);
	// The end really did attach: this is the loose-end path, not a miss.
	assertEquals(
		second.filter((e) => e.kind === "session-endpoint-attributed").length,
		1,
	);
});

Deno.test("restating what a peer runs is not a moment on its trajectory", () => {
	// A producer reports every session it holds, and a busy host holds many.
	// Only the moment the viewer LEARNED belongs on the trajectory; the same
	// rule the ledger holds for a name it has already been told.
	const convert = makeBaseEventConverter();
	const out = [
		...convert(
			opened(0, "p0/s1", "host-key", "peer-key", "wire-1", true, {
				captp: "next",
			}),
		),
		...convert(
			opened(900, "p0/s2", "host-key", "peer-key", "wire-2", true, {
				captp: "next",
			}),
		),
	];
	assertEquals(profileUpdates(out), []);
});

Deno.test("an end says what actually backed it, and nothing when nothing did", () => {
	// The stage may state only what the feed measured. Three producers report
	// three sessions and the far end of each is attached for a different reason,
	// so each end has to say a different thing.
	const convert = makeBaseEventConverter();
	const open = (
		session: string,
		partner: string,
		provenance: string | undefined,
	) => expectKind(
		convert({
			v: 1,
			sim_t_ns: 0,
			kind: "ocapn.session-opened",
			session,
			a: "rooms-key",
			b: partner,
			codec: "syrup",
			...(provenance !== undefined ? { provenance } : {}),
		}).find((e) => e.kind === "session-opened"),
		"session-opened",
	);
	// A verdict the producer measured is carried across in its own words.
	assertEquals(
		open("p0/s1", "alice-key", "authenticated-transport").b.attributedBy,
		"authenticated-transport",
	);
	// A producer that named its partner and said nothing about proof measured
	// nothing. The end still attaches — somebody named it — but the viewer has
	// no attribution to offer, and inventing one would be the stage reporting a
	// measurement that never happened.
	const silent = open("p0/s2", "bob-key", undefined);
	assertEquals(silent.b.peer, "bob-key");
	assertEquals(
		silent.b.attributedBy,
		undefined,
		"a producer that stated no verdict had one attributed to it",
	);
	// A word out of a vocabulary this viewer does not know proved nothing
	// either, so the end stays loose with its claim on it.
	const unknown = open("p0/s3", "carol-key", "vouched-for-by-a-friend");
	assertEquals(unknown.b.peer, undefined);
	assertEquals(unknown.b.designator, "carol-key");
	assertEquals(unknown.b.attributedBy, undefined);
});

Deno.test("an end two producers agreed on says the viewer correlated it", () => {
	// The one attribution the viewer awards itself. A room cannot name the tab
	// that dialed it; the tab's own report of the same wire can, and a snapshot
	// holds both before anything is drawn. That is a correlation across two
	// self-reports rather than a proof, and the end says so in the weakest word
	// the vocabulary has.
	const convert = makeBaseEventConverter();
	const wire = wireName("k");
	const out: TimelineEvent[] = [];
	out.push(...convert({
		...opened(0, "p0/s1", "rooms-key", "127.0.0.1:0", wire, false),
		replay: true,
	}));
	out.push(...convert({
		...opened(1, "p1/s1", "tab-key", "rooms-key", wire, true),
		replay: true,
	}));
	out.push(
		...convert({ v: 1, sim_t_ns: 2_000_000, kind: "trace.replay-end" }),
	);
	const room = expectKind(
		out.find((e) => e.kind === "session-opened"),
		"session-opened",
	);
	assertEquals(room.b.peer, "tab-key");
	assertEquals(room.b.attributedBy, "viewer-correlated");
});

Deno.test("the netlayer a session runs over reaches the stage", () => {
	// A designator is half a name: the same key reached over `iroh` and
	// over `keyed-relay` is two locators, so the producer reports the
	// transport beside it and the viewer has to carry it across. The
	// Inspector reads it off this observation, so dropping it here is
	// the whole difference between a session that names its netlayer
	// and one that says nothing about it.
	const convert = makeBaseEventConverter();
	const out = convert({
		v: 1,
		sim_t_ns: 0,
		kind: "ocapn.session-opened",
		session: "p0/s1",
		a: "alice-key",
		b: "bob-key",
		transport: "iroh",
		codec: "syrup",
	});
	const session = expectKind(out[2], "session-opened");
	assertEquals(session.transport, "iroh");
	// And it survives the schema, which is where a live document is
	// eventually read back from.
	assertEquals(Observation.parse(session).kind, "session-opened");
});

Deno.test("a producer that names no netlayer leaves the field off", () => {
	// The field is optional because a producer predating it reports
	// sessions and nothing else changed about them. Absent has to stay
	// absent rather than becoming an empty netlayer name: `""` is not a
	// transport, and a document carrying one would show a blank row
	// where the honest answer is no row.
	const convert = makeBaseEventConverter();
	const older = expectKind(
		convert({
			v: 1,
			sim_t_ns: 0,
			kind: "ocapn.session-opened",
			session: "p0/s1",
			a: "alice-key",
			b: "bob-key",
			codec: "syrup",
		})[2],
		"session-opened",
	);
	assert(
		!("transport" in older),
		"a producer that reported no transport minted no transport field",
	);
	assertEquals(Observation.parse(older).kind, "session-opened");
	// A producer that sends the field empty said the same thing.
	const empty = expectKind(
		convert({
			v: 1,
			sim_t_ns: 0,
			kind: "ocapn.session-opened",
			session: "p0/s2",
			a: "alice-key",
			b: "carol-key",
			transport: "",
			codec: "syrup",
		})[1],
		"session-opened",
	);
	assert(
		!("transport" in empty),
		"an empty transport is no transport, not a netlayer called ''",
	);
	const nonString = expectKind(
		convert({
			v: 1,
			sim_t_ns: 0,
			kind: "ocapn.session-opened",
			session: "p0/s3",
			a: "alice-key",
			b: "dave-key",
			transport: 1,
			codec: "syrup",
		})[1],
		"session-opened",
	);
	assert(
		!("transport" in nonString),
		"a non-string transport is invalid data, not a future netlayer",
	);
});
