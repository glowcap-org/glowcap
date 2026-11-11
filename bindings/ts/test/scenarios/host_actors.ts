// Host actors and far-promise breaks. A Host spawns, sends to, and tells
// actors with no session, and a callback's Host sends join its turn. A
// capability in a Host-send answer is released when its wrapper is
// collected. A session breaks the far promises still waiting on its partner
// and stays usable for the next send, and a driver-owned session refuses the
// break. A partner's op:abort stays readable after its session is released.

import * as tcp from "@glowcap/tcp";
import { DESIGNATOR_SCHEME_ADDRESS, INVALID_ARGUMENT } from "@glowcap/abi";
import { connectTcp, listenTcp } from "../../runtime/internal/seam.ts";
import {
	type Argument,
	bareLocator,
	GlowcapError,
	HANDSHAKE_TIMEOUT_MS,
	Host,
	Ref,
	type Runtime,
	Session,
	Sym,
} from "../../runtime/mod.ts";
import { refFromId } from "../../runtime/value.ts";
import { assert, counterBehavior, ok, within } from "./support.ts";

export async function run(managed: Runtime): Promise<void> {
	{
		await using host = new Host();
		const counter = host.spawn(counterBehavior(0n));
		assert(await host.send(counter, "add", [2n]) === 2n, "a Host send reaches a spawned actor");
		host.tell(counter, "add", [3n]);
		assert(await host.send(counter, "get", []) === 5n, "a Host tell runs before the later send");

		// A callback's Host verbs commit with its turn: the tell, the send, and
		// the spawned capability it replies with.
		const turnSends: Promise<Argument>[] = [];
		const factory = host.spawn((verb) => {
			if (verb !== "make") throw new Error(`unexpected verb ${verb}`);
			host.tell(counter, "add", [1n]);
			turnSends.push(host.send(counter, "add", [1n]));
			return [host.spawn(() => new Sym("made"))];
		});
		const made = await host.send(factory, "make", []);
		assert(Array.isArray(made) && made[0] instanceof Ref, "a turn-time Host spawn replies with its capability");
		assert(await host.send(made[0] as Ref, "probe", []) instanceof Sym, "the turn-spawned actor answers");
		assert(turnSends.length === 1, "the factory made one turn-time send");
		const turnAnswer = await within(turnSends[0], 5_000, "the turn-time send's answer");
		assert(turnAnswer === 7n, `the turn-time send answers after its tell, got ${String(turnAnswer)}`);
		assert(await host.send(counter, "get", []) === 7n, "turn-time tell and send both committed");

		// The answer's capability is tracked like any owned reference, so
		// collecting its wrapper gives the C retain back.
		const answered = await (async () => {
			const reply = await host.send(factory, "make", []);
			const child = Array.isArray(reply) ? reply[0] : null;
			assert(child instanceof Ref, "the answer carries a capability");
			return { weak: new WeakRef(child), id: child.id };
		})();
		const collect = (globalThis as unknown as { gc: () => void }).gc;
		assert(typeof collect === "function", "this scenario requires --expose-gc");
		for (let attempt = 0; attempt < 40 && answered.weak.deref() !== undefined; attempt++) {
			await new Promise((resolve) => setTimeout(resolve, 0));
			collect();
			await new Promise((resolve) => setTimeout(resolve, 0));
			host.drainGc();
		}
		assert(answered.weak.deref() === undefined, "the answer's wrapper was not collected");
		let retired = false;
		try {
			host.retain(refFromId(answered.id));
		} catch {
			retired = true;
		}
		assert(retired, "collecting the answer's capability did not release its C retain");
		ok("a Host spawned, sent to, and told actors with no session");
	}

	{
		await using serverHost = new Host();
		serverHost.publish("echo", (_verb, args) => args[0]);
		const server = await tcp.listen("127.0.0.1", 0, { host: serverHost });
		const serving = (async () => {
			for await (const accepted of server) await accepted.serve();
		})();
		try {
			const session = await managed.connect(tcp.locator("127.0.0.1", server.port));
			const echo = await session.fetch("echo");
			let refusal: unknown = null;
			try {
				session.breakFarPromises("not ours to break");
			} catch (error) {
				refusal = error;
			}
			assert(
				refusal instanceof GlowcapError && refusal.code === INVALID_ARGUMENT,
				`a driver-owned session refuses the break, got ${String(refusal)}`,
			);
			assert(await session.send(echo, "echo", [3n]) === 3n, "the refused break left the session usable");
			await session.close();
		} finally {
			await server.close();
			await serving;
		}
		ok("a driver-owned session refused the far-promise break");
	}

	{
		const listener = await listenTcp("127.0.0.1", 0);
		const designator = tcp.addressDesignator("127.0.0.1", listener.port);
		await using serverHost = new Host();
		await using host = new Host();
		const accepting = (async () =>
			Session.establishAccepted(serverHost, {
				transport: "tcp",
				designatorScheme: DESIGNATOR_SCHEME_ADDRESS,
				serverDesignator: designator,
				channel: await listener.accept(),
				verifiedChannelKey: null,
			}, HANDSHAKE_TIMEOUT_MS))();
		const channel = await connectTcp("127.0.0.1", listener.port);
		const dialing = Session.establishDialedLocator(
			host,
			bareLocator("tcp", designator),
			{ read: () => channel.read(), write: (data) => channel.write(data), close: () => channel.close() },
			HANDSHAKE_TIMEOUT_MS,
			null,
		);
		const [serverSession, session] = await Promise.all([accepting, dialing]);
		let markParked!: () => void;
		const parked = new Promise<void>((resolve) => markParked = resolve);
		serverSession.publish("svc", (verb): Argument | Promise<Argument> => {
			if (verb !== "hang") return new Sym("alive");
			markParked();
			return new Promise<Argument>(() => {});
		});
		const servingServer = serverSession.serve();
		const servingClient = session.serve();
		const svc = await session.fetch("svc");
		const pending = Promise.resolve(session.send(svc, "hang", [])).then(
			() => "",
			(error) => error instanceof Error ? error.message : String(error),
		);
		await within(parked, 5_000, "the parked answer");
		session.breakFarPromises("gave up waiting");
		const broke = await within(pending, 5_000, "the broken far promise");
		assert(broke.includes("gave up waiting"), `the break carries its message, got "${broke}"`);
		assert(await session.send(svc, "ping", []) instanceof Sym, "the session still serves later sends");
		assert(serverSession.partnerAbort() === null, "no partner abort before close");
		await session.close();
		await Promise.all([servingServer, servingClient]);
		// The close sent op:abort, and its kind and message outlive the
		// released handle that retained them.
		await serverSession.close();
		assert(serverSession.raw === 0n, "the server session released its handle");
		const partner = serverSession.partnerAbort();
		assert(
			partner?.kind === "NormalShutdown" && partner.message === "session closing",
			`the partner's abort survives release, got ${JSON.stringify(partner)}`,
		);
		assert(session.partnerAbort() === null, "the closing side received no abort");
		listener.close();
		ok("breaking far promises failed the waiting send and kept the session, and a close left its partner abort");
	}
}
