export async function announcedSturdyref(
	process: Deno.ChildProcess,
	token: string,
	label: string,
): Promise<string> {
	const reader = process.stdout.getReader();
	const deadline = Date.now() + 10_000;
	const decoder = new TextDecoder();
	let text = "";
	try {
		while (Date.now() < deadline) {
			const remaining = deadline - Date.now();
			let timeout: ReturnType<typeof setTimeout> | undefined;
			const chunk = await Promise.race([
				reader.read(),
				new Promise<undefined>((resolve) => timeout = setTimeout(() => resolve(undefined), remaining)),
			]);
			clearTimeout(timeout);
			if (chunk == null || chunk.done) break;
			text += decoder.decode(chunk.value, { stream: true });
			const match = text.match(new RegExp(`${token} (\\S+)`));
			if (match != null) return match[1];
		}
	} finally {
		reader.releaseLock();
	}
	throw new Error(`${label} did not announce before its deadline`);
}
