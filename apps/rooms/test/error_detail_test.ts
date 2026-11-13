// Whether a refusal is too much to keep next to the control it answers.

import { actionRefusal, errorDetailTitle, needsErrorDetail, sessionCapabilityRefusal } from "../web/ui/error_text.ts";
import { attachedSessionFailureText } from "../web/ui/session/attached_failure.ts";
import { assertEquals } from "./assert.ts";
import { LOCAL_REFUSALS } from "../lib/text/local_refusals.ts";
import { readResult, TerminalObservationError } from "../web/ui/session/managed/operation.ts";
import { admissionRefusal } from "../web/ui/admission_feedback.ts";
import {
	AcquisitionConflict,
	OperationsAcquisitionRefused,
	submissionError,
	type SubmissionFailureContext,
	SubmissionRefused,
} from "../web/ui/session/managed/acquisition.ts";
import { NICK_TAKEN, ROOMS_FAILURES, RoomsError, roomsErrorIn } from "../lib/error_codes.ts";
import { BreakCause, BreakReason, parseLocator, VowBroken } from "@glowcap/runtime";
import { roomsErrorOf } from "../lib/errors.ts";
import { HINT_RENDEZVOUS_RELAY } from "../lib/doors.ts";
import { initializeApplication } from "./support/application.ts";
import { formatRoomsSturdyref } from "./support/sturdyref.ts";
import {
	connectionLost,
	doorBlocked,
	doorUnreachable,
	failureView,
	LocalRefusal,
	refusalText,
	renderFailure,
	transportBreak,
} from "../lib/text/failure.ts";

function browserFailure(status: number, reason: string, code: string | null = null, detail = reason): Error {
	return Object.assign(new Error(`glowcap error ${status}: ${reason}`), { status, reason, code, detail });
}

Deno.test("a broken call names a Rooms code only when an application wrote its reason", () => {
	const reason = "nick-taken: alice";
	for (const cause of [BreakCause.partner(), BreakCause.local(BreakReason.Application)]) {
		assertEquals(roomsErrorOf(new VowBroken(reason, cause))?.code, NICK_TAKEN);
	}
	for (
		const cause of [
			new BreakCause(),
			BreakCause.local(BreakReason.TransportUnavailable),
			new BreakCause(BreakCause.partner().origin, BreakReason.Application, 1),
		]
	) {
		assertEquals(roomsErrorOf(new VowBroken(reason, cause)), null);
	}
});

Deno.test("Rooms errors read fields and canonical partner reasons, never display wrappers", () => {
	assertEquals(roomsErrorIn(new RoomsError(NICK_TAKEN, "alice"))?.code, NICK_TAKEN);
	assertEquals(roomsErrorIn(browserFailure(-12, "nick-taken: alice", NICK_TAKEN, "alice"))?.detail, "alice");
	for (
		const reason of [
			"glowcap error -14: nick-taken: alice",
			"glowcap error -12: glowcap error -8: no-server: none chosen",
			"transport: nick-taken: alice",
			"nick-taken: alice",
			"ExporterUnreachable: peer-offline: none",
		]
	) assertEquals(roomsErrorIn(new Error(reason)), null);
	assertEquals(RoomsError.from("blob-expired: nick-taken: alice")?.detail, "nick-taken: alice");
	assertEquals(RoomsError.from("ExporterUnreachable: peer-offline: none"), null);
});

Deno.test("an unexpected failure keeps its diagnostic without inventing retry authority", () => {
	const view = failureView(new Error("transport retired"));
	assertEquals(
		[view.code, view.subject, view.retry, view.detail],
		["unexpected", "operation", "unknown", "transport retired"],
	);
	assertEquals(
		refusalText(new Error("transport retired")),
		`${view.summary} ${view.action} (transport retired)`,
	);
});

Deno.test("a Loam access denial explains permissions and keeps the exact diagnostic", () => {
	const diagnostic = "glowcap error -12: Denied";
	const view = failureView(browserFailure(-12, "Denied"));
	assertEquals(view.code, "access-denied");
	assertEquals(view.retry, "after-state-change");
	assertEquals(view.detail, diagnostic);
	assertEquals(view.summary, "This access doesn't allow that action.");
	assertEquals(view.action, "Ask whoever shared it to review the permissions.");
	for (
		const message of [
			"transport: Denied",
			"glowcap error -12: upstream: Denied",
			"glowcap error -12: Denied: nick-taken",
		]
	) {
		assertEquals(failureView(new Error(message)).code, "unexpected");
	}
});

