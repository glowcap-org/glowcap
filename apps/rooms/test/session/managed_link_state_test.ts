// The link an attached page keeps to its session, alone: when it is lost, when
// it dials again, how long it waits, and what it tells a person meanwhile.
import { assertEquals } from "../assert.ts";
import { settle } from "../support/wait.ts";
import { closed, FakeClock } from "../support/managed_link.ts";
import { browserFailure } from "../support/browser_failure.ts";
import {
	backoff,
	BACKOFF_CEILING_MS,
	BACKOFF_FIRST_MS,
	LINK_WAIT_MS,
	ManagedLink,
	NOTICE_AFTER_MS,
	PROBE_BACKSTOP_MS,
	QUIET_PROBE_MS,
} from "../../web/ui/session/managed/link.ts";
import { ROOMS_ERROR_CODES, ROOMS_FAILURES } from "../../lib/failure_data.ts";
import { CALL_BOUND_MS } from "../../lib/limits.ts";
const { told } = await import("../../web/ui/panes/SessionLinkNotice.tsx");

/** A link whose dials answer from the test. */
function bare() {
	const clock = new FakeClock();
	/** Each dial, which `resolve` answers by putting its link in place. */
	const dials: { resolve: () => void }[] = [];
	const rejections: ((error: unknown) => void)[] = [];
	let probe: () => Promise<void> = () => Promise.resolve();
	const link = new ManagedLink({
		dial: (live) =>
			new Promise<void>((resolve, reject) => {
				dials.push({
					resolve: () => {
						live();
						resolve();
					},
				});
				rejections.push(reject);
			}),
		probe: () => probe(),
		changed: () => {},
	}, clock);
	return {
		clock,
		link,
		dials,
		fail: (index: number, error: unknown) => rejections[index](error),
		probing: (next: () => Promise<void>) => probe = next,
	};
}

Deno.test("the wait before each dial doubles to a ceiling and jitter only shortens it", () => {
	assertEquals(backoff(1, 0), BACKOFF_FIRST_MS);
	assertEquals(backoff(2, 0), 2 * BACKOFF_FIRST_MS);
	assertEquals(backoff(3, 0), 4 * BACKOFF_FIRST_MS);
	assertEquals(backoff(20, 0), BACKOFF_CEILING_MS);
	assertEquals(backoff(3, 1), 3_200);
});

Deno.test("a lost link dials at once, then waits out each failed dial, and a wake dials now", async () => {
	const { link, clock, dials, fail } = bare();
	link.lost(closed(), link);
	assertEquals([link.state.kind, dials.length], ["dialing", 1]);
	fail(0, closed());
	await settle();
	assertEquals([link.state.kind, dials.length, clock.next], ["waiting", 1, 1_000]);
	clock.advance(1_000);
	assertEquals([link.state.kind, dials.length], ["dialing", 2]);
	fail(1, closed());
	await settle();
	clock.advance(1_999);
	assertEquals(dials.length, 2, "the second wait is two seconds");
	link.wake();
	assertEquals([link.state.kind, dials.length], ["dialing", 3]);
	dials[2].resolve();
	await settle();
	assertEquals([link.live, clock.waiting], [true, 0]);
});

Deno.test("a dial the session asks to come back later waits at least that long, and never less than the backoff", async () => {
	const { link, clock, dials, fail } = bare();
	const limited = (retryAfterMs: number) =>
		Object.assign(browserFailure(-12, "rate-limited", "rate-limited", "too many dials"), {
			retryAfterMs,
			scope: "connection",
			owner: null,
		});
	link.lost(closed(), link);
	fail(0, limited(20_000));
	await settle();
	clock.advance(19_999);
	assertEquals([link.state.kind, dials.length], ["waiting", 1], "the session's wait is longer");
	clock.advance(1);
	assertEquals(dials.length, 2);
	fail(1, limited(1));
	await settle();
	clock.advance(1_999);
	assertEquals(dials.length, 2, "the backoff is longer");
	clock.advance(1);
	assertEquals(dials.length, 3);
});

