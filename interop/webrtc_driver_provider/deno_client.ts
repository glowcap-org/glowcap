// The Deno WebRTC proofs through the C provider, in order.
//
// Dial (ADR-0035): the binding installs `provider(signaling)`, then an
// ordinary `Runtime.connect` dials the Zig WebRTC answerer by locator, fetches
// its greeter, and calls it.
//
// Listen (ADR-0035): the binding listens with `listen(signaling)`, the Zig
// WebRTC offerer dials the listener, and the accepted session names the
// offerer's key.
//
// Each Zig peer is a separate process that speaks one JSON object per line on
// stdio. This client's signaling authority writes to its stdin and reads its
// stdout: the offer and each local candidate out, the far peer's offer or
// answer and candidates in.
//
// Needs the WebRTC C library and both peers (`zig build webrtc-abi
// webrtc-answerer webrtc-offerer`); run via `zig build
// deno-webrtc-driver-provider`.

import { durableIdentityAuthenticated, Runtime } from "@glowcap/runtime";
import { locator } from "@glowcap/webrtc";
import { listen, provider, type SignalingAuthority } from "@glowcap/webrtc/driver";
import { fail } from "../_common/deno/helpers.ts";

const GATE = "deno-webrtc-driver-provider";
const DEADLINE_MS = 25_000;
const BIN = new URL("../../zig-out/bin/", import.meta.url).pathname;

type Line = { type: string; designator?: string; sdp?: string; candidate?: unknown };

/** A Zig peer process: the lines it writes, and the lines sent to it. */
class StdioPeer {
	readonly #child: Deno.ChildProcess;
	readonly #writer: WritableStreamDefaultWriter<Uint8Array>;
	readonly #lines: AsyncIterator<string>;
	#writes: Promise<void> = Promise.resolve();
	#writeFailure: unknown = null;

