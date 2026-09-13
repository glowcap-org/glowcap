// Current data authored through the browser storage contract. Chromium owns
// structured cloning, transaction scheduling and the Blob implementation.
export async function checkStorage(page) {
	await page.evaluate(async () => {
		const binding = await import("/rooms_contract_proofs.js");
		const open = () =>
			new Promise((resolve, reject) => {
				const request = indexedDB.open("rooms-history", 1);
				request.onsuccess = () => resolve(request.result);
				request.onerror = () => reject(request.error);
			});
		const done = (tx) =>
			new Promise((resolve, reject) => {
				tx.oncomplete = resolve;
				tx.onabort = () => reject(tx.error);
			});
		const bytes = Uint8Array.from({ length: 65539 }, (_, i) => i % 251);
		const digest = Array.from(
			new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)),
			(b) => b.toString(16).padStart(2, "0"),
		).join("");
		let db = await open();
		let tx = db.transaction(["archive-records", "archive-blobs", "archive-meta"], "readwrite");
		const key = JSON.stringify(["browser", "generation", "line", "room", "directory", "garden", "seeded-line"]);
		tx.objectStore("archive-records").put({
			key,
			coordinates: JSON.stringify([
				"browser",
				"generation",
				"seeded-line",
				"line",
				"room",
				"directory",
				"garden",
			]),
			revision: 7,
			digests: [digest],
			row: [
				"line",
				"browser",
				"generation",
				"seeded-line",
				"room",
				"directory",
				"garden",
				"alice",
				"a\ud800b🌱",
				false,
				11n,
				12n,
				"present",
				[["seeded.bin", "application/octet-stream", 65539n, 0n, 0n, digest]],
			],
		});
		tx.objectStore("archive-blobs").put({
			key: JSON.stringify(["browser", "generation", "seeded-line", "room", "directory", "garden", 0]),
			digest,
			size: bytes.length,
			bytes: new Blob([bytes]),
		});
		tx.objectStore("archive-meta").put({ key: "revision", value: 7 });
		tx.objectStore("archive-meta").put({ key: "blob-bytes", value: bytes.length });
		await done(tx);
		db.close();
		await binding.rooms_browser_storage_records();
		db = await open();
		tx = db.transaction(["archive-records", "archive-meta", "archive-blobs"], "readwrite");
		const rows = tx.objectStore("archive-records").getAll();
		const count = tx.objectStore("archive-blobs").count();
		const revision = tx.objectStore("archive-meta").get("revision");
		tx.objectStore("archive-meta").put({ key: "revision", value: Number.MAX_SAFE_INTEGER });
		await done(tx);
		if (count.result !== 0 || rows.result.length !== 2) throw new Error("Rust erasure left old records or blobs");
		const kept = rows.result.find((entry) => entry.row[3] === "kept");
		if (kept.row[8] !== "a\ud800b🌱" || typeof kept.row[10] !== "bigint") {
			throw new Error("Rust changed the version-one row representation");
		}
		db.close();
		await binding.rooms_browser_storage_failed_write();
		db = await open();
		tx = db.transaction(["archive-records", "archive-meta"], "readwrite");
		const after = tx.objectStore("archive-records").getAll();
		tx.objectStore("archive-meta").put({ key: "revision", value: revision.result.value });
		await done(tx);
		if (after.result.length !== 2) throw new Error("failed abandoned transaction committed a row");
		db.close();
		// Exercise the commit-time byte ceiling after the row, revision and Blob
		// requests have already been issued. Abort must roll all three back.
		db = await open();
		tx = db.transaction("archive-meta", "readwrite");
		tx.objectStore("archive-meta").put({ key: "blob-bytes", value: 512 * 1024 * 1024 });
		await done(tx);
		db.close();
		await binding.rooms_browser_storage_failed_write();
		db = await open();
		tx = db.transaction(["archive-records", "archive-meta", "archive-blobs"], "readwrite");
		const rolledBack = tx.objectStore("archive-records").count();
		const rolledBlobs = tx.objectStore("archive-blobs").count();
		const rolledRevision = tx.objectStore("archive-meta").get("revision");
		await done(tx);
		if (
			rolledBack.result !== 2 || rolledBlobs.result !== 0 || rolledRevision.result.value !== revision.result.value
		) throw new Error("byte ceiling did not roll back the complete mutation");

		// Populate the fixed capacity in one transaction, then let Rust retire
		// the oldest record together with its attachment and byte charge.
		tx = db.transaction(["archive-records", "archive-meta", "archive-blobs"], "readwrite");
		tx.objectStore("archive-records").clear();
		for (let i = 0; i < 5000; i++) {
			const id = `e-${i}`;
			tx.objectStore("archive-records").put({
				key: JSON.stringify(["browser", "generation", "line", "room", "directory", "garden", id]),
				coordinates: JSON.stringify(["browser", "generation", id, "line", "room", "directory", "garden"]),
				revision: i + 1,
				digests: i === 0 ? [digest] : [],
				row: [
					"line",
					"browser",
					"generation",
					id,
					"room",
					"directory",
					"garden",
					"alice",
					"held",
					false,
					1n,
					BigInt(i + 1),
					"present",
					i === 0 ? [["old.bin", "application/octet-stream", 65539n, 0n, 0n, digest]] : [],
				],
			});
		}
		tx.objectStore("archive-blobs").put({
			key: JSON.stringify(["browser", "generation", "e-0", "room", "directory", "garden", 0]),
			digest,
			size: bytes.length,
			bytes: new Blob([bytes]),
		});
		tx.objectStore("archive-meta").put({ key: "revision", value: 5000 });
		tx.objectStore("archive-meta").put({ key: "blob-bytes", value: bytes.length });
		await done(tx);
		db.close();
		await binding.rooms_browser_storage_eviction();
		db = await open();
		tx = db.transaction(["archive-records", "archive-meta", "archive-blobs"]);
		const remaining = tx.objectStore("archive-records").count();
		const remainingBlobs = tx.objectStore("archive-blobs").count();
		const remainingBytes = tx.objectStore("archive-meta").get("blob-bytes");
		await done(tx);
		if (remaining.result !== 5000 || remainingBlobs.result !== 0 || remainingBytes.result.value !== 0) {
			throw new Error("eviction left excess records or retired bytes");
		}
		db.close();
	});
}
