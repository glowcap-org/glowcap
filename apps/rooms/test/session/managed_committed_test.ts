// A second change after a commit ends one of three ways. A lost link throws the
// raw loss for the owner to run the completion again over the next link. Any
// other refusal is a notice, because the first change went through, and runs
// once: no loss is made up for the owner to wait on.
import { assert, assertEquals } from "../assert.ts";
import { closed, fakeHandle } from "../support/managed_link.ts";
import { Committed } from "../../web/ui/session/managed/committed.ts";
import { LocalRefusal } from "../../lib/text/failure.ts";
import { managedSessionText } from "../../lib/text/managed_session.ts";

type Owner = ConstructorParameters<typeof Committed>[0];

function committed() {
	const reported: { source: string; error: unknown }[] = [];
	const after = new Committed(
		fakeHandle<Owner>({}),
		(source, error) => reported.push({ source, error }),
	);
	return { after, reported };
}

async function ended(run: () => Promise<unknown>, after: Committed): Promise<unknown> {
	return await after.change(run).then(() => null, (error: unknown) => error);
}

Deno.test("a receipt the session lost, with no loss behind it, is a notice and the change runs once", async () => {
	const { after, reported } = committed();
	let runs = 0;
	const error = await ended(() => {
		runs++;
		return Promise.reject(new LocalRefusal("receipt-lost"));
	}, after);
	assertEquals(error, null);
	assertEquals(runs, 1);
	assertEquals(reported.length, 1);
	assertEquals(reported[0].source, managedSessionText.followUpFailed);
});

Deno.test("a change that was never sent, with no loss behind it, is a notice too", async () => {
	const { after, reported } = committed();
	assertEquals(await ended(() => Promise.reject(new LocalRefusal("not-sent")), after), null);
	assertEquals(reported.length, 1);
});

Deno.test("a refusal whose cause is the lost connection throws that loss for the owner", async () => {
	const { after, reported } = committed();
	const loss = closed();
	const error = await ended(() => Promise.reject(new LocalRefusal("receipt-lost", { cause: loss })), after);
	assert(error === loss, "the raw loss, not the refusal around it");
	assertEquals(reported.length, 0);
});

Deno.test("a lost connection itself passes as itself", async () => {
	const { after, reported } = committed();
	const loss = closed();
	assert(await ended(() => Promise.reject(loss), after) === loss, "the owner receives the original link loss");
	assertEquals(reported.length, 0);
});

Deno.test("a closed session is not a notice", async () => {
	const { after } = committed();
	const error = await ended(() => Promise.reject(new LocalRefusal("session-closed")), after);
	assert(LocalRefusal.is(error, "session-closed"), String(error));
});