Deno.test("a short refusal stays beside the control", () => {
	assertEquals(needsErrorDetail("That name is too long for this room (32 characters)."), false);
	assertEquals(needsErrorDetail("Not sent"), false);
});

Deno.test("a locator, a paragraph, or a stack opens the rest on a card", () => {
	assertEquals(
		needsErrorDetail(
			"Could not reach ocapn://abcdefghijklmnopqrstuvwxyz.onion/s/swiss: the peer closed.",
		),
		true,
	);
	assertEquals(needsErrorDetail("one\ntwo"), true);
	assertEquals(
		needsErrorDetail(
			"the peer closed the session before the handshake finished, and the directory never answered the fetch that would have opened this room",
		),
		true,
	);
});

Deno.test("the card's title follows the kind of notice that opened it", () => {
	assertEquals(errorDetailTitle("failure"), "What went wrong");
	assertEquals(errorDetailTitle("warning"), "The full message");
	assertEquals(errorDetailTitle("success"), "The full message");
});

Deno.test("a session capability is checked for the two mistakes a reader makes", () => {
	// The wording is the catalog's and moves when the voice does; what each
	// refusal has to carry is the detail that tells the reader which of their
	// several ocapn:// strings they should have reached for.
	assertEquals(sessionCapabilityRefusal(""), "");
	assertEquals(sessionCapabilityRefusal("hello").includes("ocapn://"), true);
	// A peer's address rather than something it granted. Both are shown in
	// this app, so reaching for the wrong one is a mistake worth naming.
	assertEquals(sessionCapabilityRefusal("ocapn://127.0.0.1%3A7300.tcp").includes("/s/"), true);
	assertEquals(sessionCapabilityRefusal("ocapn://127.0.0.1%3A7300.tcp/s/swiss"), "");
});

Deno.test("a value glowcap could not read offers the likely mistake rather than diagnosing one", () => {
	const view = failureView(browserFailure(-2, "uri parse: UriParseError"));
	assertEquals(view.code, "unreadable-value");
	assertEquals(view.retry, "after-request-change");
	const said = renderFailure(view);
	// It suggests checking the text is whole; it does not tell the reader their
	// link was truncated, which the code it was handed does not establish.
	assertEquals(said.includes("from ocapn:// to the end"), true);
	assertEquals(said.includes("is not a whole"), false);
	assertEquals(said.includes("truncated"), false);
	// The cause keeps glowcap's own words, with no Rooms code in front.
	assertEquals(said.endsWith("(glowcap error -2: uri parse: UriParseError)"), true);
	// Only the leading position names the code: a -2 inside another cause is
	// that cause's business.
	assertEquals(failureView(new Error("glowcap error -12: glowcap error -2: x")).code, "unexpected");
});

Deno.test("a break on the way is told apart from a value or a denial", () => {
	// A broken call carrying the break's own code is the way, not the link; a
	// denial the peer answered is neither, and so is a value it could not read.
	assertEquals(
		transportBreak(browserFailure(-8, "browser channel error")),
		"browser channel error",
	);
	assertEquals(transportBreak(browserFailure(-12, "Denied")), null);
	assertEquals(transportBreak(browserFailure(-2, "host: MalformedPath")), null);
	assertEquals(transportBreak(new Error("That name is taken.")), null);
	// A closed connection is a lost one. What the other side answered is not.
	assertEquals(
		[
			browserFailure(-7, "session closing"),
			browserFailure(-8, "browser channel error"),
			browserFailure(-12, "ExporterUnreachable", "peer-unreachable"),
			browserFailure(-12, "Denied"),
			browserFailure(-13, "host: UnknownCapability"),
		].map(connectionLost),
		[true, true, true, false, false],
	);
});

Deno.test("a route diagnosis uses its projected code, never diagnostic spelling", () => {
	const detail = "Rooms WebRTC found no route within its connect budget";
	const view = failureView(browserFailure(-12, "ExporterUnreachable", "peer-unreachable", detail));
	assertEquals(view.code, "peer-unreachable");
	assertEquals(view.detail, detail);
	assertEquals(
		renderFailure(view),
		`${view.summary} ${view.action} (peer-unreachable: ${detail})`,
	);
	for (
		const reason of [
			"ExporterUnreachable",
			"PeerIdentityUnverified",
			"unknown swissnum",
			"handoff redeem failed",
			"glowcap error -12: Denied",
		]
	) {
		assertEquals(failureView(new Error(reason)).code, "unexpected");
	}
});

