// A page attached to a session elsewhere opens even when its link is lost on
// the way. Whichever step of opening meets the loss, the page stays open while
// its link is replaced, the new link observes and reads the workspace and
// adopts what other tabs left, and what opening registered is released once.
import { assertEquals } from "../assert.ts";
import { closed, linkedWorkspace, relinking } from "../support/managed_link.ts";
import { until, within } from "../support/wait.ts";
import { snapshot } from "../support/managed_viewer.ts";

const steps: ("register" | "poll" | "read" | "adopt")[] = ["register", "poll", "read", "adopt"];

for (const step of steps) {
	Deno.test(`a link lost when the page opens, at ${step}, leaves the page open while it is replaced`, async () => {
		// The step breaks the link, so every later call over it fails too.
		const fail = () => {
			first.lose();
			return Promise.reject(closed());
		};
		const extra: Record<string, unknown> = {
			effects: step === "adopt" ? fail : () => first.park(),
		};
		if (step === "register") extra.prepareObservation = () => Promise.resolve({ submit: fail, free() {} });
		if (step === "read") extra.snapshot = fail;
		const first = linkedWorkspace("first", [], extra);
		if (step === "poll") first.polling(fail);
		let adopted = 0;
		const second = linkedWorkspace("second", [], {
			snapshot: () => Promise.resolve({ ...snapshot(), revision: "2" }),
			effects: () => {
				adopted++;
				return Promise.resolve([]);
			},
		});
		const { session } = relinking(first.workspace, second.workspace);
		await within(session.start(), "the page to open");
		await until(() => first.state.freed === 1 && session.link?.live === true, "the new link");
		await until(() => adopted === 1, "the new link to adopt what other tabs left");
		assertEquals(session.current?.revision, "2", "the page reads the workspace over the new link");
		assertEquals(second.state.observations, 1, "the new link observes the workspace");
		first.lose();
		second.lose();
		await session.close();
		const registered = step === "register" ? 0 : 1;
		assertEquals(first.state.observationFreed, registered, "what opening registered is released once");
		assertEquals(second.state.observationFreed, 1);
	});
}
