// Generated callers meet raw behaviors while the factory answer remains pending.
import { type Argument, GlowcapError, type HostProfile, Ref, VowBroken } from "@glowcap/runtime";
import * as generated from "../generated/callbacks.ts";
import { authoring } from "./authoring.ts";
import { invocation } from "./invocation.ts";
import { packed } from "./packed.ts";
import { presence } from "./presence.ts";
import { bounds } from "./bounds.ts";
import { compounds } from "./compounds.ts";
import { scalars } from "./scalars.ts";
import { assert, withPair } from "./pair.ts";

type Outcome = "reader" | "wrong" | "broken" | "cancel";

async function scenario(profile: HostProfile, outcome: Outcome): Promise<void> {
	await withPair(profile, async (host, client, accepted) => {
		let settle: ((value: Argument) => void) | undefined;
		let rejectOpen: ((reason: unknown) => void) | undefined;
		let sink: Ref | undefined;
		let argument: Ref | undefined;
		let pending = false;

		host.publish("factory", (verb, args) => {
			assert(args.length === 1 && args[0] instanceof Ref, "reference argument");
			if (verb === "open") {
				sink = args[0];
				pending = true;
				return new Promise<Argument>((resolve, reject) => {
					settle = resolve;
					rejectOpen = reject;
				});
			}
			if (verb === "accept") {
				assert(pending, "argument must arrive before fulfillment");
				argument = args[0];
				return undefined;
			}
			throw new Error("unknown factory method");
		});
		const reader = accepted.spawn((verb, args) => {
			assert(args.length === 0, "reader arguments");
			if (verb === "read") return "reader value";
			if (verb === "then") return "ordinary then method";
			throw new Error("unknown reader method");
		});
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
		const observed = Promise.allSettled([opened.observe(), raw, pipelined.observe()]);
		pending = false;
		if (outcome === "cancel") {
			await client.close({ pending: "cancel" });
		} else if (outcome === "broken") {
			assert(rejectOpen, "factory rejection authority");
			rejectOpen(new Error("future factory refusal"));
		} else {
			settle(outcome === "wrong" ? "not a reader" : reader);
		}
		const [typed, untyped, pipeline] = await observed;
		if (outcome === "reader") {
			assert(typed.status === "fulfilled" && typed.value instanceof Ref, "typed capability fulfillment");
			assert(untyped.status === "fulfilled" && untyped.value instanceof Ref, "raw capability fulfillment");
			assert(pipeline.status === "fulfilled" && pipeline.value === "reader value", "pipeline result");
			assert(await generated.reader_then(client, typed.value).observe() === "ordinary then method", "wire then");
		} else if (outcome === "wrong") {
			assert(typed.status === "rejected" && typed.reason instanceof TypeError, "typed refusal");
			assert(
				untyped.status === "fulfilled" && untyped.value === "not a reader",
				"raw outcome survives typed refusal",
			);
			assert(pipeline.status === "rejected", "invalid pipeline refused");
		} else {
			assert(
				typed.status === "rejected" && untyped.status === "rejected" && pipeline.status === "rejected",
				"all observations refused",
			);
			assert(typed.reason === untyped.reason, "typed observation replaced runtime failure");
			assert(
				typed.reason instanceof GlowcapError && pipeline.reason instanceof GlowcapError,
				"runtime failure remains typed",
			);
			if (outcome === "broken") {
				assert(
					typed.reason instanceof VowBroken && pipeline.reason instanceof VowBroken,
					"remote break remains typed",
				);
				assert(typed.reason.reason === "future factory refusal", "unknown remote break retained");
				assert(pipeline.reason.reason === "future factory refusal", "pipeline remote break retained");
			} else {
				// The late application result must not revive the closed call.
				settle(reader);
			}
		}
	});
}

await invocation();
await presence();
await scalars();
await compounds();
await bounds();
await packed();
await authoring();
for (const profile of ["interop", "glowcap"] satisfies HostProfile[]) {
	for (const outcome of ["reader", "wrong", "broken", "cancel"] satisfies Outcome[]) {
		await scenario(profile, outcome);
	}
}
console.log(
	"interface TypeScript: both profiles, pending callbacks, pipelines, invalid replies, breaks, and close cancellation passed",
);
