// The test front loses one acknowledgment after the real adapter retires I/O.
// Recovery still reads the real database through the unchanged storage module.
export function storageWithLostAcknowledgment(path) {
	const physical = JSON.stringify(`${path}?physical`);
	return `
		export { open, close, quiescent, put } from ${physical};
		import { execute as physicalExecute } from ${physical};
		export async function execute(owner, write, step) {
			const probe = owner.database.name === "rooms-session-graph" ? globalThis.roomsGraphOutcome : null;
			const masked = write && probe?.phase === "armed";
			if (masked) probe.phase = "writing";
			const terminal = await physicalExecute(owner, write, step);
			if (masked) {
				probe.retired(terminal);
				return { ...terminal, outcome: 2 };
			}
			if (!write && probe?.phase === "unknown") {
				probe.phase = "recovering";
				probe.recovering();
				await probe.release;
				probe.phase = "done";
			}
			return terminal;
		}
	`;
}
