// Presentation-resource cleanup. Rust file holders already settle session closure.
export function settleViewCleanup(label: string, cleanup: () => void): void {
	try {
		cleanup();
	} catch (error) {
		console.error(`rooms: ${label}: ${error instanceof Error ? error.message : error}`);
	}
}
