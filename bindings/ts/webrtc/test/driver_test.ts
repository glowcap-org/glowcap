import { GlowcapError } from "@glowcap/runtime";
import { INVALID_ARGUMENT, IO, OK } from "@glowcap/runtime/ffi";
import { Host } from "@glowcap/runtime";
import { ExchangeBook, type ExchangeSink, listen, type SignalingAuthority, type SignalingTarget } from "../driver.ts";

type Recorded = { operation: string; error: unknown };

function harness(overrides: Partial<SignalingAuthority> = {}, sinkOverrides: Partial<ExchangeSink> = {}) {
	const answers: Array<[bigint, string]> = [];
	const candidates: Array<[bigint, string]> = [];
	const failures: Recorded[] = [];
	const failed: bigint[] = [];
	const offers: Array<[string, string]> = [];
	const answered: Array<{ target: SignalingTarget; sdp: string }> = [];
	const sent: Array<[bigint, string]> = [];
	const targets: Array<{ call: string; exchange: bigint; target: SignalingTarget | null }> = [];
	const subscriptions: Array<{ target: SignalingTarget; sink: (ice: string) => void; disposed: number }> = [];
	const signaling: SignalingAuthority = {
		offer: (exchange, target, sdp) => {
			targets.push({ call: "offer", exchange, target });
			return Promise.resolve(`answer:${sdp}`);
		},
		answer: (exchange, target, sdp) => {
			targets.push({ call: "answer", exchange, target });
			answered.push({ target, sdp });
		},
		candidate: (exchange, ice) => {
			targets.push({ call: "candidate", exchange, target: null });
			sent.push([exchange, ice]);
		},
		onCandidate: (exchange, target, sink) => {
			targets.push({ call: "onCandidate", exchange, target });
			const subscription = { target, sink, disposed: 0 };
			subscriptions.push(subscription);
			return () => {
				subscription.disposed += 1;
			};
		},
		...overrides,
	};
	let minted = 100n;
	const sink: ExchangeSink = {
		// Like the library, an accept's answer goes out through `send_answer`
		// before the call returns.
		provideOffer: (designator, sdp) => {
			offers.push([designator, sdp]);
			const exchange = minted++;
			const code = book.sendAnswer(exchange, target(designator), `answer:${sdp}`);
			return { code, exchange };
		},
		provideAnswer: (exchange, sdp) => {
			answers.push([exchange, sdp]);
			return OK;
		},
		provideCandidate: (exchange, ice) => {
			candidates.push([exchange, ice]);
			return OK;
		},
		failExchange: (exchange) => {
			failed.push(exchange);
			return OK;
		},
		lastError: () => null,
		...sinkOverrides,
	};
	const book = new ExchangeBook(signaling, sink, {
		recordCallerlessBindingFailure: (operation, error) => failures.push({ operation, error }),
	});
	return { book, answers, answered, candidates, failures, failed, offers, sent, subscriptions, targets };
}

function target(designator: string, introducer: string | null = null): SignalingTarget {
	return { designator, introducer };
}

const settle = () => new Promise<void>((resolve) => setTimeout(resolve, 0));

Deno.test({
	name: "an offer's answer and a far candidate reach their exchange",
	sanitizeOps: false,
	fn: async () => {
		const h = harness();
		if (h.book.sendOffer(7n, target("aa"), "offer-sdp") !== OK) throw new Error("offer refused");
		h.subscriptions[0].sink('{"candidate":"far"}');
		await settle();
		if (h.answers.length !== 1 || h.answers[0][0] !== 7n || h.answers[0][1] !== "answer:offer-sdp") {
			throw new Error(`unexpected answers ${JSON.stringify(h.answers.map(String))}`);
		}
		if (h.candidates.length !== 1 || h.candidates[0][0] !== 7n) throw new Error("candidate not provided");
		if (h.book.sendCandidate(7n, "local") !== OK || h.sent[0]?.[0] !== 7n) {
			throw new Error("local candidate not sent under the dial's exchange");
		}
	},
});

Deno.test("done ends the subscription and drops late answers and candidates", async () => {
	let release: (sdp: string) => void = () => {};
	const h = harness({
		offer: () => new Promise((resolve) => (release = resolve)),
	});
	h.book.sendOffer(1n, target("bb"), "sdp");
	h.book.done(1n);
	if (h.subscriptions[0].disposed !== 1) throw new Error("subscription not disposed");
	if (h.book.size !== 0) throw new Error("exchange not forgotten");
	release("late");
	h.subscriptions[0].sink("late");
	await settle();
	if (h.answers.length + h.candidates.length !== 0) throw new Error("a finished exchange received data");
	if (h.book.sendCandidate(1n, "x") !== INVALID_ARGUMENT) throw new Error("unknown exchange accepted a candidate");
});