Deno.test("a reach through the browser's own relay door names the relay, and keeps the break when it has one", () => {
	const broke = doorUnreachable(
		"directory",
		"127.0.0.1:8080",
		"glowcap error -12: glowcap error -8: browser channel error",
	);
	assertEquals(broke.startsWith("Rooms couldn't reach that directory through the server at 127.0.0.1:8080."), true);
	assertEquals(broke.endsWith("(glowcap error -12: glowcap error -8: browser channel error)"), true);
	// The dial reported another door's refusal, so there is no break to quote.
	assertEquals(doorUnreachable("directory", "127.0.0.1:8080", "").endsWith("isn't answering."), true);
	assertEquals(doorBlocked("prompt", "x").includes("Allow it when the browser asks, then connect again."), true);
	assertEquals(doorBlocked("denied", "x").includes("site settings, then connect again."), true);
});

Deno.test("a session act that broke on the way names the server this browser goes through", async () => {
	await initializeApplication();
	const server = { base: "https://rooms.example/", chosen: true };
	const broke = browserFailure(-8, "browser channel error");
	const named = attachedSessionFailureText(broke, server);
	assertEquals(named.includes("rooms.example"), true);
	assertEquals(named.includes("browser channel error"), true);
	// With no server to name, the failure stands in its own words.
	const bare = attachedSessionFailureText(broke, null);
	assertEquals(bare.includes("rooms.example"), false);
	assertEquals(bare.includes("browser channel error"), true);
	// Attaching through a relay door with no server names the relay instead.
	const relayLink = formatRoomsSturdyref(
		parseLocator(`ocapn://${"ab".repeat(32)}.noise-relay?${HINT_RENDEZVOUS_RELAY}=ws://relay.example/relay`),
		"workspace",
	);
	assertEquals(
		attachedSessionFailureText(broke, null, relayLink),
		doorUnreachable("session", "relay.example", transportBreak(broke) ?? ""),
	);
	// A link only a server opens has no door of this browser's to name.
	const tcpLink = formatRoomsSturdyref(parseLocator("ocapn://offered.example.tcp"), "workspace");
	assertEquals(attachedSessionFailureText(broke, null, tcpLink).includes("relay.example"), false);
	// A peer the dial could not reach is the session, or the server on the way.
	const gone = browserFailure(-12, "ExporterUnreachable", "peer-unreachable");
	assertEquals(
		attachedSessionFailureText(gone, server),
		doorUnreachable("session", "rooms.example", transportBreak(gone) ?? ""),
	);
	// With no server on the way, the attach names the session it reached for.
	assertEquals(
		attachedSessionFailureText(gone, null).startsWith(ROOMS_FAILURES["session-unreachable"].summary),
		true,
	);
	// A refusal that is about the link never blames the server.
	assertEquals(
		attachedSessionFailureText(browserFailure(-12, "Denied"), server).includes("rooms.example"),
		false,
	);
});

Deno.test("a UI action preserves expected refusals and contains unexpected failures", async () => {
	assertEquals(
		await actionRefusal(() => Promise.resolve("That nickname is already taken.")),
		"That nickname is already taken.",
	);
	const transport = await actionRefusal(() => Promise.reject(new Error("transport retired")));
	assertEquals(transport.includes("Rooms couldn't complete"), true);
	assertEquals(transport.includes("transport retired"), true);
	const wire = await actionRefusal(() => Promise.reject("wire refused"));
	assertEquals(wire.includes("Rooms couldn't complete"), true);
	assertEquals(wire.includes("wire refused"), true);
});

Deno.test("cleanup cannot supply the primary failure's classification or retry advice", () => {
	const cleanup = Object.assign(new Error("admission cleanup"), {
		status: -12,
		reason: "rate-limited: retry-after-ms=100; scope=join",
		code: "rate-limited",
		detail: "retry-after-ms=100; scope=join",
		retryAfterMs: 100,
		scope: "join",
		owner: "session",
	});
	const failure = new Error("original observation was lost", { cause: cleanup });
	assertEquals(failureView(failure).code, "unexpected");
	assertEquals(failureView(failure).retry, "unknown");
});

Deno.test("an absent receipt preserves its own typed refusal without trusting observation text", async () => {
	const reason = "rate-limited: retry-after-ms=1000; scope=message; owner=directory";
	const failure = {
		status: null,
		reason,
		code: "rate-limited",
		detail: "retry-after-ms=1000; scope=message; owner=directory",
		retryAfterMs: 1000,
		scope: "message",
		owner: "directory",
	};
	for (const knownAbsent of [false, true]) {
		const error: unknown = await readResult({
			result: () => Promise.resolve({ observationFailure: reason, knownAbsent, failure: null }),
		}).catch((error: unknown) => error);
		assertEquals(admissionRefusal(error), null);
	}
	const absent: unknown = await readResult({
		result: () => Promise.resolve({ observationFailure: reason, knownAbsent: true, failure }),
	}).catch((error: unknown) => error);
	assertEquals(admissionRefusal(absent)?.code, "rate-limited");
	assertEquals(admissionRefusal(absent)?.retryAfterMs, 1000);
});

