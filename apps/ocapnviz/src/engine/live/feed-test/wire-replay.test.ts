// Two ends of one wire: a snapshot draws what live learning draws.

import { assert, assertEquals } from "@std/assert";
import { makeBaseEventConverter } from "../feed.ts";
import { type BaseTimelineEvent } from "../record.ts";
import { sessionEndpoint } from "../../../schema/session-end.ts";
import type { TimelineEvent } from "../../timeline.ts";
import { expectKind } from "./harness.ts";
import {
	AS_STAMPED,
	DM_WIRE,
	joinedProfiles,
	NAMING_FIRST,
	opened,
	pictureOf,
	ROOM_WIRE_1,
	ROOM_WIRE_2,
	runThrough,
	wireName,
} from "./fixtures.ts";

Deno.test("a replayed snapshot draws what a feed that never had to learn draws", () => {
	// Stop a recording and start another, and the viewer asks for the topology
	// again. The endpoint answers with every live session's open — and one wire
	// is TWO of those, because both its ends report it. Fed one at a time, that
	// re-runs the live learning sequence: an end drawn loose, then the moment it
	// attached. Live that sequence is honest, because the far end's report had
	// not arrived. On a snapshot it is not: both ends are in the batch before
	// anything is drawn, so there is no moment at which the viewer did not know.
	//
	// The bar is not "no blip" — an absent symptom would also be met by a
	// snapshot path that quietly drew something else. It is that the snapshot
	// lands on exactly the picture a feed draws when it is told the naming end
	// first and never has to learn anything. Same construction, same end state,
	// fewer events.
	const snapshot = makeBaseEventConverter();
	const resolved: TimelineEvent[] = [];
	for (const ev of AS_STAMPED) {
		resolved.push(...snapshot({ ...ev, replay: true }));
	}
	resolved.push(...snapshot({
		v: 1,
		sim_t_ns: 6_000_000,
		kind: "trace.replay-end",
	}));

	assertEquals(
		pictureOf(resolved),
		pictureOf(runThrough(NAMING_FIRST)),
		"a resolved snapshot draws exactly what a feed that never had to learn draws",
	);
	// Three peers and three sessions, so the comparison above is comparing
	// something rather than two empty pictures.
	assertEquals(pictureOf(resolved).peers.length, 3);
	assertEquals(pictureOf(resolved).edges.length, 3);

	// And it says nothing it did not do. These are the viewer's own knowledge
	// events; a batch that held both ends before it drew never learned.
	assertEquals(
		resolved.filter((e) => e.kind === "session-endpoint-attributed").length,
		0,
		"a resolved snapshot has no end attaching to report: it held both ends " +
			"before it drew anything",
	);
	assertEquals(
		resolved.filter((e) => e.kind === "session-opened" && e.b.peer === undefined)
			.length,
		0,
		"a resolved snapshot leaves no end loose: it knew both before it drew",
	);
});

Deno.test("a room whose every end publishes is a room of glowcap peers", () => {
	// The case the user actually watches: a room server and two browser tabs,
	// each publishing its own trace, on the OCapN v1.0 floor. Every peer here
	// is some producer's own end, so every peer is known — reached through the
	// snapshot, where the batch holds both ends of each wire before it draws,
	// and through the live order, where the second end has to be learned.
	const snapshot = makeBaseEventConverter();
	const resolved: TimelineEvent[] = [];
	for (const ev of AS_STAMPED) {
		resolved.push(...snapshot({ ...ev, replay: true }));
	}
	resolved.push(...snapshot({
		v: 1,
		sim_t_ns: 6_000_000,
		kind: "trace.replay-end",
	}));

	const drawnAs = joinedProfiles(resolved);
	assertEquals(Object.keys(drawnAs).length, 3);
	assertEquals(
		Object.values(drawnAs).filter((p) => p !== "glowcap"),
		[],
		"a snapshot holding every end's own report drew a peer it could not name",
	);

	// Live, the same three peers arrive one report at a time, so one of them is
	// drawn before its own producer has spoken. It is known by the end of the
	// sequence either way — through its join or through the moment it learned.
	const live = runThrough(AS_STAMPED);
	const liveJoined = joinedProfiles(live);
	const learned = new Set(
		live.flatMap((e) => e.kind === "peer-updated" && e.profile !== undefined ? [e.peerId] : []),
	);
	for (const [peer, joined] of Object.entries(liveJoined)) {
		assert(
			joined === "glowcap" || learned.has(peer),
			`${peer} publishes its own trace and is still not known to be glowcap`,
		);
	}
});

