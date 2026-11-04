// Generated views track native reply occurrences without retiring shared aliases.
import { FetchFailed, GlowcapError, type HostProfile, Ref, RemotePromise, Sym, Tagged } from "@glowcap/runtime";
import { CLOSED, INVALID_ARGUMENT, NOT_FOUND } from "../../../bindings/ts/abi/constants.ts";
import { HostGc } from "../../../bindings/ts/runtime/gc.ts";
import { MAX_UNOBSERVED_OUTCOMES } from "../../../bindings/ts/runtime/host/state.ts";
import { refStruct } from "../../../bindings/ts/runtime/abi_value.ts";
import { hostS } from "../../../bindings/ts/runtime/internal/ffi/host.ts";
import { ab } from "../../../bindings/ts/runtime/internal/seam.ts";
import { refFromId } from "../../../bindings/ts/runtime/value.ts";
import { awaitMinted, finishFetch } from "../../../bindings/ts/runtime/promise.ts";
import { introducer_get_greeter, reader_read } from "../generated/callbacks.ts";
import * as compounds from "../generated/compounds.ts";
import { assert, withPair } from "./pair.ts";

type Registration = { target: object; held: unknown; token?: object };

// Invoke the real HostGc finalizer callbacks deterministically. No assertion
// depends on when a JavaScript collector chooses to reclaim a wrapper.
class Collector {
	static readonly instances: Collector[] = [];
	static readonly registered: object[] = [];
	readonly registrations: Registration[] = [];
	constructor(readonly callback: (held: unknown) => void) {
		Collector.instances.push(this);
	}
	register(target: object, held: unknown, token?: object): void {
		Collector.registered.push(target);
		this.registrations.push({ target, held, token });
	}
	unregister(token: object): boolean {
		let removed = false;
		for (let index = this.registrations.length - 1; index >= 0; index--) {
			if (this.registrations[index].token !== token) continue;
			this.registrations.splice(index, 1);
			removed = true;
		}
		return removed;
	}
	static targets(): object[] {
		return this.instances.flatMap((registry) => registry.registrations.map((row) => row.target));
	}
	static collect(select: (target: object) => boolean): void {
		for (const registry of this.instances) {
			for (const row of [...registry.registrations]) {
				if (!select(row.target)) continue;
				registry.registrations.splice(registry.registrations.indexOf(row), 1);
				registry.callback(row.held);
			}
		}
	}
}

async function refused(operation: Promise<unknown>): Promise<void> {
	try {
		await operation;
	} catch (error) {
		assert(error instanceof TypeError, "wrong typed refusal");
		return;
	}
	throw new Error("typed result admitted a capability in the wrong position");
}

