// Complete writes, fsync, and same-directory atomic replacement.

const decoder = new TextDecoder("utf-8", { fatal: true });

/** Read one complete UTF-8 document without allowing the file to choose the
 * process allocation. Startup owns this bounded copy; live protocol paths do
 * not use filesystem documents. */
export async function readBoundedText(path: string, maxBytes: number, what: string): Promise<string> {
	if (!Number.isSafeInteger(maxBytes) || maxBytes < 1) throw new Error("durable file ceiling must be positive");
	const file = await Deno.open(path, { read: true });
	try {
		const stat = await file.stat();
		if (stat.size > maxBytes) throw new Error(`${what} exceeds its ${maxBytes}-byte ceiling`);
		let bytes = new Uint8Array(Math.max(1, Math.min(maxBytes + 1, stat.size + 1)));
		let used = 0;
		let complete = false;
		while (!complete) {
			if (used === bytes.length) {
				if (used > maxBytes) throw new Error(`${what} exceeds its ${maxBytes}-byte ceiling`);
				const grown = new Uint8Array(Math.min(maxBytes + 1, Math.max(bytes.length * 2, used + 1)));
				grown.set(bytes);
				bytes = grown;
			}
			const read = await file.read(bytes.subarray(used));
			if (read == null) {
				complete = true;
				continue;
			}
			used += read;
			if (used > maxBytes) throw new Error(`${what} exceeds its ${maxBytes}-byte ceiling`);
		}
		try {
			return decoder.decode(bytes.subarray(0, used));
		} catch {
			throw new Error(`${what} is not UTF-8 text`);
		}
	} finally {
		file.close();
	}
}

export async function writeAll(file: Deno.FsFile, bytes: Uint8Array): Promise<void> {
	let written = 0;
	while (written < bytes.length) {
		const count = await file.write(bytes.subarray(written));
		if (count === 0) throw new Error("durable file write made no progress");
		written += count;
	}
}

function parentDirectory(path: string): string {
	const slash = path.lastIndexOf("/");
	return slash < 0 ? "." : slash === 0 ? "/" : path.slice(0, slash);
}

async function syncDirectory(path: string): Promise<void> {
	const directory = await Deno.open(parentDirectory(path), { read: true });
	try {
		await directory.sync();
	} finally {
		directory.close();
	}
}

/** Install a same-directory staged file and make the directory entry durable.
 * The staged file must already have had its contents synced. */
export async function renameSynced(staged: string, path: string): Promise<void> {
	await Deno.rename(staged, path);
	await syncDirectory(path);
}

export async function atomicWrite(path: string, bytes: Uint8Array): Promise<void> {
	const temp = `${path}.tmp-${crypto.randomUUID()}`;
	try {
		const file = await Deno.open(temp, { createNew: true, write: true, mode: 0o600 });
		try {
			await writeAll(file, bytes);
			await file.sync();
		} finally {
			file.close();
		}
		await renameSynced(temp, path);
	} catch (error) {
		try {
			await Deno.remove(temp);
		} catch (cleanup) {
			if (!(cleanup instanceof Deno.errors.NotFound)) {
				throw new AggregateError([error, cleanup], "durable file write and temporary cleanup both failed");
			}
		}
		throw error;
	}
}

export async function appendSynced(path: string, bytes: Uint8Array): Promise<void> {
	const file = await Deno.open(path, { append: true, create: true, write: true, mode: 0o600 });
	try {
		await writeAll(file, bytes);
		await file.sync();
	} finally {
		file.close();
	}
}