Deno.test("a rejected offer is retained and gives the dial up once", async () => {
	let rejectCandidate: (error: Error) => void = () => {};
	const h = harness({
		offer: () => Promise.reject(new Error("signaling down")),
		candidate: () => new Promise<void>((_resolve, reject) => (rejectCandidate = reject)),
	});
	if (h.book.sendOffer(2n, target("cc"), "sdp") !== OK) throw new Error("offer refused");
	if (h.book.sendCandidate(2n, "local") !== OK) throw new Error("candidate refused");
	await settle();
	if (h.failures.length !== 1 || h.failures[0].operation !== "webrtc.signaling.offer") {
		throw new Error("rejection not retained");
	}
	if (h.failed.length !== 1 || h.failed[0] !== 2n) throw new Error("dial not given up");
	rejectCandidate(new Error("send down"));
	await settle();
	if (h.failures.slice(1).map((f) => f.operation).join() !== "webrtc.signaling.candidate.send") {
		throw new Error(`late rejection not retained: ${h.failures.length}`);
	}
	if (h.failed.length !== 1) throw new Error(`dial given up ${h.failed.length} times`);
	// The driver ends the exchange through `done`, not the book.
	if (h.book.size !== 1) throw new Error("exchange dropped before done");
	h.book.done(2n);
	h.subscriptions[0].sink("late");
	if (h.failed.length !== 1) throw new Error("a finished exchange was failed again");
});

Deno.test("a rejected candidate send records and gives the dial up once", async () => {
	const h = harness({ candidate: () => Promise.reject(new Error("send down")) });
	h.book.sendOffer(5n, target("ff"), "sdp");
	if (h.book.sendCandidate(5n, "local") !== OK) throw new Error("candidate refused");
	await settle();
	const sends = h.failures.filter((f) => f.operation === "webrtc.signaling.candidate.send");
	if (sends.length !== 1 || h.failures.length !== 1) throw new Error(`recorded ${h.failures.length}`);
	if (h.failed.length !== 1 || h.failed[0] !== 5n) throw new Error(`failed ${h.failed.length} times`);
});

Deno.test("a candidate that throws returns IO, records, and keeps the exchange", () => {
	const h = harness({
		candidate: () => {
			throw new GlowcapError(IO, "send broke");
		},
	});
	h.book.sendOffer(6n, target("gg"), "sdp");
	if (h.book.sendCandidate(6n, "local") !== IO) throw new Error("throw not reported as IO");
	if (h.failures.length !== 1 || h.failures[0].operation !== "webrtc.signaling.candidate.send") {
		throw new Error(`recorded ${h.failures.length}`);
	}
	if (h.book.size !== 1 || h.subscriptions[0].disposed !== 0) throw new Error("exchange not live");
	if (h.failed.length !== 0) throw new Error("dial given up by a synchronous throw");
});

Deno.test("an offer that throws returns IO, leaves nothing, and disposes once", () => {
	const h = harness({
		offer: () => {
			throw new GlowcapError(IO, "offer broke");
		},
	});
	if (h.book.sendOffer(8n, target("hh"), "sdp") !== IO) throw new Error("throw not reported as IO");
	if (h.book.size !== 0) throw new Error("refused exchange kept");
	if (h.subscriptions.length !== 1 || h.subscriptions[0].disposed !== 1) {
		throw new Error(`disposed ${h.subscriptions[0]?.disposed} times`);
	}
	if (h.failures.length !== 1 || h.failures[0].operation !== "webrtc.signaling.offer") {
		throw new Error(`recorded ${h.failures.length}`);
	}
	if (h.failed.length !== 0) throw new Error("a refused dial was failed through the library");
});

Deno.test("a second done is a no-op and disposes once", () => {
	const h = harness();
	h.book.sendOffer(9n, target("ii"), "sdp");
	h.book.done(9n);
	h.book.done(9n);
	if (h.subscriptions[0].disposed !== 1) throw new Error(`disposed ${h.subscriptions[0].disposed} times`);
	if (h.book.size !== 0) throw new Error("exchange kept");
	if (h.failures.length !== 0) throw new Error("second done recorded a failure");
});

