// Retention is an owner-scoped durable effect, observed through its original
// request. An unrelated owner's history and shared IndexedDB account survive.
export async function managedRetention({ workspace, peer, observation, blob, bounded }) {
	const peerHistory = await peer.deviceHistory(false);
	const history = await workspace.deviceHistory(false);
	const filter = JSON.stringify({ source: null, generation: null, kind: null,
		conversationKind: null, directory: null, conversation: null, digest: null });
	const held = [];
	async function change(keep) {
		const request = await workspace.prepareCommand(`history-${crypto.randomUUID()}`,
			(await workspace.snapshot()).revision, "chooseHistoryRetention", [keep ? "true" : "false"]);
		held.push(request);
		let cursor = (await observation.poll()).cursor;
		await request.submit();
		await bounded((async () => {
			for (;;) {
				const status = await request.status();
				if (status === "committed") return;
				if (status !== "pending") throw new Error(`history retention requires recovery: ${status}`);
				cursor = (await observation.receive(cursor)).cursor;
			}
		})(), "committed history erasure");
		const intent = (await workspace.snapshot()).intent;
		if (intent.keepHistory !== keep || intent.historyErasure != null) {
			throw new Error("history retention reported success before durable settlement");
		}
	}
	try {
		const own = await history.read(filter, "0", 100);
		const other = await peerHistory.read(filter, "0", 100);
		if (!own.records.length || !other.records.length) throw new Error("both durable owner histories must be populated");
		await change(false);
		const erased = await history.read(filter, "0", 100);
		if (erased.records.length || erased.next !== own.next) throw new Error("scoped erasure lost its cursor or retained records");
		const preserved = await peerHistory.read(filter, "0", 100);
		if (JSON.stringify(preserved) !== JSON.stringify(other)) throw new Error("one owner's retention erased another owner's history");
		let refused = false;
		try { await blob.read("0", 1); } catch { refused = true; }
		if (!refused) throw new Error("an erased archived blob retained read authority");
		await change(true);
		if ((await history.read(filter, "0", 100)).records.length) throw new Error("enabling retention restored erased records");
	} finally {
		for (const request of held) request.free();
		history.free();
		peerHistory.free();
	}
}
