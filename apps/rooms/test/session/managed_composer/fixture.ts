// One controlled composer viewer: submitted work and editable input have
// separate owners, so tests can settle either side in any order.
import type { ManagedRoomsSession } from "../../../web/ui/session/managed/session.ts";
import type { ManagedOperation } from "../../../web/ui/session/managed/operation.ts";
import type { CommandPowers } from "../../../web/ui/commands.ts";
import { CompletedLine, type LineResult } from "../../../web/ui/session/managed/completed_line.ts";
Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});
export const store = await import("../../../web/ui/store.ts");
const { RoomsPage } = await import("../../../web/ui/page.ts");
const { dirId } = await import("../../../web/ui/types.ts");
const { managedComposer } = await import("../../../web/ui/session/managed/composer.ts");
export const tick = async () => {
	for (let i = 0; i < 12; i++) await Promise.resolve();
};
export function fixture(powers: Partial<CommandPowers> = {}, result?: unknown) {
	const page = new RoomsPage();
	const directory = dirId("directory");
	store.openDir(page.projection, directory, "directory");
	const first = store.ensureRoom(page.projection, directory, "first", { persistId: "first" });
	const second = store.ensureRoom(page.projection, directory, "second", { persistId: "second" });
	store.setRoomMembership(page.projection, first.key, "joined", "");
	store.switchTo(page.projection, first.key);
	const completion = Promise.withResolvers<void>();
	const drafts: [string, string][] = [];
	const commands: [string, string[]][] = [];
	let acquisitions = 0;
	const session = {
		pending: [],
		effects: { reserve() {} },
		drafts: {
			stage: (id: string, text: string) => drafts.push([id, text]),
			flush: () => Promise.resolve(),
			sync() {},
		},
		command: (verb: string, args: string[]) => {
			commands.push([verb, args]);
			return Promise.resolve({
				result: () => result == null ? completion.promise : completion.promise.then(() => result),
			} as unknown as ManagedOperation);
		},
		execute: async (
			_id: string,
			prepare: () => Promise<ManagedOperation>,
			complete: (op: ManagedOperation) => Promise<void>,
		) => complete(await prepare()),
		finish() {},
		actions: {
			acquireLine: async (_id: string, op: ManagedOperation) => {
				const result = await op.result();
				acquisitions++;
				return new CompletedLine(result as LineResult | null);
			},
		},
	} as unknown as ManagedRoomsSession;
	const actions = managedComposer(
		page,
		session,
		{ you: () => "ada", standingHere: () => "", ...powers } as CommandPowers,
	);
	const close = () => {
		for (const row of [...page.projection.get().convs.values()]) store.forgetConv(page.projection, row.key);
	};
	return {
		page,
		directory,
		first,
		second,
		session,
		actions,
		completion,
		drafts,
		commands,
		acquisitions: () => acquisitions,
		close,
	};
}
