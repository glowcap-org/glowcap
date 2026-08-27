// Kernel-held exclusive custody for one durable peer state directory.

export class DirectoryCustody {
	readonly #file: Deno.FsFile;

	private constructor(file: Deno.FsFile) {
		this.#file = file;
	}

	static async acquire(directory: string, lockName: string, subject: string): Promise<DirectoryCustody> {
		await Deno.mkdir(directory, { recursive: true, mode: 0o700 });
		await Deno.chmod(directory, 0o700);
		const file = await Deno.open(`${directory}/${lockName}`, {
			create: true,
			read: true,
			write: true,
			mode: 0o600,
		});
		try {
			if (!await file.tryLock(true)) {
				throw new Error(`${subject} state directory is already in use by another peer`);
			}
			return new DirectoryCustody(file);
		} catch (error) {
			file.close();
			throw error;
		}
	}

	close(): void {
		try {
			this.#file.unlockSync();
		} finally {
			this.#file.close();
		}
	}
}
