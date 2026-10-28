// Generated calls meet raw behaviors while the factory answer remains pending.
import { type Argument, Host, Ref, Runtime } from "@glowcap/runtime";
import * as tcp from "@glowcap/tcp";
import * as generated from "../generated/callbacks.ts";

function assert(condition: unknown, message: string): asserts condition {
	if (!condition) throw new Error(message);
}

async function scenario(wrong: boolean): Promise<void> {
	await using host = new Host();
	let settle: ((value: Argument) => void) | undefined;
	let sink: Ref | undefined;
	let argument: Ref | undefined;
	let pending = false;

	host.publish("factory", (verb, args) => {
		assert(args.length === 1 && args[0] instanceof Ref, "reference argument");
		if (verb === "open") {
			sink = args[0];
			pending = true;
			return new Promise<Argument>((resolve) => settle = resolve);
		}
		if (verb === "accept") {
			assert(pending, "argument must arrive before fulfillment");
			argument = args[0];
			return undefined;
		}
		throw new Error("unknown factory method");
	});
	const server = await tcp.listen("127.0.0.1", 0, { host });
	await using runtime = await Runtime.open({ providers: [tcp.provider()] });
	const accepting = server[Symbol.asyncIterator]().next();
	const client = await runtime.connect(tcp.locator("127.0.0.1", server.port));
	const incoming = await accepting;
	assert(!incoming.done, "accepted connection");
	const accepted = incoming.value;
	const serving = accepted.serve();
	const reader = accepted.spawn((verb, args) => {
		assert(args.length === 0, "reader arguments");
		if (verb === "read") return "reader value";
		if (verb === "then") return "ordinary then method";
		throw new Error("unknown reader method");
	});
	const failures: unknown[] = [];
	try {
		const root = await client.fetch("factory");
		let received: Ref | undefined;
		let notices = 0;
		const callback = client.spawn((verb, args) => {
			assert(args.length === 1, "sink arity");
			if (verb === "push") {
				assert(args[0] instanceof Ref, "callback reference");
				received = args[0];
			} else if (verb === "changed") {
				assert(args[0] === "notice", "notification value");
				notices++;
			} else throw new Error("unknown sink method");
		});
		const opened = generated.factory_open(client, root, callback);
		assert(!("then" in opened), "pending wrapper must not be assimilated");
		assert(await Promise.resolve(opened) === opened, "Promise.resolve preserves wrapper");
		await generated.factory_accept(client, root, opened.raw).observe();
		assert(pending && argument && sink && settle, "unobserved open sent immediately");
		await generated.sink_changed(accepted, sink, "notice");
		await generated.sink_push(accepted, sink, argument).observe();
		assert(received && notices === 1, "callback and notification delivered");
		const raw = opened.raw.then((value) => value);
		const pipelined = generated.reader_read(client, opened.raw);
		const typed = opened.observe();
		pending = false;
		settle(wrong ? "not a reader" : reader);
		if (wrong) {
			const results = await Promise.allSettled([typed, pipelined.observe()]);
			assert(results[0].status === "rejected" && results[0].reason instanceof TypeError, "typed refusal");
			assert(results[1].status === "rejected", "invalid pipeline refused");
			assert(await raw === "not a reader", "typed refusal preserves raw observation");
		} else {
			const reference = await typed;
			assert(reference instanceof Ref && await raw instanceof Ref, "capability fulfillment");
			assert(await pipelined.observe() === "reader value", "pipeline result");
			assert(await generated.reader_then(client, reference).observe() === "ordinary then method", "wire then");
		}
	} catch (error) {
		failures.push(error);
	}
	for (const cleanup of [() => client.close({ pending: "cancel" }), () => server.close(), () => serving]) {
		try {
			await cleanup();
		} catch (error) {
			failures.push(error);
		}
	}
	if (failures.length) throw new AggregateError(failures, "interface conversation failed");
}

await scenario(false);
await scenario(true);
console.log(
	"interface TypeScript: immediate send, pending argument, callback, pipeline, invalid reply, and then passed",
);
