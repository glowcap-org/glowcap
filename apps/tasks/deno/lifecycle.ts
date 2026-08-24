export interface Closable {
	close(): Promise<void>;
}

export interface AcceptedSession extends Closable {
	onClose(callback: () => void): void;
	serve(): Promise<void>;
}

/** Install cleanup ownership before fallible accepted-session setup. */
export function serveAcceptedSession(
	session: AcceptedSession,
	setup: () => void,
	cleanup: () => void,
	report: (what: string, error: unknown) => void,
): void {
	let retired = false;
	const retire = () => {
		if (retired) return;
		retired = true;
		try {
			cleanup();
		} catch (error) {
			report("accepted session cleanup", error);
		}
		let closing: Promise<void>;
		try {
			closing = session.close();
		} catch (error) {
			report("accepted session close", error);
			return;
		}
		void closing.catch((error) => report("accepted session close", error));
	};

	try {
		session.onClose(retire);
		if (retired) return;
		setup();
		const serving = session.serve();
		void serving.then(
			retire,
			(error) => {
				report("accepted session serve", error);
				retire();
			},
		).catch((error) => {
			report("accepted session retirement", error);
			retire();
		});
	} catch (error) {
		report("accepted session setup", error);
		retire();
	}
}

/** Retire partially acquired join resources without replacing the join error. */
export async function closeFailedJoin(
	session: Closable | null,
	runtime: Closable,
	primary: unknown,
	report: (what: string, error: unknown) => void,
): Promise<never> {
	if (session !== null) {
		try {
			await session.close();
		} catch (error) {
			report("abandoned join session", error);
		}
	}
	try {
		await runtime.close();
	} catch (error) {
		report("abandoned join runtime", error);
	}
	throw primary;
}