Deno.test("the same reports arriving live still learn, and say so", () => {
	// The contrast the test above rests on. Fed one at a time in the order the
	// endpoint stamped them, the very same reports DO make the viewer learn —
	// so the snapshot's silence is a property of the batch, not of the records.
	const live = runThrough(AS_STAMPED);
	assert(
		live.some((e) => e.kind === "session-endpoint-attributed"),
		"a live feed told the accepting end first has to learn who dialed",
	);
	assert(
		live.some((e) =>
			e.kind === "session-opened" && e.b.peer === undefined &&
			e.b.designator !== undefined
		),
		"and it holds that end loose, carrying the claim, until it does",
	);
	// Same topology either way: three peers, three edges. What differs is only
	// that the live path had to be told the second half.
	assertEquals(pictureOf(live).edges.length, 3);
	assertEquals(pictureOf(live).peers.length, 3);
});

Deno.test("an empty snapshot, and a batch nobody closes, both land", () => {
	// Two shapes the boundary has to survive. A viewer connecting to an idle
	// endpoint gets the mark with nothing before it. And a producer predating
	// the mark sends a batch nobody closes — the first live record draws it,
	// because a held batch that never renders is worse than one drawn early.
	const idle = makeBaseEventConverter();
	assertEquals(
		idle({ v: 1, sim_t_ns: 0, kind: "trace.replay-end" }),
		[],
		"an empty batch draws nothing and does not throw",
	);
	// The endpoint is live afterwards, and behaves.
	const after = idle(
		opened(1, "p0/s1", "rooms-key", "tab1-key", ROOM_WIRE_1, true),
	);
	assertEquals(after.filter((e) => e.kind === "session-opened").length, 1);

	const unclosed = makeBaseEventConverter();
	assertEquals(
		unclosed({
			...opened(0, "p0/s1", "rooms-key", "tab1-key", ROOM_WIRE_1, true),
			replay: true,
		}),
		[],
		"a replayed record waits for the end of its batch",
	);
	const flushed = unclosed(
		opened(1, "p1/s1", "tab1-key", "tab2-key", DM_WIRE, true),
	);
	// Both the held open and the live one are drawn, held one first.
	const opens = flushed.filter((e) => e.kind === "session-opened");
	assertEquals(
		opens.length,
		2,
		"the held batch is drawn before the live record",
	);
});

Deno.test("a producer restarting discards the batch it never finished", () => {
	// A batch describes the topology of ONE producer process. If that process
	// is replaced while its batch is still held, the sessions in it died with
	// it and its wire names may now belong to something else — so drawing it
	// into the new epoch would materialize exactly the ghosts the epoch change
	// exists to clear.
	const convert = makeBaseEventConverter();
	assertEquals(
		convert({
			...opened(0, "p0/s1", "rooms-key", "tab1-key", ROOM_WIRE_1, true),
			epoch: 1,
			replay: true,
		}),
		[],
		"the batch is held",
	);
	// The endpoint restarted. Nothing of the old process survives.
	const afterRestart = convert({
		...opened(1, "p0/s1", "rooms-key", "tab2-key", ROOM_WIRE_2, true),
		epoch: 2,
	});
	const opens = afterRestart.filter((e) => e.kind === "session-opened");
	assertEquals(opens.length, 1, "only the new epoch's session is drawn");
	assertEquals(
		afterRestart.filter((e) => e.kind === "peer-joined" && e.peerId === "tab1-key").length,
		0,
		"a peer from the dead process's batch was drawn into the new epoch",
	);
});

