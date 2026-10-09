// Direct line ownership, edits, files and recording preserve both peers’ exact sources.
export async function managedDirect({ binding, workspace, peerSession, peerObservation, directAccess, held, coordinate, peerCommand, peerNotice, peerMessage, message, notice, settle, bounded, archiveFilter }) {
	const peerDirect = (await peerSession.snapshot()).intent.conversations.find((row) => row.kind === "direct");
	if (!peerDirect) throw new Error("the counterpart did not retain its accepted direct conversation");
	const historyId = peerDirect.introduction == null ? peerDirect.id :
		binding.directHistoryId(peerDirect.directory, peerDirect.introduction.registration);
	const directTyping = await workspace.typingSender("direct", JSON.stringify(coordinate("directAccess", directAccess)));
	held.push(directTyping);
	await directTyping.set(true);
	await peerNotice((event) => event.target.id === peerDirect.id && event.notice.kind === "typing" && event.notice.on === true);
	await directTyping.set(false);
	await peerNotice((event) => event.target.id === peerDirect.id && event.notice.kind === "typing" && event.notice.on === false);
	const peerPost = await peerCommand("direct-post", "say", peerDirect.id, "A direct message through Loam");
	const directLine = await message("A direct message through Loam");
	if (!directLine.notice.marker || !peerPost.result.line || !peerPost.result.id) throw new Error("the direct post did not return its sender identity and real line actor");
	const authoredId = peerPost.result.id;
	const peerAfterPost = await peerSession.snapshot();
	if (!peerAfterPost.intent.conversations.find((row) => row.id === peerDirect.id).lines.some((line) => line.id === authoredId)) {
		throw new Error("the sender did not commit its returned line custody");
	}
	if (!peerPost.result.history || peerPost.result.history.source === directLine.notice.history?.source) {
		throw new Error("the sender did not admit its independent recording coordinates");
	}
	const senderHistory = await peerSession.deviceHistory(true);
	held.push(senderHistory);
	async function senderArchived(text, state, files = 0) {
		return await bounded((async () => {
			for (;;) {
				const page = await senderHistory.read(archiveFilter, "0", 100);
				const row = page.records.find(({record}) => record.source === peerPost.result.history.source
					&& record.generation === peerPost.result.history.generation && record.id === peerPost.result.history.id)?.record;
				if (row?.text === text && row.state === state && row.attachments.length === files
					&& row.attachments.every((file) => file.blob != null)) {
					if (!row.mine || row.conversation !== historyId) throw new Error("outgoing recording lost its admitted sender or conversation");
					return row;
				}
				await new Promise((resolve) => setTimeout(resolve, 10));
			}
		})(), "sender archive commitment");
	}
	await senderArchived("A direct message through Loam", "present");
	await peerCommand("direct-edit", "editLine", peerDirect.id, String(authoredId), "A direct edit through Loam");
	const directEdit = await message("A direct edit through Loam");
	if (directEdit.notice.marker.id !== directLine.notice.marker.id || directEdit.notice.marker.change !== "edited") {
		throw new Error("direct edit lost its line identity");
	}
	if (!directLine.notice.history || JSON.stringify(directEdit.notice.history) !== JSON.stringify(directLine.notice.history)) {
		throw new Error("direct edit lost its original archive coordinates");
	}
	await senderArchived("A direct edit through Loam", "edited");
	const sentBytes = new TextEncoder().encode("Exact outgoing direct bytes");
	const refile = await peerSession.prepareUpload("sender-refile", (await peerSession.snapshot()).revision,
		peerDirect.id, "A direct refile through Loam", "[]", [new binding.RoomsBrowserSource("sender.txt", "text/plain", sentBytes.length, 0, 0,
			(offset, length) => Promise.resolve(sentBytes.slice(offset, offset + length)))], String(authoredId), new Uint32Array());
	held.push(refile);
	let senderCursor = (await peerObservation.poll()).cursor;
	if (await refile.submit() === "conflict") throw new Error("the direct refile conflicted before admission");
	for (;;) {
		const status = await refile.status();
		if (status === "committed") break;
		if (status !== "pending") throw new Error(`direct refile receipt: ${status}`);
		senderCursor = (await peerObservation.receive(senderCursor)).cursor;
	}
	await message("A direct refile through Loam");
	const sentRecord = await senderArchived("A direct refile through Loam", "edited", 1);
	const sentBlob = await senderHistory.attachment(JSON.stringify(sentRecord), 0);
	held.push(sentBlob);
	if (new TextDecoder().decode(await sentBlob.read("0", sentBytes.length)) !== new TextDecoder().decode(sentBytes)) throw new Error("the sender archive did not capture the exact source bytes");
	await peerCommand("direct-withdraw", "withdrawLine", peerDirect.id, String(authoredId));
	const directWithdrawal = await notice((event) => event.target.kind === "direct" && event.notice.marker?.id === directLine.notice.marker.id
		&& event.notice.marker?.change === "withdrawn");
	if (JSON.stringify(directWithdrawal.notice.history) !== JSON.stringify(directLine.notice.history)) {
		throw new Error("direct withdrawal lost its original archive coordinates");
	}
	await senderArchived("", "withdrawn");
	const directReply = await workspace.prepareCommand("direct-reply", (await workspace.snapshot()).revision,
		"say", ["direct", "Reply through the saved direct route"]);
	held.push(directReply);
	await settle(directReply);
	await peerMessage("Reply through the saved direct route");
	return directTyping;
}