Deno.test("a wake honors the session's word of when to ask again, and only Try now asks sooner", async () => {
	const { link, clock, dials, fail } = bare();
	const limited = Object.assign(browserFailure(-12, "rate-limited", "rate-limited", "too many dials"), {
		retryAfterMs: 20_000,
		scope: "connection",
		owner: null,
	});
	link.lost(closed(), link);
	fail(0, limited);
	await settle();
	clock.advance(5_000);
	link.wake();
	assertEquals([link.state.kind, dials.length], ["waiting", 1], "a wake waits out what the session asked");
	clock.advance(14_999);
	assertEquals(dials.length, 1, "and no longer than that");
	clock.advance(1);
	assertEquals(dials.length, 2);
	fail(1, limited);
	await settle();
	link.tryNow();
	assertEquals(dials.length, 3, "a person's Try now asks at once");
	fail(2, closed());
	await settle();
});

Deno.test("a link lost soon after it came back waits out a backoff, and one that stayed live dials at once", async () => {
	const { link, clock, dials } = bare();
	link.lost(closed(), link);
	dials[0].resolve();
	await settle();
	link.lost(closed(), link);
	assertEquals([link.state.kind, dials.length, clock.next], ["waiting", 1, backoff(1, 0)]);
	clock.advance(backoff(1, 0));
	dials[1].resolve();
	await settle();
	clock.advance(QUIET_PROBE_MS);
	link.lost(closed(), link);
	assertEquals([link.state.kind, dials.length], ["dialing", 3], "a steady link starts its backoff over");
});

Deno.test("a loss ends only the link its handles travel", async () => {
	const { link, dials } = bare();
	const old = { generation: link.generation };
	link.lost(closed(), link);
	link.lost(closed(), old);
	dials[0].resolve();
	await settle();
	assertEquals(
		[link.live, link.generation > old.generation],
		[true, true],
		"a loss over the replaced link while dialing is not held, and the new link is stamped newer",
	);
	link.lost(closed(), old);
	assertEquals([link.live, dials.length], [true, 1], "a loss over the replaced link leaves the new one live");
});

Deno.test("a loss over the new link in the turn it goes live dials again", async () => {
	const { link, dials, clock } = bare();
	link.lost(closed(), link);
	dials[0].resolve();
	link.lost(closed(), link);
	await settle();
	clock.advance(backoff(1, 0));
	assertEquals([link.state.kind, dials.length], ["dialing", 2]);
});

Deno.test("a dial that answers without putting a link in place is a failure inside the page", async () => {
	const clock = new FakeClock();
	const link = new ManagedLink(
		{ dial: () => Promise.resolve(), probe: () => Promise.resolve(), changed: () => {} },
		clock,
	);
	link.lost(closed(), link);
	await settle();
	assertEquals([link.state.kind, link.notice], ["refused", "failed"]);
});

Deno.test("a session that accepts each dial and drops it at once is dialed ever less often, up to the ceiling", async () => {
	const { link, clock, dials } = bare();
	link.lost(closed(), link);
	for (let attempt = 1; attempt <= 7; attempt++) {
		dials[attempt - 1].resolve();
		await settle();
		assertEquals(link.live, true);
		link.lost(closed(), link);
		const wait = backoff(attempt, 0);
		clock.advance(wait - 1);
		assertEquals(dials.length, attempt, `drop ${attempt} waits ${wait} ms`);
		clock.advance(1);
		assertEquals(dials.length, attempt + 1);
	}
	assertEquals(backoff(7, 0), BACKOFF_CEILING_MS, "the last waits were the ceiling");
});

Deno.test("only a lost connection ends a live link", () => {
	const { link, dials } = bare();
	link.lost(browserFailure(-12, "Denied"), link);
	assertEquals([link.live, dials.length], [true, 0]);
});

