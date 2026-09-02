import * as tcp from "@glowcap/tcp";
import { DESIGNATOR_SCHEME_ADDRESS, TIMEOUT } from "@glowcap/abi";
import { connectTcp, listenTcp } from "../../runtime/internal/seam.ts";
import { bareLocator, GlowcapError, Host, Runtime, Session, Sym } from "../../runtime/mod.ts";
import { assert, ok, within } from "./support.ts";

/** Prove finish-close settlement and finite-grace escalation on both fronts. */
export async function runFinishClosePolicy(): Promise<void> {
	// Work admitted before the close barrier may settle within its grace. Repeated
	// close calls observe the one barrier rather than starting parallel teardown.
	{
		const listener = await listenTcp("127.0.0.1", 0);
		const designator = tcp.addressDesignator("127.0.0.1", listener.port);
		await using serverHost = new Host();
		const host = new Host();
		let enteredCall!: () => void;
		const callEntered = new Promise<void>((resolve) => enteredCall = resolve);
		let releaseAnswer!: () => void;
		const answerGate = new Promise<void>((resolve) => releaseAnswer = resolve);
		serverHost.publishGiftable("svc", () => {
			enteredCall();
			return answerGate.then(() => new Sym("done"));
		});
		const accepting = (async () =>
			Session.establishAccepted(serverHost, {
				transport: "tcp",
				designatorScheme: DESIGNATOR_SCHEME_ADDRESS,
				serverDesignator: designator,
				channel: await listener.accept(),
			}))();
		const dialing = Session.establishDialedLocator(
			host,
			bareLocator("tcp", designator),
			await connectTcp("127.0.0.1", listener.port),
		);
		const [serverSession, session] = await Promise.all([accepting, dialing]);
		const servingServer = serverSession.serve().catch(() => {});
		const servingClient = session.serve().catch(() => {});
		const service = await session.fetch("svc");
		const reply = session.send(service, "work", []);
		await within(callEntered, 2_000, "the admitted call reaching the partner");
		const first = host.close({ pending: "finish", graceMs: 5_000 });
		const second = host.close({ pending: "finish", graceMs: 5_000 });
		assert(first === second, "repeated close returns the one shared close barrier");
		releaseAnswer();
		const settled = await within(reply, 5_000, "the admitted vow settling under finish close");
		assert(settled instanceof Sym && settled.value === "done", "finish close let the admitted vow settle");
		await within(first, 5_000, "finish close settlement");
		listener.close();
		await serverHost.close();
		await Promise.all([servingServer, servingClient]);
		ok("a finish close settles admitted work and repeated close shares its barrier");
	}

	// A negotiating byte-fed session that cannot settle spends its grace,
	// escalates to cancel, reaches release, and records the typed timeout.
	{
		const listener = await listenTcp("127.0.0.1", 0);
		const designator = tcp.addressDesignator("127.0.0.1", listener.port);
		const host = new Host();
		const silent = listener.accept();
		const connection = await connectTcp("127.0.0.1", listener.port);
		const negotiating = Session.establishDialedLocator(
			host,
			bareLocator("tcp", designator),
			connection,
		).catch(() => null);
		let timedOut: GlowcapError | null = null;
		try {
			await within(host.close({ pending: "finish", graceMs: 20 }), 5_000, "finite-grace finish close");
		} catch (error) {
			if (error instanceof GlowcapError) timedOut = error;
		}
		assert(timedOut?.code === TIMEOUT, "a spent finish grace surfaces the typed timeout");
		let repeated: GlowcapError | null = null;
		try {
			await host.close();
		} catch (error) {
			if (error instanceof GlowcapError) repeated = error;
		}
		assert(repeated?.code === TIMEOUT, "close after the barrier observes the recorded timeout");
		connection.close();
		(await silent).close();
		await negotiating;
		listener.close();
		ok("a finish close that outlives its finite grace reports the typed TIMEOUT");
	}

	// The loop-backed twin must wake its parked driver step at the same deadline
	// and report the same typed outcome.
	{
		const listener = await listenTcp("127.0.0.1", 0);
		const runtime = await Runtime.open({ providers: [tcp.provider()] });
		const silent = listener.accept();
		const negotiating = runtime.connect(tcp.locator("127.0.0.1", listener.port)).catch(() => null);
		let timedOut: GlowcapError | null = null;
		try {
			await within(runtime.close({ pending: "finish", graceMs: 20 }), 5_000, "loop finite-grace finish close");
		} catch (error) {
			if (error instanceof GlowcapError) timedOut = error;
		}
		assert(timedOut?.code === TIMEOUT, "a spent loop finish grace surfaces the typed timeout");
		(await silent).close();
		await negotiating;
		listener.close();
		ok("a loop finish close that outlives its finite grace reports the typed TIMEOUT");
	}
}