Deno.test("a feed that never ends its batch cannot grow it without limit", () => {
	// Everything on this feed is untrusted until it is read: the
	// viewer dials the endpoint. A feed that marked records `replay` forever
	// would otherwise buffer for the connection's life. Past the bound the held
	// records are DRAWN rather than dropped — losing topology silently would be
	// worse than drawing it early and having to learn an end.
	const convert = makeBaseEventConverter();
	let drawn = 0;
	for (let i = 0; i < 9000; i += 1) {
		drawn += convert({
			...opened(
				i,
				`p0/s${i}`,
				"rooms-key",
				`tab${i}-key`,
				wireName("f"),
				true,
			),
			replay: true,
		}).length;
	}
	assert(drawn > 0, "a batch past the bound was never drawn");
});

Deno.test("a producer's later sessions hang off the node its end attached to", () => {
	// The defect that survived the first fix. A claim is scoped to ONE wire, so
	// nothing else may be filed under it — but a producer that spoke for a
	// wire-scoped row used to leave a pointer at it, and every later session it
	// opened was drawn against that row. When the row eventually merged away,
	// those other sessions were joined to a peer whose row had ended, so they
	// visibly closed the moment the picture improved. That is exactly the
	// falsehood this vocabulary exists to delete, surviving one hop out. Nothing
	// is filed under a claim now, which is what removes the class rather than
	// the instance.
	const convert = makeBaseEventConverter();
	const roomWire = wireName("e");
	const otherWire = wireName("f");
	// The room accepts a dialer it cannot name.
	convert(opened(0, "p0/s1", "rooms-key", "127.0.0.1:0", roomWire, false));
	// The dialer's own producer speaks for that end, and that is the first time
	// anything is drawn for it — under its own designator, never the claim.
	const spoke = convert(
		opened(1, "p1/s1", "tab1-key", "rooms-key", roomWire, true),
	);
	assertEquals(
		spoke.filter((e) => e.kind === "peer-joined").map((e) => expectKind(e, "peer-joined").peerId),
		["tab1-key"],
	);
	const attached = expectKind(
		spoke.find((e) => e.kind === "session-endpoint-attributed"),
		"session-endpoint-attributed",
	);
	assertEquals(attached.peerId, "tab1-key");

	// That same producer now opens a second wire to someone else. Its own end
	// is the node the first wire's end attached to.
	const second = convert(
		opened(2, "p1/s2", "tab1-key", "other-key", otherWire, true),
	);
	assertEquals(
		expectKind(
			second.find((e) => e.kind === "session-opened"),
			"session-opened",
		).a.peer,
		"tab1-key",
	);
	// A third producer reports the FIRST wire. Both its ends are known, so
	// there is nothing here to learn — and crucially nothing that could end the
	// node the second wire is drawn against.
	const third = convert(
		opened(3, "p2/s1", "other-key", "rooms-key", roomWire, true),
	);
	for (
		const invented of [
			"session-endpoint-attributed",
			"session-closed",
			"peer-left",
			"peer-unobserved",
		]
	) {
		assertEquals(
			third.filter((e) => e.kind === invented).length,
			0,
			`a wire whose ends are both known produced a ${invented}`,
		);
	}
	// The second wire still joins the two nodes it was drawn between.
	const picture = pictureOf([...spoke, ...second, ...third]);
	assert(
		picture.edges.includes(["other-key", "tab1-key"].sort().join("–")),
		"the later session lost the node it was drawn against",
	);
});