Deno.test("a throwing signaling authority refuses the dial and leaves nothing behind", () => {
	const h = harness({
		onCandidate: () => {
			throw new GlowcapError(IO, "no signaling");
		},
	});
	if (h.book.sendOffer(3n, target("dd"), "sdp") !== IO) throw new Error("dial not refused");
	if (h.book.size !== 0) throw new Error("refused exchange kept");
	if (h.failures.length !== 1) throw new Error("refusal not retained");
});

Deno.test("a reused exchange id is refused and the original still gets its answer", async () => {
	const h = harness();
	h.book.sendOffer(4n, target("ee"), "first");
	if (h.book.sendOffer(4n, target("other"), "second") !== INVALID_ARGUMENT) throw new Error("duplicate accepted");
	if (h.subscriptions.length !== 1 || h.book.size !== 1) throw new Error("duplicate touched the book");
	await settle();
	if (h.answers.length !== 1 || h.answers[0][1] !== "answer:first") {
		throw new Error(`answers ${JSON.stringify(h.answers.map(String))}`);
	}
	h.book.done(4n);
	if (h.subscriptions[0].disposed !== 1) throw new Error("original not disposed once");
});

Deno.test("a refused answer is recorded and gives the dial up once", async () => {
	const h = harness({}, { provideAnswer: () => IO });
	h.book.sendOffer(10n, target("jj"), "sdp");
	await settle();
	if (h.failures.length !== 1 || h.failures[0].operation !== "webrtc.signaling.answer") {
		throw new Error(`recorded ${h.failures.length}`);
	}
	if (h.failed.length !== 1 || h.failed[0] !== 10n) throw new Error(`failed ${h.failed.length} times`);
	h.book.done(10n);
});

Deno.test("a refused candidate is recorded and does not give the dial up", () => {
	const h = harness({}, { provideCandidate: () => IO });
	h.book.sendOffer(11n, target("kk"), "sdp");
	h.subscriptions[0].sink("far");
	if (h.failures.length !== 1 || h.failures[0].operation !== "webrtc.signaling.candidate") {
		throw new Error(`recorded ${h.failures.length}`);
	}
	if (h.failed.length !== 0) throw new Error("a refused candidate failed the dial");
	h.book.done(11n);
});

Deno.test("an answer or candidate refused as INVALID_ARGUMENT is a finished dial, not a fault", async () => {
	let answers = 0;
	let candidates = 0;
	const h = harness({}, {
		provideAnswer: () => {
			answers++;
			return INVALID_ARGUMENT;
		},
		provideCandidate: () => {
			candidates++;
			return INVALID_ARGUMENT;
		},
	});
	h.book.sendOffer(12n, target("ll"), "sdp");
	h.subscriptions[0].sink("far");
	await settle();
	if (answers !== 1 || candidates !== 1) throw new Error(`sink saw ${answers} answers and ${candidates} candidates`);
	if (h.failures.length !== 0 || h.failed.length !== 0) throw new Error("benign refusal was recorded or failed");
	h.book.done(12n);
});

Deno.test("an introducer reaches offer, subscribe, and candidate on the target", async () => {
	const h = harness();
	if (h.book.sendOffer(9n, target("dd", "intro"), "sdp") !== OK) throw new Error("offer refused");
	if (h.book.sendCandidate(9n, "local") !== OK) throw new Error("candidate refused");
	await settle();
	if (h.targets.map((t) => t.call).join() !== "onCandidate,offer,candidate") {
		throw new Error(`unexpected calls ${h.targets.map((t) => t.call).join()}`);
	}
	for (const { call, exchange, target: seen } of h.targets) {
		if (exchange !== 9n) throw new Error(`${call} named exchange ${exchange}`);
		if (seen == null) continue;
		if (seen.designator !== "dd" || seen.introducer !== "intro") throw new Error(`${call} lost the introducer`);
	}
});

Deno.test("a dial without an introducer carries a null introducer", () => {
	const h = harness();
	h.book.sendOffer(10n, target("ee"), "sdp");
	if (h.targets.some((t) => t.target != null && t.target.introducer !== null)) throw new Error("introducer not null");
});

