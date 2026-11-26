// One controlled composer viewer: submitted work and editable input have
// separate owners, so tests can settle either side in any order.
import "../../support/match_media.ts";
import { fakeHandle, ownerEntry, unread } from "../../support/managed_link.ts";
import type { ManagedDrafts } from "../../../web/ui/session/managed/drafts.ts";
import type { ManagedTyping } from "../../../web/ui/session/managed/typing.ts";
import type { ManagedActions } from "../../../web/ui/session/managed/actions.ts";
import type { Committed } from "../../../web/ui/session/managed/committed.ts";
import type { ManagedRoomsSession, Sending } from "../../../web/ui/session/managed/session.ts";
import type { ManagedOperation } from "../../../web/ui/session/managed/operation.ts";
import type { CommandPowers } from "../../../web/ui/commands.ts";
import { CompletedLine, type LineResult } from "../../../web/ui/session/managed/completed_line.ts";
export const store = await import("../../../web/ui/store.ts");
const { RoomsPage } = await import("../../../web/ui/page.ts");
const { dirId } = await import("../../../web/ui/directory.ts");
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
	const linesLeft: string[] = [];
	const linesSettled: [string, boolean | null][] = [];
	const linesLanded: string[] = [];
	let acquisitions = 0;
	// What a press learns once its change is committed, over this fixture.
	const after = ownerEntry({}).committed;
	const session: ManagedRoomsSession = fakeHandle<ManagedRoomsSession>({
		pending: [],
		effects: fakeHandle<ManagedRoomsSession["effects"]>({ reserve() {} }),
		drafts: fakeHandle<ManagedDrafts>({
			failure: () => undefined,
			stage: (id: string, text: string) => drafts.push([id, text]),
			flush: () => Promise.resolve(),
			sync() {},
		}),
		typing: fakeHandle<ManagedTyping>({
			lineLeft: (id: string) => linesLeft.push(id),
			forget: (id: string) => linesSettled.push([id, null]),
			lineLanded: (id: string) => {
				linesLanded.push(id);
				return Promise.resolve();
			},
			lineSettled: (id: string, landed: boolean) => {
				linesSettled.push([id, landed]);
				return Promise.resolve();
			},
		}),
		command: (verb: string, args: string[]) => {
			commands.push([verb, args]);
			return Promise.resolve({
				result: () => result == null ? completion.promise : completion.promise.then(() => result),
			} as unknown as ManagedOperation);
		},
		execute: <T>(
			_id: string,
			prepare: () => Promise<ManagedOperation>,
			complete: (op: ManagedOperation, after: Committed) => Promise<T>,
		) => prepare().then((operation) => complete(operation, after)),
		// As the real session's `press` does, over the `execute` and `command` the
		// test has in place when the press runs.
		press: <T>(
			id: string,
			prepare: (sending: Sending) => Promise<ManagedOperation>,
			then: (command: ManagedOperation, after: Committed) => Promise<T>,
		) => session.execute(
			id,
			() => prepare({ command: (...args) => session.command(...args), perform: unread("perform") }),
			then,
		),
		finish() {},
		actions: fakeHandle<ManagedActions>({
			acquireLine: async (_id: string, op: ManagedOperation) => {
				const result = await op.result();
				acquisitions++;
				return new CompletedLine(result as LineResult | null);
			},
		}),
	});
	const actions = managedComposer(
		page,
		session,
		{ you: () => "ada", standingHere: () => "", ...powers } as CommandPowers,
	);
	/** Replace what runs a press's change and its completion. */
	const executing = (
		run: (
			id: string,
			prepare: () => Promise<ManagedOperation>,
			complete: (op: ManagedOperation, after: Committed) => Promise<unknown>,
		) => Promise<unknown>,
	) => Object.assign(session, { execute: run });
	const close = () => {
		for (const row of [...page.projection.get().convs.values()]) store.forgetConv(page.projection, row.key);
	};
	return {
		page,
		directory,
		first,
		second,
		session,
		executing,
		after,
		actions,
		completion,
		drafts,
		commands,
		linesLeft,
		linesSettled,
		linesLanded,
		acquisitions: () => acquisitions,
		close,
	};
}