Deno.test("a dial that ran out of time is retried, and an answered refusal is not", async () => {
	const { link, dials, fail, clock } = bare();
	link.lost(closed(), link);
	fail(0, browserFailure(null, "Saved workspace connection timed out", "session-unreachable"));
	await settle();
	assertEquals(link.state.kind, "waiting");
	link.wake();
	const denied = browserFailure(-12, "The saved access was revoked", "session-restoration-failed");
	fail(1, denied);
	await settle();
	assertEquals([link.state.kind, link.notice, link.cause], ["refused", "refused", denied]);
	assertEquals(clock.waiting, 0, "a refusal runs no timer");
	link.wake();
	assertEquals([link.state.kind, dials.length], ["refused", 2], "a wake leaves a refusal alone");
	link.tryNow();
	assertEquals([link.state.kind, dials.length], ["dialing", 3], "only a person's try now dials again");
});

Deno.test("a dial step the session did not answer in time is dialed again until it is live", async () => {
	const { link, dials, fail, clock } = bare();
	link.lost(closed(), link);
	fail(0, browserFailure(null, "Saved workspace snapshot", "session-request-timed-out"));
	await settle();
	assertEquals([link.state.kind, clock.next], ["waiting", 1_000]);
	clock.advance(1_000);
	dials[1].resolve();
	await settle();
	assertEquals(link.live, true);
});

// What the catalog says of each code decides whether a failed dial waits and
// dials again: a failure to reach, or a failure that clears soon. Every other
// code is the session's answer, and the link stops on it.
Deno.test("the catalog marks exactly the failures to reach a peer, a member, or the session", () => {
	assertEquals(ROOMS_ERROR_CODES.filter((code) => ROOMS_FAILURES[code].reach), [
		"member-unreachable",
		"peer-unreachable",
		"session-unreachable",
	]);
});
/** A code of each kind the catalog gives, and whether a dial it refuses dials again. */
const dialOutcomes: [string, boolean][] = [
	["session-unreachable", true],
	["peer-unreachable", true],
	["member-unreachable", true],
	["session-request-timed-out", true],
	["session-restoration-failed", false],
	["session-capability-gone", false],
	["room-retired", false],
];
for (const [code, again] of dialOutcomes) {
	Deno.test(`a dial refused with ${code} ${again ? "dials again" : "stops"}`, async () => {
		const { link, fail, clock } = bare();
		link.lost(closed(), link);
		fail(0, browserFailure(-12, "the dial's answer", code));
		await settle();
		assertEquals(
			[link.state.kind, clock.waiting > 0],
			again ? ["waiting", true] : ["refused", false],
		);
	});
}

Deno.test("a refused dial offers Try now only where the same dial can meet another answer", () => {
	const offer = (code: string) => told("refused", browserFailure(-12, "the dial's answer", code)).offer;
	assertEquals(offer("session-restoration-failed"), "tryNow", "a session that may come back");
	assertEquals(offer("session-capability-gone"), null, "a link that no longer works names its step instead");
	assertEquals(offer("session-peer-unverified"), null, "a session that is not the one named names its step instead");
});

Deno.test("a failure inside the page is refused without an answer and offers a reload", async () => {
	const { link, fail } = bare();
	link.lost(closed(), link);
	fail(0, new Error("the page broke"));
	await settle();
	assertEquals(link.notice, "failed");
});

Deno.test("a Rust failure that names no code and no status is a failure inside the page", async () => {
	const { link, fail } = bare();
	link.lost(closed(), link);
	fail(0, browserFailure(null, "Workspace connection"));
	await settle();
	assertEquals([link.state.kind, link.notice], ["refused", "failed"]);
});

Deno.test("a hidden page runs no timer and waits to be seen", async () => {
	const { link, clock, dials, fail } = bare();
	link.lost(closed(), link);
	fail(0, closed());
	await settle();
	link.visibility(false);
	assertEquals([link.state.kind, clock.waiting], ["waiting", 0]);
	clock.advance(LINK_WAIT_MS * 2);
	assertEquals(dials.length, 1);
	link.visibility(true);
	assertEquals(dials.length, 2);
	fail(1, closed());
	await settle();
	link.visibility(false);
	assertEquals([link.state.kind, clock.waiting], ["waiting", 0], "a dial that fails while hidden waits to be seen");
});

Deno.test("a hidden page probes nothing until it is seen", () => {
	const { link, clock, probing } = bare();
	let probes = 0;
	probing(() => {
		probes++;
		return new Promise(() => {});
	});
	link.visibility(false);
	link.wake();
	assertEquals([probes, clock.waiting], [0, 0]);
	link.visibility(true);
	assertEquals([probes, clock.waiting], [1, 1]);
});

