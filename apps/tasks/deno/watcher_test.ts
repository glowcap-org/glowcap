// Observe commits a durable context before startup's first poll can fail.
import { type Argument, Ref, RemotePromise, secondaryFailures, Session } from "@glowcap/runtime";
import type { TaskBoard } from "./task_client.ts";

function assert(value: unknown, message: string): asserts value {
	if (!value) throw new Error(message);
}

export async function watcherStartup(board: TaskBoard): Promise<void> {
	for (const refuseCleanup of [false, true]) {
		const primary = new Error("injected first poll failure");
		const cleanup = new Error("injected cancellation failure");
		const original = Session.prototype.send;
		let firstPoll = true;
		let attempts = 0;
		let cancelled: { session: Session; target: Ref } | undefined;
		const serverCancels: RemotePromise[] = [];
		Session.prototype.send = function (target, verb, args: Argument[] = []) {
			if (verb === "poll" && firstPoll) {
				firstPoll = false;
				return RemotePromise.failed(primary);
			}
			if (verb === "cancel") {
				assert(target instanceof Ref, "cleanup did not target the Tasks canceller");
				attempts++;
				cancelled = { session: this, target };
				if (refuseCleanup) return RemotePromise.failed(cleanup);
				const result = original.call(this, target, verb, args);
				serverCancels.push(result);
				return result;
			}
			return original.call(this, target, verb, args);
		};
		let received: unknown;
		try {
			await board.watch();
		} catch (error) {
			received = error;
		} finally {
			Session.prototype.send = original;
		}
		assert(received === primary, "watch startup replaced its primary failure");
		assert(attempts === 1, "watch startup did not attempt exactly one cancellation");
		if (refuseCleanup) {
			assert(secondaryFailures(primary)[0] === cleanup, "cleanup refusal was lost");
			assert(cancelled != null, "missing Tasks registration for fixture cleanup");
			assert(
				await original.call(cancelled.session, cancelled.target, "cancel", []) === true,
				"fixture cleanup failed",
			);
		} else {
			assert(
				serverCancels.length === 1 && await serverCancels[0] === true,
				"the Tasks context was not cancelled",
			);
		}
		const next = await board.watch();
		await next.stop();
	}
	console.log("TypeScript: failed watcher startup cancels once and preserves cleanup failures");
}
