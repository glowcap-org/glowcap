// Hash staged release bytes without materializing the archive in the JS heap.
// Called only by the host resolver; browser adapters never open archives.
import { closeSync, openSync, readSync } from "node:fs";
import { createHash } from "node:crypto";

/** Synchronous, bounded-memory SHA-256 for one staged archive. */
export function sha256File(path: string): string {
	const hash = createHash("sha256");
	const buffer = new Uint8Array(64 * 1024);
	const fd = openSync(path, "r");
	try {
		while (true) {
			const size = readSync(fd, buffer, 0, buffer.length, null);
			if (size === 0) break;
			hash.update(buffer.subarray(0, size));
		}
	} finally {
		closeSync(fd);
	}
	return hash.digest("hex");
}