Deno.test("a device with no network waits for one, and says so", async () => {
	const { link, clock, dials, fail } = bare();
	link.connectivity(false);
	link.lost(closed(), link);
	assertEquals([link.state.kind, dials.length], ["waiting", 0]);
	clock.time += NOTICE_AFTER_MS;
	assertEquals(link.notice, "offline");
	link.connectivity(true);
	assertEquals(dials.length, 1);
	fail(0, closed());
	await settle();
});

Deno.test("the notice names the wait only after it has lasted", async () => {
	const { link, clock, fail } = bare();
	link.lost(closed(), link);
	fail(0, closed());
	await settle();
	assertEquals(link.notice, null);
	clock.time = NOTICE_AFTER_MS;
	assertEquals(link.notice, "reconnecting");
	clock.time = LINK_WAIT_MS;
	assertEquals(link.notice, "stuck");
});

Deno.test("a dial under way says the page is reconnecting and offers nothing, however long the link is gone", async () => {
	const { link, clock, fail } = bare();
	link.lost(closed(), link);
	clock.time = LINK_WAIT_MS;
	assertEquals([link.state.kind, link.notice], ["dialing", "reconnecting"]);
	assertEquals(told("reconnecting", link.cause).offer, null);
	fail(0, closed());
	await settle();
	assertEquals([link.state.kind, link.notice], ["waiting", "stuck"]);
	assertEquals(told("stuck", link.cause).offer, "tryNow", "once no dial is under way, Try now dials");
});

Deno.test("a probe that is never answered counts as a lost link once the call's own bounds have passed", () => {
	const { link, clock, dials, probing } = bare();
	probing(() => new Promise(() => {}));
	link.wake();
	clock.advance(CALL_BOUND_MS);
	assertEquals([link.live, dials.length], [true, 0], "the call answers for itself within its bound");
	clock.advance(PROBE_BACKSTOP_MS - CALL_BOUND_MS);
	assertEquals([link.state.kind, dials.length], ["dialing", 1]);
});

// Only this side's own lost connection, which carries no binding status, ends
// the link. The session's own line with the same code is an answer.
const probeAnswers: [string, number | null, string, boolean][] = [
	["answered with", -12, "session-unreachable", false],
	["that lost its connection with", null, "session-unreachable", true],
];
for (const [said, status, code, lost] of probeAnswers) {
	Deno.test(`a probe ${said} ${code} ${lost ? "ends" : "keeps"} the link`, async () => {
		const { link, dials, probing } = bare();
		probing(() => Promise.reject(browserFailure(status, "the probe's answer", code)));
		link.wake();
		await settle();
		assertEquals([link.live, dials.length], [!lost, lost ? 1 : 0]);
	});
}

Deno.test("a probe that answers keeps the link", async () => {
	const { link, clock, dials } = bare();
	link.wake();
	await settle();
	clock.advance(PROBE_BACKSTOP_MS * 2);
	assertEquals([link.live, dials.length, clock.waiting], [true, 0, 0]);
});

Deno.test("a link lost while its probe waits keeps no timer of that probe", () => {
	const { link, clock, probing } = bare();
	probing(() => new Promise(() => {}));
	link.wake();
	link.lost(closed(), link);
	assertEquals(link.state.kind, "dialing");
	assertEquals(clock.waiting, 2, "only the notice's two thresholds wait");
});

/** A link whose probes the test counts, each answered with `answer`. */
function counted(answer: () => Promise<void> = () => Promise.resolve()) {
	const bound = bare();
	let probes = 0;
	bound.probing(() => {
		probes++;
		return answer();
	});
	return { ...bound, probes: () => probes };
}

Deno.test("a probe the session refuses leaves the link live and the quiet bound running", async () => {
	const { link, clock, probes } = counted(() => Promise.reject(browserFailure(-12, "Denied")));
	link.quiet();
	clock.advance(QUIET_PROBE_MS);
	await settle();
	assertEquals([link.live, probes()], [true, 1]);
	clock.advance(QUIET_PROBE_MS);
	await settle();
	assertEquals(probes(), 2, "the refusal started the bound over");
});

