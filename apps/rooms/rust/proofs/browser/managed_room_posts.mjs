// Exact room line edits, source suspension, history and selected previews.
export async function managedRoomPosts({workspace, held, settle, message, notice, lifecycle, control, coordinate, said}) {
	const changeLine = async (operation, verb, ...args) => {
		const command = await workspace.prepareCommand(
			operation,
			(await workspace.snapshot()).revision,
			verb,
			["room", String(said.notice.marker.id), ...args],
		);
		held.push(command);
		await settle(command);
	};
	await changeLine("edit", "editLine", "Edited through Loam");
	const edited = await message("Edited through Loam");
	if (edited.notice.marker?.id !== said.notice.marker.id || edited.notice.marker?.change !== "edited") {
		throw new Error("edit changed a different posted line");
	}
	const seat = (await workspace.snapshot()).intent.conversations.find((row) => row.id === "room").seat;
	const seatCoordinate = JSON.stringify(coordinate("roomSeat", seat));
	if (await workspace.readBridgeForm(seatCoordinate) !== null) {
		throw new Error("a normal room advertised a bridge form");
	}
	const history = await workspace.readHistory(JSON.stringify(coordinate("roomSeat", seat)));
	if (!history.some((line) => line.text === "Edited through Loam")) {
		throw new Error("exact-seat history missed the committed edit");
	}
	await lifecycle(control, "pause", (await control.inspect()).revision);
	let pausedForm = false;
	try { await workspace.readBridgeForm(seatCoordinate); } catch { pausedForm = true; }
	if (!pausedForm) throw new Error("paused source read its retained bridge form");
	let pausedEdit = false;
	try {
		await changeLine("paused-edit", "editLine", "Must not appear");
	} catch {
		pausedEdit = true;
	}
	if (!pausedEdit) throw new Error("paused source edited its retained line");
	await lifecycle(control, "resume", (await control.inspect()).revision);
	await changeLine("withdraw", "withdrawLine");
	await notice((event) =>
		event.notice.marker?.id === said.notice.marker.id && event.notice.marker?.change === "withdrawn"
	);
	const previewText = "See https://example.org/";
	const previewPost = await workspace.prepareCommand(
		"previews", (await workspace.snapshot()).revision, "say",
		["room", previewText, JSON.stringify(["https://example.org/"])],
	);
	held.push(previewPost);
	await settle(previewPost);
	const previewed = await message(previewText);
	if (JSON.stringify(previewed.notice.previewUrls) !== JSON.stringify(["https://example.org/"])) {
		throw new Error("managed text post lost its selected preview");
	}
}
