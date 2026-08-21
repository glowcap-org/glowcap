import { Ref, type Session } from "@pancake/runtime";
import type { Directory } from "../lib/directory.ts";
import { DirectMessage } from "../lib/direct_message.ts";

function assert(condition: unknown, message: string): asserts condition {
	if (!condition) throw new Error(message);
}

Deno.test("a direct line construction failure retires its redeemed authority", async () => {
	const dm = {} as Ref;
	const released: Ref[] = [];
	let closed = 0;
	const via = {
		spawn(): Ref {
			throw new Error("reply export refused");
		},
		release(ref: Ref): void {
			released.push(ref);
		},
		close(): Promise<void> {
			closed++;
			return Promise.resolve();
		},
	} as unknown as Session;
	const directory = {
		session: via,
		introduceVia(): Promise<{ dm: Ref; via: Session }> {
			return Promise.resolve({ dm, via });
		},
	} as unknown as Directory;

	let refused = "";
	await DirectMessage.open(directory, "peer", () => null).catch((error) => {
		refused = error instanceof Error ? error.message : String(error);
	});
	assert(refused.includes("reply export refused"), "the construction error was not preserved");
	assert(released.length === 1 && released[0] === dm, "the imported DM occurrence was not released");
	assert(closed === 1, "the otherwise-unowned redeemed session was not closed");
});