Deno.test("a read parked on a quiet, seen link brings one probe per bound", async () => {
	const { link, clock, probes } = counted();
	link.quiet();
	clock.advance(QUIET_PROBE_MS - 1);
	assertEquals(probes(), 0, "nothing goes out before the bound");
	clock.advance(1);
	await settle();
	assertEquals(probes(), 1, "the bound brings one probe");
	for (let interval = 2; interval <= 4; interval++) {
		clock.advance(QUIET_PROBE_MS);
		await settle();
		assertEquals(probes(), interval, "one probe per bound, each answer starting it over");
	}
	assertEquals(link.live, true);
});

Deno.test("a busy link and a hidden page send no probe", async () => {
	const { link, clock, probes } = counted();
	let release = link.quiet();
	for (let answer = 0; answer < 4; answer++) {
		clock.advance(QUIET_PROBE_MS - 1);
		// Each answer ends the parked read, and the next read holds the bound anew.
		release();
		release = link.quiet();
	}
	assertEquals(probes(), 0, "a link that keeps answering is never probed");
	link.visibility(false);
	assertEquals(clock.waiting, 0, "a hidden page holds no timer");
	clock.advance(QUIET_PROBE_MS * 3);
	assertEquals(probes(), 0);
	link.visibility(true);
	await settle();
	assertEquals(probes(), 1, "being seen again probes once, as any return does");
	clock.advance(QUIET_PROBE_MS);
	await settle();
	assertEquals(probes(), 2, "and the read still parked holds the bound again");
	release();
	clock.advance(QUIET_PROBE_MS * 3);
	assertEquals(probes(), 2, "a released hold leaves nothing armed");
});

Deno.test("waiting for the link ends when it is live, refused, or has stayed down for the bound", async () => {
	const { link, clock, dials, fail } = bare();
	link.lost(closed(), link);
	const live = link.available(null);
	const bounded = link.available(1_000);
	clock.advance(1_000);
	assertEquals(await bounded, false);
	dials[0].resolve();
	assertEquals(await live, true);
	clock.advance(QUIET_PROBE_MS);
	link.lost(closed(), link);
	const refused = link.available(null);
	fail(1, browserFailure(-12, "revoked", "session-restoration-failed"));
	assertEquals(await refused, false);
});

Deno.test("a hidden page spends no time toward a send's bound", async () => {
	const { link, clock, dials } = bare();
	link.connectivity(false);
	link.lost(closed(), link);
	const bounded = link.available(1_000);
	link.visibility(false);
	assertEquals(clock.waiting, 0, "no timer runs while hidden");
	link.visibility(true);
	assertEquals(dials.length, 0, "a page seen again still waits for the network");
	link.connectivity(true);
	assertEquals(dials.length, 1, "the network's return dials");
	dials[0].resolve();
	assertEquals(await bounded, true);
});

Deno.test("a send's bound keeps what the page was seen for, and none of the time it was hidden", async () => {
	const { link, clock } = bare();
	link.connectivity(false);
	link.lost(closed(), link);
	let ended: boolean | null = null;
	const bounded = link.available(1_000).then((answer) => ended = answer);
	clock.advance(400);
	link.visibility(false);
	clock.advance(10_000);
	assertEquals(ended, null, "hidden time is not the bound's");
	link.visibility(true);
	clock.advance(599);
	await settle();
	assertEquals(ended, null, "what was seen is still taken from the bound");
	clock.advance(1);
	await bounded;
	assertEquals(ended, false, "the bound ends once a second of seen time has passed");
});

Deno.test("try now dials even when the device reports no network", async () => {
	const { link, dials } = bare();
	link.connectivity(false);
	link.lost(closed(), link);
	assertEquals([link.state.kind, dials.length], ["waiting", 0], "the offline report holds the dial");
	const live = link.available(null);
	link.tryNow();
	assertEquals(dials.length, 1, "try now dials despite the offline report");
	dials[0].resolve();
	assertEquals(await live, true);
});