export async function outcomeGc(): Promise<void> {
	const original = globalThis.FinalizationRegistry;
	globalThis.FinalizationRegistry = Collector as unknown as typeof FinalizationRegistry;
	try {
		for (const profile of ["interop", "glowcap"] satisfies HostProfile[]) {
			await withPair(profile, async (host, client, accepted) => {
				const child = accepted.spawn(() => "still callable");
				host.publish("outcome", (verb) => {
					if (verb === "barrier") return null;
					if (verb === "tuple") return [new Uint8Array([0, 1]), child, child];
					if (verb === "nested") return [[new Sym("item"), child, new Tagged("opaque", [child])]];
					return child;
				});
				const target = await client.fetch("outcome");
				const anchor = await client.send(target, "anchor");
				assert(anchor instanceof Ref, "anchor must be a capability");
				const refs = () =>
					Collector.targets().filter((value) => value instanceof Ref && value.id === anchor.id);
				assert(refs().length === 0, "raw manual reply acquired automatic tracking");
				assert(finishFetch(anchor, "valid", client.host) === anchor, "valid fetch changed wrapper identity");
				assert(refs().length === 0, "valid manual fetch changed release policy");
				await refused(reader_read(client, target).observe());
				assert(
					refs().length === 1 && refs()[0] !== anchor,
					"discarded generated reply lacks occurrence tracking",
				);
				const shared = reader_read(client, target);
				await refused(shared.observe());
				const raw = await shared.raw;
				assert(raw instanceof Ref && refs().includes(raw), "raw alias lost its tracked wrapper");
				assert(raw === await shared.raw, "raw observers received different wrappers");
				assert(await client.send(raw, "read") === "still callable", "typed refusal poisoned a saved raw alias");
				const selected = client.send(target, "tracked").withGc();
				assert(selected.withGc() === selected, "repeated selection changed the promise");
				assert(await selected instanceof Ref, "tracked reply lost its category");
				let late: unknown = null;
				try {
					selected.withGc();
				} catch (error) {
					late = error;
				}
				assert(
					late instanceof GlowcapError && late.code === INVALID_ARGUMENT,
					"late selection did not refuse explicitly",
				);
				const unobserved = client.send(target, "settled");
				await client.send(target, "barrier");
				const beforeUpgrade = refs().length;
				unobserved.withGc().withGc();
				assert(refs().length === beforeUpgrade + 1, "settled upgrade repeated or skipped tracking");
				await unobserved;
				const valid = await introducer_get_greeter(client, target).observe();
				assert(refs().includes(valid), "valid generated capability lacks tracking");
				assert(
					await client.send(valid, "read") === "still callable",
					"valid tracked capability was retired early",
				);
				const beforeCompound = refs().length;
				await refused(compounds.tuple(client, target).observe());
				assert(refs().length === beforeCompound + 2, "partial decoding lost independent equal occurrences");
				const nested = compounds.nested(client, target);
				const values = await nested.observe();
				assert(values === await nested.raw, "opaque projection copied the native reply");
				assert(refs().length === beforeCompound + 4, "opaque nested occurrence lacks tracking");
				const invalidFetch = await client.send(target, "tuple");
				const beforeFetchDiscard = Collector.registered.length;
				try {
					finishFetch(invalidFetch, "bad fetch", client.host);
					throw new Error("fetch accepted a compound reply");
				} catch (error) {
					assert(error instanceof FetchFailed, "fetch classification changed its failure");
				}
				assert(
					Collector.registered.length === beforeFetchDiscard,
					"rejected native fetch allocated finalizer registrations",
				);
				const borrowed = client.spawn(() => "local root survived");
				const local = client.spawn(() => borrowed);
				await refused(reader_read(client, local).observe());
				assert(!Collector.targets().includes(borrowed), "borrowed local root acquired reply ownership");
				assert(
					await client.send(borrowed, "read") === "local root survived",
					"borrowed local root was retired",
				);
				const forwarded = client.caretaker(target).proxy;
				const beforeForward = refs().length;
				await refused(reader_read(client, forwarded).observe());
				assert(refs().length === beforeForward + 1, "local Forward lost native reply tracking");
				// These outcomes never cross the observation boundary. Their
				// retains retire directly, without a second finalizer registration.
				const beforeDiscard = Collector.registered.length;
				const ignored = client.send(target, "ignored");
				await client.send(target, "barrier");
				Collector.collect((value) => value === ignored);
				client.host.drainGc();
				const lateArrival = client.send(target, "late arrival");
				client.host.abandonVow(lateArrival.vow!);
				await client.send(target, "barrier");
				const evicted = client.send(target, "evicted");
				await client.send(target, "barrier");
				for (let index = 0; index < MAX_UNOBSERVED_OUTCOMES; index++) {
					const vow = 1_000_000n + BigInt(index);
					client.host.vowMinted(vow);
					client.host.settleVow(vow, { ok: null });
				}
				try {
					await evicted;
					throw new Error("evicted outcome remained observable");
				} catch (error) {
					assert(error instanceof GlowcapError && error.code === CLOSED, "eviction changed its refusal");
				}
				assert(
					!Collector.registered.slice(beforeDiscard).some((value) => value instanceof Ref),
					"internal discard allocated finalizer registrations",
				);
				const replaced = client.send(target, "tuple");
				await client.send(target, "barrier");
				client.host.settleVow(replaced.vow!, { ok: null });
				assert(await replaced === null, "replacement changed its outcome");
				const rejectedSchedule = new Error("discard scheduler refused");
				const failures: unknown[] = [];
				const discardGc = new HostGc();
				discardGc.bind({
					released: false,
					hostRaw: client.host.raw,
					kick() {},
					abandonVow() {},
					recordFailure: (failure) => failures.push(failure),
					scheduleDrain() {
						throw rejectedSchedule;
					},
				});
				discardGc.discardArgument(await client.send(target, "tuple"));
				const queuedDiscards = () => discardGc.pending.length;
				assert(queuedDiscards() === 2, "scheduler refusal lost a native occurrence");
				assert(failures.length === 1 && failures[0] === rejectedSchedule, "scheduler failure lost its owner");
				discardGc.drainGc();
				assert(queuedDiscards() === 0, "retry did not commit both native releases");
				for (const deliveredFirst of [true, false]) {
					const hidden = client.send(target, "tuple");
					const failure = new Error("required progress failed");
					let refusedWith: unknown = null;
					try {
						await awaitMinted(
							{
								ptr: 0n,
								hostOwner: client.host,
								vowMinted() {}, // The real send minted and registered it.
								attend() {},
								awaitVow: (vow) => client.host.awaitVow(vow),
								kickActions: async () => {
									if (deliveredFirst) await client.send(target, "barrier");
									throw failure;
								},
								parkVowRelease() {}, // The real wrapper owns vow retirement.
							},
							hidden.vow!,
							false,
						);
					} catch (error) {
						refusedWith = error;
					}
					assert(refusedWith === failure, "unexposed result delayed or replaced progress failure");
					await client.send(target, "barrier");
				}
				client.withGc();
				const automaticIgnored = client.send(target, "automatic ignored");
				await client.send(target, "barrier");
				const beforeTrackedDiscard = refs().length;
				Collector.collect((value) => value === automaticIgnored);
				client.host.drainGc();
				assert(refs().length === beforeTrackedDiscard - 1, "discard retained its finalizer guard");
				const automatic = client.send(target, "automatic");
				await client.send(target, "barrier");
				automatic.withGc().withGc();
				const automaticResult = await automatic;
				assert(
					Collector.registered.filter((value) => value === automaticResult).length === 1,
					"automatic outcome repeated a registration",
				);
				client.send(target, "tuple");
				await client.send(target, "barrier");
				client.host.failPendingVows(new GlowcapError(CLOSED, "test terminal failure"));
				// All saved raw aliases were exercised while live. Now simulate
				// collection of the reply wrappers and their vow handles.
				const retiring = refs();
				Collector.collect((value) => value instanceof RemotePromise || retiring.includes(value));
				client.host.drainGc();
				await client.host.kickActions();
				client.release(anchor);
				const result = hostS.glowcap_host_ref_release(client.host.raw, ab(refStruct(refFromId(anchor.id))), 1n);
				assert(result === NOT_FOUND, "discarded reply retained an extra native occurrence");
				client.release(local);
				client.release(forwarded);
				client.release(borrowed);
				client.release(target);
			});
		}
	} finally {
		globalThis.FinalizationRegistry = original;
		Collector.instances.length = 0;
		Collector.registered.length = 0;
	}
}
