import { createHash } from "node:crypto";
import { sha256File } from "../internal/ffi/release_checksum.ts";
import { assertEquals, rejects } from "../../test/assert.ts";

Deno.test("staged archive checksums cover empty, short, and multiple-buffer files", () => {
	const directory = Deno.makeTempDirSync();
	const path = `${directory}/archive.tar.gz`;
	try {
		for (const size of [0, 7, 64 * 1024 - 1, 64 * 1024, 64 * 1024 + 1, 2 * 1024 * 1024 + 17]) {
			const bytes = Uint8Array.from({ length: size }, (_, index) => index % 251);
			Deno.writeFileSync(path, bytes);
			assertEquals(sha256File(path), createHash("sha256").update(bytes).digest("hex"));
		}
		Deno.removeSync(path);
		rejects(() => sha256File(path), "ENOENT");
	} finally {
		Deno.removeSync(directory, { recursive: true });
	}
});