Deno.test("a producer leaving takes its view, not the conversation", () => {
	// The last leak of the defect this vocabulary exists for. A telemetry
	// socket dropping is a fact about the FEED. The conversation it was
	// reporting may have ended, or may be running happily with nobody
	// watching — from here those are indistinguishable, so saying
	// `session-closed` picks one and states it as protocol fact.
	const convert = makeBaseEventConverter();
	convert(opened(0, "p1/s1", "tab1-key", "rooms-key", wireName("g"), true));
	const gone = convert({
		v: 1,
		sim_t_ns: 1_000_000,
		kind: "trace.producer-left",
		scope: "p1",
	});
	const kinds = gone.map((e) => e.kind);
	assert(
		kinds.includes("session-unobserved"),
		"the session the departing producer was showing went out of view",
	);
	for (const invented of ["session-closed", "peer-left"]) {
		assertEquals(
			kinds.filter((k) => k === invented).length,
			0,
			`losing sight of a conversation is not a ${invented}`,
		);
	}
});

Deno.test("a wire another producer still watches survives one leaving", () => {
	// The refcount that makes the above safe: an end going dark is not the
	// conversation ending, and the peer still reporting it is still reporting
	// it. Only the LAST observer going takes the wire off stage.
	const convert = makeBaseEventConverter();
	const shared = wireName("h");
	convert(opened(0, "p0/s1", "rooms-key", "127.0.0.1:0", shared, false));
	convert(opened(1, "p1/s1", "tab1-key", "rooms-key", shared, true));
	const gone = convert({
		v: 1,
		sim_t_ns: 2_000_000,
		kind: "trace.producer-left",
		scope: "p1",
	});
	assertEquals(
		gone.filter((e) => e.kind === "session-unobserved" || e.kind === "session-closed").length,
		0,
		"a wire the room server still reports stayed on stage",
	);
});

Deno.test("a peer named by a designator records it as its identifier", () => {
	// A peer's public identifier is the durable name it answers to, as
	// against the name it is shown by. The live feed has that fact — it is
	// what `verified` proves, and it is the key the ledger files the row
	// under — and used to spend it on the label alone. A room then renamed
	// the peer to a nickname and the designator was gone from the picture,
	// which is the one fact that made this end attributable at all.
	const convert = makeBaseEventConverter();
	const wire = wireName("g");
	const joins = convert(
		opened(0, "p0/s1", "rooms-key", "tab1-key", wire, true),
	);
	const byId = new Map(
		joins.filter((e) => e.kind === "peer-joined").map((
			e,
		) => [
			expectKind(e, "peer-joined").label,
			expectKind(e, "peer-joined"),
		]),
	);
	for (const name of ["rooms-key", "tab1-key"]) {
		const joined = byId.get(name);
		assert(joined !== undefined, `${name} did not join`);
		assertEquals(
			joined.designator,
			name,
			`${name} joined without recording the designator it was filed under`,
		);
	}

	// A later rename states a NAME. The identifier is not a name, so it does
	// not move — that is the whole point of keeping the two apart.
	const renamed = convert({
		v: 1,
		kind: "rooms.member-named",
		session: "p0/s1",
		nick: "nick1",
		t: 5,
	} as unknown as BaseTimelineEvent);
	for (const ev of renamed) {
		assertEquals(
			(ev as { designator?: string }).designator,
			undefined,
			"a rename restated an identifier",
		);
	}
});

