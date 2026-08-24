/** The task board's resource policy. Every task-side limit lives here. */
export const MAX_TASKS = 1024;
export const MAX_TASK_TEXT_BYTES = 4096;
export const MAX_WATCHERS = 256;
export const MAX_SNAPSHOT_TEXT_BYTES = 512 * 1024;

// Syrup tuple and integer overhead remains well below the Host's 1 MiB frame
// cap when the variable text payload is held to half that budget.

const textEncoder = new TextEncoder();

export function taskTextBytes(text: string): number {
	return textEncoder.encode(text).byteLength;
}

export function validateTaskText(text: string): number {
	if (text.length === 0) throw new Error("task text must be non-empty");
	const bytes = taskTextBytes(text);
	if (bytes > MAX_TASK_TEXT_BYTES) {
		throw new Error(`task text may be at most ${MAX_TASK_TEXT_BYTES} bytes`);
	}
	return bytes;
}