Deno.test("an uncertain receipt names the failure it saw and stays uncertain", async () => {
	const reason = "peer-unreachable: no route within the connect budget";
	const error: unknown = await readResult({
		result: () =>
			Promise.resolve({
				observationFailure: reason,
				knownAbsent: false,
				failure: {
					status: null,
					reason,
					code: "peer-unreachable",
					detail: "no route within the connect budget",
					retryAfterMs: null,
					scope: null,
					owner: null,
				},
			}),
	}).catch((error: unknown) => error);
	assertEquals(error instanceof TerminalObservationError, true);
	assertEquals(failureView(error).code, "peer-unreachable");
	assertEquals(admissionRefusal(error), null);
});

Deno.test("a submission refusal retains its own projected admission evidence", () => {
	const failure = new SubmissionRefused("The session refused admission", {
		status: -12,
		reason: "rate-limited: retry-after-ms=100; scope=join; owner=session",
		code: "rate-limited",
		detail: "retry-after-ms=100; scope=join; owner=session",
		retryAfterMs: 100,
		scope: "join",
		owner: "session",
	});
	assertEquals(failureView(failure).code, "rate-limited");
	assertEquals(roomsErrorIn(failure)?.retryAfterMs, 100);
	assertEquals(roomsErrorIn(failure)?.advice?.owner, "session");
	assertEquals(failure.message, "The session refused admission");
});

Deno.test("local refusal keys carry their own retry advice and keep diagnostics separate", () => {
	const refusal = new LocalRefusal("storage-blocked", { cause: new Error("provider refused") });
	const view = failureView(refusal);
	assertEquals(view.code, "local-storage-blocked");
	assertEquals(view.retry, "after-state-change");
	assertEquals(view.detail, "provider refused");
	assertEquals(failureView(new Error(refusal.message)).code, "unexpected");
});

Deno.test("access outcomes keep the recovery instructions of their own dialog", () => {
	const contexts: SubmissionFailureContext[] = [
		{ conflict: "access-issue-conflict", uncertain: "access-issue-unknown" },
		{ conflict: "access-edit-conflict", uncertain: "access-edit-unknown" },
	];
	for (const context of contexts) {
		const uncertain = failureView(submissionError({ status: "uncertain", reason: "reply lost" }, context));
		assertEquals(uncertain.code, `local-${context.uncertain}`);
		assertEquals(uncertain.detail, "reply lost");
		assertEquals(uncertain.summary.includes("Unfinished changes"), false);
		assertEquals(uncertain.summary.includes("check again"), true);
		const conflict = failureView(submissionError({ status: "conflict" }, context));
		assertEquals(conflict.code, `local-${context.conflict}`);
		assertEquals(conflict.summary.includes("selected"), false);
		assertEquals(conflict.summary, LOCAL_REFUSALS[context.conflict].summary);
	}
});

Deno.test("known managed failures retain their recovery type and catalog projection", async () => {
	const { WorkspaceConflict, ResultExpired, ReceiptRetired, ResultAcquisitionError } = await import(
		"../web/ui/session/managed/operation.ts"
	);
	for (
		const [failure, code] of [
			[new WorkspaceConflict(), "local-conflict"],
			[new AcquisitionConflict(), "local-acquisition-conflict"],
			[new ResultExpired(), "local-result-expired"],
			[new ReceiptRetired(), "local-receipt-retired"],
			[new OperationsAcquisitionRefused([]), "local-operations-acquisition-refused"],
			[
				new ResultAcquisitionError(undefined, new Error("publication unavailable")),
				"local-result-needs-recovery",
			],
		] as const
	) {
		assertEquals(failureView(failure).code, code);
		assertEquals(failureView(new Error(failure.message)).code, "unexpected");
	}
});

Deno.test("an aggregate local refusal keeps nested diagnostics without repeating catalog sentences", () => {
	const failure = new LocalRefusal("history-unavailable", {
		cause: [
			new LocalRefusal("history-invalid", { cause: new Error("cursor did not advance") }),
			new Error("peer disconnected"),
		],
	});
	assertEquals(failureView(failure).detail, "cursor did not advance\npeer disconnected");
});