Deno.test("an unproven claim never becomes anyone's identifier", () => {
	// The other half: a name nothing backed is a claim about an end, not a
	// designator anyone answers to. It lives on the endpoint that carries it and
	// reaches no peer — recording it as an identifier would state the very fact
	// the loose end exists to say is missing.
	const convert = makeBaseEventConverter();
	const wire = wireName("h");
	const first = convert(
		opened(0, "p0/s1", "rooms-key", "127.0.0.1:0", wire, false),
	);
	const loose = expectKind(
		first.find((e) => e.kind === "session-opened"),
		"session-opened",
	);
	assertEquals(loose.b, sessionEndpoint({ designator: "127.0.0.1:0" }));
	assertEquals(
		first.filter((e) => e.kind === "peer-joined").map((e) => expectKind(e, "peer-joined").peerId),
		["rooms-key"],
		"the claim drew a peer",
	);

	// Its own producer now speaks for it. The end attaches to that producer's
	// peer, and that peer arrives carrying the designator it answers to —
	// stated once, on the join that draws it, because the ledger only ever
	// draws a peer under a name somebody stated (`ensurePeer`).
	const spoke = convert(
		opened(1, "p1/s1", "tab1-key", "rooms-key", wire, true),
	);
	const named = spoke.filter((e) => (e as { designator?: string }).designator !== undefined);
	assertEquals(
		named.length,
		1,
		"the attached peer never stated its designator, or stated it twice",
	);
	assertEquals(expectKind(named[0], "peer-joined").designator, "tab1-key");

	// And a nickname arriving afterwards is a NAME. It must not carry an
	// identifier, because that is the fact a nickname would otherwise
	// erase — the whole reason the two are kept apart.
	const renamed = convert({
		v: 1,
		kind: "rooms.member-named",
		session: "p1/s1",
		nick: "nick1",
		t: 9,
	} as unknown as BaseTimelineEvent);
	for (const ev of renamed) {
		assertEquals(
			(ev as { designator?: string }).designator,
			undefined,
			"a nickname restated an identifier",
		);
	}

	// Over the whole run: the claim reached no peer at all, by any route. It is
	// neither anyone's identifier nor anyone's stage id nor anyone's name.
	for (const ev of [...first, ...spoke, ...renamed]) {
		const row = ev as {
			designator?: string;
			peerId?: string;
			label?: string;
		};
		for (const field of [row.designator, row.peerId, row.label]) {
			assert(
				field !== "127.0.0.1:0",
				`${ev.kind} carried the unproven claim as a peer fact`,
			);
		}
	}
});

Deno.test("no end the feed draws is attributed to nobody", () => {
	// The endpoint model's one-way invariant, held over a whole feed rather than
	// one record: `attributedBy` present means `peer` present, because nothing
	// can attribute an end to nobody. The converse is what makes it one-way, and
	// it is deliberate — an authored scenario attaches a peer with no
	// measurement to report, and so does a feed whose producer named its partner
	// and stated no verdict about it (the test below holds that end of it). Every
	// producer here states a verdict, so every end this feed draws is either
	// attributed or loose.
	//
	// Its mirror is the fact the whole model exists for: an end with a
	// `designator` and no `attributedBy` carries no peer, so a claim nothing
	// backed can never quietly become an identity.
	const convert = makeBaseEventConverter();
	const roomWire = wireName("i");
	const dmWire = wireName("j");
	const seen: TimelineEvent[] = [];
	const feed = (ev: BaseTimelineEvent) => seen.push(...convert(ev));
	// A room accepts two tabs it cannot name, each tab then speaks for
	// itself, and the two tabs open a direct session to each other.
	feed(opened(0, "p0/s1", "rooms-key", "127.0.0.1:0", roomWire, false));
	feed(opened(1, "p1/s1", "tab1-key", "rooms-key", roomWire, true));
	feed(opened(2, "p2/s1", "tab2-key", "tab1-key", dmWire, true));
	feed(opened(3, "p1/s2", "tab1-key", "tab2-key", dmWire, true));

	let attributed = 0;
	let loose = 0;
	for (const ev of seen) {
		if (ev.kind !== "session-opened") continue;
		for (const [side, end] of [["a", ev.a], ["b", ev.b]] as const) {
			if (end.attributedBy !== undefined) {
				attributed += 1;
				assert(
					end.peer !== undefined,
					`${ev.sessionId} side ${side} was attributed by ` +
						`${end.attributedBy} and named no peer`,
				);
				continue;
			}
			loose += 1;
			assertEquals(
				end.peer,
				undefined,
				`${ev.sessionId} side ${side} drew a peer nothing attributed it to`,
			);
			assert(
				end.designator !== undefined,
				`${ev.sessionId} side ${side} is loose and carries no claim either`,
			);
		}
	}
	// Both arms ran, so neither passed over an empty set.
	assert(attributed > 0, "no end was attributed at all");
	assert(loose > 0, "no end was left loose at all");
});
