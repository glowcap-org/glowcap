// Independent reference occurrences retain their own lifetime through release and resolution.
import * as tcp from "@glowcap/tcp";
import { Host, Ref, Runtime, type Session } from "../../runtime/mod.ts";
import { refFromId } from "../../runtime/value.ts";
import { assert, ok, within } from "./support.ts";

export async function run(managed: Runtime): Promise<void> {
	await using serverHost = new Host();
	let complete!: () => void;
	serverHost.publish(
		"echo",
		(verb, args) =>
			verb === "pending"
				? new Promise<import("../../runtime/mod.ts").Argument>((resolve) => {
					complete = () => resolve([args[0]]);
				})
				: args[0],
	);
	const server = await tcp.listen("127.0.0.1", 0, { host: serverHost });
	const serving = (async () => {
		for await (const session of server) await session.serve();
	})();
	let current: Session | null = null;
	try {
		for (const gc of [false, true]) {
			const session = current = await managed.connect(tcp.locator("127.0.0.1", server.port));
			if (gc) session.withGc();
			const host = session.host;
			const original = session.spawn(() => "alive");
			const held = host.retain(original);
			assert(held !== original && held.equals(original), "retain did not mint an independent wrapper");
			session.release(original);
			assert(await session.send(held, "ping", []) === "alive", "release spent the retained occurrence");
			const resolved = await session.resolve(held);
			assert(resolved instanceof Ref && resolved !== held, "resolution did not own its reference");
			host.release(held);
			assert(await session.send(resolved as Ref, "ping", []) === "alive", "resolution borrowed its input");
			await using foreign = new Host();
			for (const [owner, ref] of [[host, held], [foreign, resolved]] as const) {
				let refused = false;
				try {
					owner.retain(ref as Ref);
				} catch {
					refused = true;
				}
				assert(refused, "retention accepted a released or foreign reference");
			}
			const remote = await session.fetch("echo");
			const remoteResolved = await session.resolve(remote);
			assert(remoteResolved instanceof Ref, "remote object resolution did not return a reference");
			const pending = session.send(remote, "pending", [remote]);
			const promiseRef = await session.send(remote, "echo", [pending]);
			assert(promiseRef instanceof Ref, "echo did not return a pending capability");
			const resolving = session.resolve(promiseRef as Ref);
			complete();
			const settled = await within(resolving, 2000, "pending capability resolution");
			assert(Array.isArray(settled) && settled[0] instanceof Ref, "resolution lost its capability outcome");
			host.release((settled as Ref[])[0]);
			const originalReply = await pending;
			assert(
				Array.isArray(originalReply) && originalReply[0] instanceof Ref,
				"original promise lost its outcome",
			);
			host.release((originalReply as Ref[])[0]);
			host.release(promiseRef as Ref);

			const dropped = (() => {
				const source = session.spawn(() => "temporary");
				const finalOwner = host.retain(source);
				host.release(source);
				return { weak: new WeakRef(finalOwner), id: finalOwner.id };
			})();
			const collect = (globalThis as unknown as { gc: () => void }).gc;
			assert(typeof collect === "function", "this scenario requires --expose-gc");
			for (let attempt = 0; attempt < 40; attempt++) {
				await new Promise((resolve) => setTimeout(resolve, 0));
				collect();
				await new Promise((resolve) => setTimeout(resolve, 0));
				host.drainGc();
				if (dropped.weak.deref() === undefined) break;
			}
			assert(dropped.weak.deref() === undefined, "retained wrapper was not collected");
			// Reconstruct only the expired id to test native retirement, bypassing
			// the binding's released-wrapper guard. This probe owns no C retain.
			let retired = false;
			try {
				host.retain(refFromId(dropped.id));
			} catch {
				retired = true;
			}
			assert(retired, "collection did not retire the final C retain");
			assert(await session.send(remote, "echo", [19]) === 19, "collection closed the live session");
			session.release(remote);
			assert(
				await session.send(remoteResolved as Ref, "echo", [19]) === 19,
				"resolved remote object is unusable",
			);
			host.release(remoteResolved as Ref);
			host.release(resolved as Ref);
			await foreign.close();
			let refused = false;
			try {
				foreign.retain(resolved as Ref);
			} catch {
				refused = true;
			}
			assert(refused, "closed Host accepted a retain");
			await session.closeTransport();
		}
	} finally {
		await current?.closeTransport();
		await server.close();
		await serving;
	}
	ok("independent retains and object resolution survive releasing their source, with Session GC off and on");
}