	constructor(path: string, args: string[] = []) {
		this.#child = new Deno.Command(path, {
			args,
			stdin: "piped",
			stdout: "piped",
			stderr: "inherit",
		}).spawn();
		this.#writer = this.#child.stdin.getWriter();
		this.#lines = this.#child.stdout
			.pipeThrough(new TextDecoderStream())
			.pipeThrough(splitLines())[Symbol.asyncIterator]();
	}

	/** The next line, or null once the peer closed its stdout. */
	async next(): Promise<Line | null> {
		for (;;) {
			const { value, done } = await this.#lines.next();
			if (done) return null;
			if (value.trim() !== "") return JSON.parse(value) as Line;
		}
	}

	/** The peer's key designator, which it announces before anything else. */
	async identity(name: string): Promise<string> {
		const line = await this.next();
		if (line?.type !== "identity" || line.designator == null) {
			fail(GATE, `the ${name} did not open with an identity line: ${JSON.stringify(line)}`);
		}
		return line.designator;
	}

	/** Route every line the peer writes until it closes its stdout. A `route`
	 * that throws ends the pump with that error. */
	async pump(route: (line: Line) => void): Promise<void> {
		for (let line = await this.next(); line !== null; line = await this.next()) route(line);
	}

	/** Queue one line for the peer. A failed write is kept and raised by the
	 * next `send` or `check`. */
	send(value: unknown): void {
		this.check();
		const bytes = new TextEncoder().encode(`${JSON.stringify(value)}\n`);
		this.#writes = this.#writes.then(() => this.#writer.write(bytes)).catch((error) => {
			this.#writeFailure ??= error;
		});
	}

	/** Raise the first write that failed. */
	check(): void {
		if (this.#writeFailure != null) throw this.#writeFailure;
	}

	/** Close the peer's stdin once the writes already queued are out. */
	async closeStdin(): Promise<void> {
		await this.#writes;
		this.check();
		await this.#writer.close();
	}

	/** The peer's exit code. */
	async exitCode(): Promise<number> {
		return (await this.#child.status).code;
	}

	async kill(): Promise<void> {
		try {
			this.#child.kill();
		} catch {
			// best-effort: the process already exited
		}
		await this.#child.status;
	}
}

/** The far peer's candidates. Those that arrive before `subscribe` wait for
 * its sink, because the library subscribes only once the exchange begins. */
class Candidates {
	readonly #sinks = new Set<(ice: string) => void>();
	readonly #pending: string[] = [];

	feed(candidate: unknown): void {
		const ice = JSON.stringify(candidate);
		if (this.#sinks.size === 0) this.#pending.push(ice);
		for (const sink of this.#sinks) sink(ice);
	}

	subscribe(sink: (ice: string) => void): () => void {
		this.#sinks.add(sink);
		for (const ice of this.#pending.splice(0)) sink(ice);
		return () => this.#sinks.delete(sink);
	}
}

function splitLines(): TransformStream<string, string> {
	let rest = "";
	return new TransformStream({
		transform(chunk, controller) {
			rest += chunk;
			const parts = rest.split("\n");
			rest = parts.pop()!;
			for (const part of parts) controller.enqueue(part);
		},
		flush(controller) {
			if (rest !== "") controller.enqueue(rest);
		},
	});
}

/** Candidate carriage both proofs share: local candidates go to the peer and
 * the far peer's come from `candidates`. */
function stdioSignaling(
	peer: () => StdioPeer,
	candidates: Candidates,
	roles: Pick<SignalingAuthority, "offer" | "answer">,
): SignalingAuthority {
	return {
		...roles,
		candidate: (_exchange, ice) => peer().send({ type: "candidate", candidate: JSON.parse(ice) }),
		onCandidate: (_exchange, _target, sink) => candidates.subscribe(sink),
	};
}

/** Await `step` unless the pump stops first. A pump that threw names the line
 * that broke the protocol, and a clean end means the peer left early. */
async function unlessPumpStops<T>(step: Promise<T>, pump: Promise<void>): Promise<T> {
	return await Promise.race([
		step,
		pump.then((): never => fail(GATE, "the Zig peer closed its stdout before the step finished")),
	]);
}

/** Run one proof under its own deadline. */
async function bounded(name: string, proof: () => Promise<void>): Promise<void> {
	const timer = setTimeout(() => {
		console.error(`${GATE}: FAILED: ${name} produced no result within ${DEADLINE_MS} ms`);
		Deno.exit(1);
	}, DEADLINE_MS);
	try {
		await proof();
	} finally {
		clearTimeout(timer);
	}
}

async function requirePeer(name: string): Promise<string> {
	const path = `${BIN}glowcap-webrtc-${name}`;
	try {
		await Deno.stat(path);
	} catch {
		fail(GATE, `missing ${path}: run \`zig build webrtc-${name}\``);
	}
	return path;
}

async function dialProof(): Promise<void> {
	const peer = new StdioPeer(await requirePeer("answerer"));
	let pump: Promise<void> | null = null;
	try {
		const designator = await peer.identity("answerer");
		const candidates = new Candidates();
		let answered!: (sdp: string) => void;
		const answer = new Promise<string>((resolve) => (answered = resolve));
		pump = peer.pump((line) => {
			if (line.type === "answer") answered(line.sdp!);
			else if (line.type === "candidate") candidates.feed(line.candidate);
			else throw new Error(`the answerer wrote a line outside the protocol: ${JSON.stringify(line)}`);
		});
		const signaling = stdioSignaling(() => peer, candidates, {
			offer: (_exchange, _target, sdp) => {
				peer.send({ type: "offer", sdp });
				return answer;
			},
			answer: () => {
				throw new Error("this authority only dials");
			},
		});

		const runtime = await Runtime.open({ providers: [provider(signaling)] });
		try {
			const session = await unlessPumpStops(runtime.connect(locator(designator)), pump);
			try {
				const greeter = await session.fetch("greeter");
				const reply = await session.send(greeter, "greet", []);
				if (typeof reply !== "string" || reply === "") {
					fail(GATE, `expected a greeting, got ${JSON.stringify(reply)}`);
				}
				peer.check();
				console.log(
					`${GATE}: OK, dialed the answerer through the C provider and heard ${JSON.stringify(reply)}`,
				);
			} finally {
				await session.close();
			}
		} finally {
			await runtime.close();
		}
	} finally {
		await peer.kill();
		await pump;
	}
}

function greeter(): string {
	return "hello over webrtc";
}

async function listenProof(): Promise<void> {
	const path = await requirePeer("offerer");
	let peer!: StdioPeer;
	const candidates = new Candidates();
	const signaling = stdioSignaling(() => peer, candidates, {
		offer: () => Promise.reject(new Error("this authority only answers")),
		answer: (_exchange, _target, sdp) => peer.send({ type: "answer", sdp }),
	});
	const server = await listen(signaling, { includeLoopbackCandidates: true });
	let started = false;
	let pump: Promise<void> | null = null;
	try {
		server.host.publish("greeter", greeter);
		const advertised = server.locator;
		if (advertised.transport !== "webrtc" || advertised.designator !== server.designator) {
			fail(GATE, `the listener advertised ${JSON.stringify(advertised)}`);
		}

		// The listener's designator is the offerer's argument.
		peer = new StdioPeer(path, [server.designator]);
		started = true;
		const offerer = await peer.identity("offerer");
		pump = peer.pump((line) => {
			if (line.type === "offer") server.provideOffer(offerer, line.sdp!);
			else if (line.type === "candidate") candidates.feed(line.candidate);
			else throw new Error(`the offerer wrote a line outside the protocol: ${JSON.stringify(line)}`);
		});

		const accepted = await unlessPumpStops(server[Symbol.asyncIterator]().next(), pump);
		if (accepted.done) fail(GATE, "the listener stopped before it accepted the offerer");
		await using session = accepted.value;
		// Serve from the start, because the offerer calls the greeter as soon as
		// the channel opens. Its hanging up after the greeting ends the serve
		// loop, and the exit code below is what proves the greeting.
		const served = session.serve().catch(() => {}); // tolerant: the partner hanging up ends the serve loop
		// The channel is open, so signaling is over: close the carrier.
		await peer.closeStdin();
		const partner = session.partnerIdentity();
		if (partner.designator !== offerer || !durableIdentityAuthenticated(partner)) {
			fail(GATE, `the accepted session names ${JSON.stringify(partner.designator)}, not ${offerer}`);
		}
		const [, code] = await Promise.all([served, peer.exitCode()]);
		if (code !== 0) fail(GATE, `the offerer exited with ${code}`);
		console.log(`${GATE}: OK, the Deno binding accepted the offerer and named its key`);
	} finally {
		if (started) await peer.kill();
		await pump;
		await server.close();
		await server.host.close();
	}
}

await bounded("the dial proof", dialProof);
await bounded("the listen proof", listenProof);
Deno.exit(0);