Deno.test("an accepted offer subscribes, answers, and ends through done", () => {
	const h = harness();
	const exchange = h.book.provideOffer("aa", "offer-sdp");
	if (h.answered.length !== 1 || h.answered[0].sdp !== "answer:offer-sdp") throw new Error("answer not carried");
	if (h.targets.map((t) => t.call).join() !== "onCandidate,answer") {
		throw new Error(`unexpected calls ${h.targets.map((t) => t.call).join()}`);
	}
	if (h.answered[0].target.designator !== "aa" || h.answered[0].target.introducer !== null) {
		throw new Error("answer lost its target");
	}
	h.subscriptions[0].sink("far");
	if (h.candidates.length !== 1 || h.candidates[0][0] !== exchange) throw new Error("candidate not provided");
	if (h.book.sendCandidate(exchange, "local") !== OK || h.sent[0]?.[0] !== exchange) {
		throw new Error("local candidate not sent under the accept's exchange");
	}
	h.book.done(exchange);
	if (h.subscriptions[0].disposed !== 1 || h.book.size !== 0) throw new Error("accept not ended by done");
});

Deno.test("an authority that throws from answer refuses the offer and leaves nothing", () => {
	const h = harness({
		answer: () => {
			throw new GlowcapError(IO, "answer broke");
		},
	});
	try {
		h.book.provideOffer("ee", "sdp");
		throw new Error("offer accepted");
	} catch (error) {
		if (!(error instanceof GlowcapError) || error.code !== IO) throw error;
	}
	if (h.book.size !== 0) throw new Error("refused accept kept");
	if (h.subscriptions[0].disposed !== 1) throw new Error("subscription not disposed once");
	if (h.failures.length !== 1 || h.failures[0].operation !== "webrtc.signaling.answer.send") {
		throw new Error(`recorded ${h.failures.map((f) => f.operation).join()}`);
	}
	if (h.failed.length !== 0) throw new Error("a refused accept was failed through the library");
});

Deno.test("an answer whose send rejects is recorded and gives the accept up once", async () => {
	const h = harness({ answer: () => Promise.reject(new Error("the room is gone")) });
	const exchange = h.book.provideOffer("ee", "sdp");
	if (h.book.size !== 1) throw new Error("the accept did not start");
	await settle();
	if (h.failures.length !== 1 || h.failures[0].operation !== "webrtc.signaling.answer.send") {
		throw new Error(`recorded ${h.failures.map((f) => f.operation).join()}`);
	}
	if (h.failed.length !== 1 || h.failed[0] !== exchange) throw new Error("the accept was not given up once");
});

Deno.test("failExchange on an unknown exchange raises and changes nothing", () => {
	const h = harness({}, { failExchange: () => INVALID_ARGUMENT });
	const live = h.book.provideOffer("ff", "sdp");
	try {
		h.book.failExchange(999n);
		throw new Error("an unknown exchange was accepted");
	} catch (error) {
		if (!(error instanceof GlowcapError) || error.code !== INVALID_ARGUMENT) throw error;
	}
	if (h.book.size !== 1 || h.subscriptions[0].disposed !== 0 || h.failures.length !== 0) {
		throw new Error("a refused give-up changed the book");
	}
	h.book.done(live);
});

Deno.test("failExchange hands the exchange to the library and leaves the end to done", () => {
	const h = harness();
	const exchange = h.book.provideOffer("gg", "sdp");
	h.book.failExchange(exchange);
	if (h.failed.length !== 1 || h.failed[0] !== exchange) throw new Error("exchange not given up");
	if (h.book.size !== 1) throw new Error("exchange dropped before done");
});

Deno.test("an accept's refused library call carries the library's reason", () => {
	const h = harness({}, {
		provideOffer: () => ({ code: IO, exchange: 0n }),
		lastError: () => "the WebRTC library refused the offer",
	});
	try {
		h.book.provideOffer("hh", "sdp");
		throw new Error("refusal swallowed");
	} catch (error) {
		if (
			!(error instanceof GlowcapError) || error.code !== IO ||
			!error.message.includes("the WebRTC library refused")
		) {
			throw error;
		}
	}
});

Deno.test("listen refuses a seed together with a host and a short seed before touching the library", async () => {
	const signaling: SignalingAuthority = {
		offer: () => Promise.reject(new Error("unused")),
		answer: () => {},
		candidate: () => {},
		onCandidate: () => () => {},
	};
	const host = new Host();
	try {
		const both = await listen(signaling, {}, { seed: new Uint8Array(32), host } as never).catch((e) => e);
		if (!(both instanceof GlowcapError) || !both.message.includes("alternative identity sources")) {
			throw new Error(`seed with host: ${both}`);
		}
		const short = await listen(signaling, {}, { seed: new Uint8Array(31) }).catch((e) => e);
		if (!(short instanceof GlowcapError) || !short.message.includes("seed must be 32 bytes")) {
			throw new Error(`short seed: ${short}`);
		}
		if (host.driverLoop != null) throw new Error("a refused listen adopted the host");
	} finally {
		await host.close();
	}
});
