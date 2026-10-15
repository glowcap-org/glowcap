// The exported browser owner registers and chats through the actual process
// directory. Files remain mediated by the exact acquiring session grant.
export async function managedRooms({ location, moduleUrl = "/rooms_contract_proofs.js" }) {
	const { managedRetention } = await import("/managed_retention.mjs");
	const { managedDirect } = await import("/managed_direct.mjs");
	const { managedRoomPosts } = await import("/managed_room_posts.mjs");
	const binding = await import(moduleUrl);
	await binding.default();
	const app = new binding.RoomsManagedApplication(crypto.randomUUID(), (source, reason) => console.error(source, reason));
	const held = [];
	const files = [];
	const incoming = [];
	let activityReader;
	let activityPump;
	let activityStopped = false;
	let sourcePaused = false;
	let lifecycleChanged = () => {};
	let peerApp;
	let peerSession;
	let peerObservation;
	let peerActivity;
	let peerPump;
	let peerStopped = false;
	const key = () => crypto.randomUUID().replaceAll("-", "");
	const coordinate = (role, key) => ({ role, key });
	const archiveFilter = JSON.stringify({ source: null, generation: null, kind: null,
		conversationKind: null, directory: null, conversation: null, digest: null });
	let report = { ready: 0, failures: [] };
	let reported = () => {};
	const messages = [];
	let received = () => {};
	let observation;
	let settling = 0;
	async function bounded(work, description) {
		let timer;
		try {
			return await Promise.race([work, new Promise((_, reject) => timer = setTimeout(() =>
				reject(new Error(`${description}; report ${JSON.stringify(report)}; messages ${JSON.stringify(messages.map(event => event.notice))}`)), 5000))]);
		} finally { clearTimeout(timer); }
	}
	async function ready(count) {
		await bounded((async () => { while (report.ready < count) {
			if (report.sourceFailure) throw new Error(report.sourceFailure);
			if (report.failures.length) throw new Error(JSON.stringify(report.failures));
			await new Promise((resolve) => reported = resolve);
		} })(), `waiting for ${count} supervised owners`);
	}
	async function message(text) {
		return await notice((event) => event.notice.kind === "line" && event.notice.text === text);
	}
	async function notice(matches) {
		await bounded((async () => { while (!messages.some(matches)) {
			await new Promise((resolve) => received = resolve);
		} })(), `waiting for managed notice after command ${settling}`);
		return messages.findLast(matches);
	}
	async function settle(command) {
		const step = ++settling;
		let cursor = (await observation.poll()).cursor;
		try { await command.submit(); }
		catch (error) { throw new Error(`managed command ${step} admission: ${error}`, { cause: error }); }
		for (;;) {
			const status = await command.status();
			if (status === "committed") return await command.result();
			if (status !== "pending") {
				// Include the retained outcome, so a refusal can be distinguished
				// from uncertain delivery without instrumenting the implementation.
				let detail;
				try { detail = JSON.stringify(await command.result()); }
				catch (error) { detail = String(error); }
				throw new Error(`managed command ${step} requires recovery: ${status}: ${detail}`);
			}
			cursor = (await observation.receive(cursor)).cursor;
		}
	}
	async function lifecycle(control, verb, revision) {
		const method = { pause: "preparePause", resume: "prepareResume", revoke: "prepareRevoke" }[verb];
		const request = await control[method](revision);
		held.push(request);
		if (verb === "pause" || verb === "revoke") sourcePaused = true;
		await request.submit();
		if (verb === "resume") sourcePaused = false;
		lifecycleChanged();
		return request;
	}

	try {
		const root = await app.management();
		held.push(root);
		const permissions = [
			"observeWorkspace", "interactWorkspace", "replaceWorkspace", "manageCustody", "resolvePending",
			"history", "readFile",
		];
		const request = await root.prepareIssue(
			(await root.inspect()).revision,
			JSON.stringify({ ceiling: permissions, configured: permissions }),
			"Room consumer",
			false,
			0,
			JSON.stringify({
				inspect: true,
				pause: true,
				resume: true,
				revoke: true,
				delegateControl: false,
				editCeiling: permissions,
				issueCeiling: null,
			}),
		);
		held.push(request);
		const [workspace, control] = await request.submit();
		held.push(workspace, control);
		activityReader = await workspace.activityReader();
		let activityCursor = "";
		const discovery = new Map();
		let discoverySnapshots = 0;
		activityPump = (async () => {
			while (!activityStopped) {
				let delivery;
				try { delivery = await activityReader.read(activityCursor, true); }
				catch (error) {
					if (activityStopped) return;
					if (!sourcePaused) throw error;
					await new Promise((resolve) => lifecycleChanged = resolve);
					continue;
				}
				if (activityStopped) return;
				if (delivery.gap) {
					discovery.clear();
					activityCursor = delivery.cursor;
					await workspace.resynchronizeDiscovery();
					continue;
				}
				if (delivery.unavailable && !sourcePaused) throw new Error("an active callback became unavailable");
				activityCursor = delivery.cursor;
				const event = delivery.event;
				if (!event) continue;
				if (event.notice.kind === "discoverySnapshot") {
					discovery.set(event.target.id, event.notice.snapshot);
					discoverySnapshots++;
				}
				messages.push(event);
				files.push(...event.files);
				if (event.authority) incoming.push(event.authority);
				if (event.route) incoming.push(event.route);
				received();
			}
		})();
		activityPump.catch((error) => { console.error("managed activity pump:",error); received(); });
		await app.startRooms((next) => { report = next; reported(); });
		let refused = false;
		try {
			await app.startRooms(() => {});
		} catch {
			refused = true;
		}
		if (!refused) throw new Error("the browser opened a second workspace activity");
		const directory = await workspace.prepareDirectory("home", location, "managed-member", true, false);
		held.push(directory);
		await directory.submit();
		// Discovery and registered presence are separate supervised owners.
		await ready(2);
		await bounded((async () => { while (discoverySnapshots === 0) {
			await new Promise((resolve) => received = resolve);
		} })(), "waiting for the initial directory snapshot");
		const priorSnapshots = discoverySnapshots;
		discovery.clear();
		await workspace.resynchronizeDiscovery();
		await bounded((async () => { while (discoverySnapshots === priorSnapshots) {
			await new Promise((resolve) => received = resolve);
		} })(), "waiting for an exported discovery refresh");
		if (!discovery.has("home")) throw new Error("refresh did not rebuild the directory projection");
		const observing = await workspace.prepareObservation();
		observation = await observing.submit();
		observing.free();
		const reader = await workspace.directoryReader("home");
		held.push(reader);
		await reader.list();
		const name = `managed-${key().slice(0, 8)}`;
		const create = await workspace.prepareCommand(
			"create",
			(await workspace.snapshot()).revision,
			"openManagedRoom",
			["home", name, "listed", "open", "open", `~${key()}`],
		);
		held.push(create);
		const result = await settle(create);
		const snapshot = await workspace.snapshot();
		const access = key();
		const management = key();
		const source = key();
		snapshot.intent.conversations.push({
			kind: "room",
			id: "room",
			directory: "home",
			name,
			source,
			access,
			accepted: null,
			seat: null,
			topic: null,
			files: null,
			moderator: null,
			control: management,
			reconnect: "requested",
			standing: null,
			draft: "",
		});
		snapshot.intent.active = "room";
		const acquisition = await create.prepareResultAcquisition(
			snapshot.revision,
			JSON.stringify([
				[coordinate("roomAccess", result.room), coordinate("roomAccess", access)],
				[coordinate("roomControl", result.control), coordinate("roomControl", management)],
			]),
			"[]",
			JSON.stringify(snapshot.intent),
			JSON.stringify(coordinate("sessionAccess", source)),
		);
		held.push(acquisition);
		await acquisition.submit();
		await ready(3);
		const say = await workspace.prepareCommand("say", (await workspace.snapshot()).revision, "say", [
			"room",
			"Hello Loam",
		]);
		held.push(say);
		const posted = await settle(say);
		if (!posted.line) throw new Error(`post returned no line authority: ${JSON.stringify(posted)}`);
		const said = await message("Hello Loam");
		if (!posted.line || said.notice.marker?.change !== "said") {
			throw new Error("post did not preserve its line authority and display identity");
		}
		const line = key();
		const afterPost = await workspace.snapshot();
		afterPost.intent.conversations.find((row) => row.id === "room").lines = [{
			id: said.notice.marker.id,
			handle: line,
		}];
		const acquireLine = await say.prepareResultAcquisition(
			afterPost.revision,
			JSON.stringify([[coordinate("line", posted.line), coordinate("line", line)]]),
			"[]",
			JSON.stringify(afterPost.intent),
		);
		held.push(acquireLine);
		await acquireLine.submit();
		await managedRoomPosts({workspace, held, settle, message, notice, lifecycle, control, coordinate, said});
		const peerTab = crypto.randomUUID();
		const peerMessages = [];
		let peerReceived = () => {};
		const peerNotice = async (matches) => {
			let timer;
			try {
				return await Promise.race([
					(async () => {
						while (!peerMessages.some(matches)) await new Promise((resolve) => peerReceived = resolve);
						return peerMessages.findLast(matches);
					})(),
					new Promise((_, reject) => timer = setTimeout(() => reject(new Error(`Counterpart notification missing: ${JSON.stringify(peerMessages)}`)), 3000)),
				]);
			} finally { clearTimeout(timer); }
		};
		const openPeer = async () => {
		peerStopped = false;
		peerApp = new binding.RoomsManagedApplication(peerTab, (source, reason) => console.error(source, reason));
		peerSession = await peerApp.workspace();
		held.push(peerSession);
		const peerObserving = await peerSession.prepareObservation();
		peerObservation = await peerObserving.submit();
		peerObserving.free();
		peerActivity = await peerSession.activityReader();
		peerPump = (async () => {
			let cursor = "";
			while (!peerStopped) {
				let delivery;
				try { delivery = await peerActivity.read(cursor, true); }
				catch (error) { if (peerStopped) return; throw error; }
				if (peerStopped) return;
				if (delivery.gap || delivery.unavailable) throw new Error("managed counterpart lost admitted activity");
				cursor = delivery.cursor;
				if (!delivery.event) continue;
				peerMessages.push(delivery.event);
				files.push(...delivery.event.files);
				if (delivery.event.authority) incoming.push(delivery.event.authority);
				if (delivery.event.route) incoming.push(delivery.event.route);
				peerReceived();
			}
		})();
		peerPump.catch((error) => { if (!peerStopped) console.error("managed counterpart activity:", error); peerReceived(); });
		if ((await peerSession.snapshot()).intent.connection !== "webrtc") {
		const connection = await peerSession.prepareCommand(`webrtc-${key()}`, (await peerSession.snapshot()).revision,
			"chooseConnection", ["webrtc", ""]);
		held.push(connection);
		if (await connection.submit() !== "committed") throw new Error("the WebRTC connection choice did not commit");
		}
		await peerApp.startRooms(() => {});
		};
		await openPeer();
		const peerDirectory = await peerSession.prepareDirectory("home", location, "managed-direct-peer", true, true);
		held.push(peerDirectory);
		await peerDirectory.submit();
		await peerNotice((event) => event.notice.kind === "registered");
		const peerReader = await peerSession.directoryReader("home");
		held.push(peerReader);
		const publication = (await peerReader.list()).rooms.find((row) => row.name === name);
		if (!publication) throw new Error("counterpart did not discover the exact public entry");
		const peerIntent = await peerSession.snapshot();
		const accept = await peerSession.preparePublicRoom(peerIntent.revision, JSON.stringify({
			id: "room", directory: "home", name, publication: publication.id, source: key(),
		}));
		held.push(accept);
		await accept.submit();
		if ((await peerSession.snapshot()).intent.active !== peerIntent.intent.active) {
			throw new Error("public room acquisition changed the reader's selection");
		}
		await peerNotice((event) => event.notice.metadata?.presence?.kind === "roster"
			&& event.notice.metadata.presence.names.includes("managed-member"));
		const beforeRestart = "Recorded before counterpart restart";
		const beforeRestartCommand = await workspace.prepareCommand("archive-restart", (await workspace.snapshot()).revision,
			"say", ["room", beforeRestart]);
		held.push(beforeRestartCommand);
		await settle(beforeRestartCommand);
		await peerNotice((event) => event.notice.text === beforeRestart);
		const peerHistory = await peerSession.deviceHistory(false);
		let retainedHistory;
		try {
			retainedHistory = await bounded((async () => {
				for (;;) {
					const page = await peerHistory.read(archiveFilter, "0", 100);
					const record = page.records.find((entry) => entry.record.text === beforeRestart)?.record;
					if (record) return record;
					await new Promise((resolve) => setTimeout(resolve, 10));
				}
			})(), "counterpart recording before reopen");
		} finally { peerHistory.free(); }
		const beforeReopen = (await peerSession.snapshot()).intent.conversations.find((row) => row.id === "room");
		if (beforeReopen.accepted != null || beforeReopen.access != null || beforeReopen.publication !== publication.id) {
			throw new Error("public membership retained a live entrance instead of its original publication");
		}
		// Retire the whole counterpart owner, then reopen its actual IndexedDB
		// bootstrap. The first peer keeps the exact publication alive. No fetched
		// entrance, command result or registration survives into the new owner.
		peerStopped = true;
		await peerObservation.cancel();
		peerObservation.free();
		peerObservation = null;
		await peerApp.close();
		await peerPump;
		peerActivity.free();
		for (const retired of [peerDirectory, peerReader, accept, peerSession]) {
			held.splice(held.indexOf(retired), 1);
			retired.free();
		}
		peerApp.free();
		peerMessages.length = 0;
		await openPeer();
		const restoredHistory = await peerSession.deviceHistory(false);
		try {
			const page = await restoredHistory.read(archiveFilter, "0", 100);
			if (!page.records.some((entry) => JSON.stringify(entry.record) === JSON.stringify(retainedHistory))) {
				throw new Error("cold IndexedDB reopen lost the original archive identity or content");
			}
		} finally { restoredHistory.free(); }
		const ownHistory = await workspace.deviceHistory(false);
		try {
			const page = await ownHistory.read(archiveFilter, "0", 100);
			if (page.records.some((entry) => entry.record.source === retainedHistory.source)) {
				throw new Error("local history disclosed another durable tab owner's records");
			}
		} finally { ownHistory.free(); }
		await peerNotice((event) => event.notice.metadata?.presence?.kind === "roster"
			&& event.notice.metadata.presence.names.includes("managed-member"));
		const afterReopen = (await peerSession.snapshot()).intent.conversations.find((row) => row.id === "room");
		if (JSON.stringify(afterReopen.publicEntry) !== JSON.stringify(beforeReopen.publicEntry)
			|| afterReopen.publication !== beforeReopen.publication
			|| afterReopen.source !== beforeReopen.source || afterReopen.accepted != null) {
			throw new Error("cold public recovery replaced its original source or publication");
		}
		const roomSelection = (await workspace.snapshot()).intent.conversations.find((row) => row.id === "room");
		const roomTyping = await workspace.typingSender("room", JSON.stringify(coordinate("roomSeat", roomSelection.seat)));
		held.push(roomTyping);
		await roomTyping.set(true);
		await peerNotice((event) => event.notice.kind === "typing" && event.notice.on === true);
		await roomTyping.set(false);
		await peerNotice((event) => event.notice.kind === "typing" && event.notice.on === false);
		const registration = await reader.memberRegistration("managed-direct-peer");
		const initiatingDirectory = (await workspace.snapshot()).intent.directories.find((row) => row.id === "home");
		if (!initiatingDirectory?.name || !initiatingDirectory.inbox) {
			throw new Error("the initiating nickname has no exact live registration");
		}
		const introduction = {
			access: initiatingDirectory.access, name: initiatingDirectory.name,
			callback: initiatingDirectory.inbox, registration, opening: "opening",
		};
		let introduce = await workspace.prepareCommand("introduce", (await workspace.snapshot()).revision,
			"startDirect", ["home", "managed-direct-peer", registration, "opening"]);
		held.push(introduce);
		let introduced = await settle(introduce);
		if (introduced.status === "pending") {
			await notice((event) => event.notice.kind === "introducible" && event.notice.registration === registration);
			introduce = await workspace.prepareCommand("introduce-ready", (await workspace.snapshot()).revision,
				"startDirect", ["home", "managed-direct-peer", registration, "opening"]);
			held.push(introduce);
			introduced = await settle(introduce);
		}
		if (introduced.status !== "ready") throw new Error("the exact introduction did not return its inbox");
		const directAccess = key();
		const directSource = key();
		const directIntent = await workspace.snapshot();
		directIntent.intent.conversations.push({
			kind: "direct", id: "direct", directory: "home", peer: "managed-direct-peer",
			access: directAccess, source: directSource, introduction, closed: false, draft: "",
		});
		const acquireDirect = await introduce.prepareResultAcquisition(directIntent.revision,
			JSON.stringify([[coordinate("directAccess", introduced.inbox), coordinate("directAccess", directAccess)]]),
			"[]", JSON.stringify(directIntent.intent), JSON.stringify(coordinate("sessionAccess", directSource)));
		held.push(acquireDirect);
		await acquireDirect.submit();
		await ready(4);
		const beforeDirectPost = await workspace.prepareCommand("before-direct-post", (await workspace.snapshot()).revision,
			"say", ["room", "Room before direct post"]);
		held.push(beforeDirectPost);
		await settle(beforeDirectPost);
		await message("Room before direct post");
		const peerCommand = async (operation, verb, ...args) => {
			const selected = await peerSession.snapshot();
			for (let attempt = 0; attempt < 4; attempt++) {
				const snapshot = attempt === 0 ? selected : await peerSession.snapshot();
				if (JSON.stringify(snapshot.intent) !== JSON.stringify(selected.intent)) throw new Error("counterpart gesture selection changed");
				const command = await peerSession.prepareCommand(`${operation}-${attempt}`, snapshot.revision, verb, args);
				held.push(command);
				let cursor = (await peerObservation.poll()).cursor;
				if (await command.submit() === "conflict") continue;
				for (;;) {
					const status = await command.status();
					if (status === "committed") return { command, result: await command.result() };
					if (status !== "pending") throw new Error(`managed counterpart receipt: ${status}`);
					cursor = (await peerObservation.receive(cursor)).cursor;
				}
			}
			throw new Error("managed counterpart admission repeatedly conflicted");
		};
		const peerMessage = async (text) => {
			return await peerNotice((event) => event.notice.text === text);
		};
		const directTyping = await managedDirect({ binding, workspace, peerSession, peerObservation, directAccess, held, coordinate, peerCommand, peerNotice, peerMessage, message, notice, settle, bounded, archiveFilter });
		const roomCheck = await workspace.prepareCommand("room-check", (await workspace.snapshot()).revision,
			"say", ["room", "Room still subscribed"]);
		held.push(roomCheck);
		await settle(roomCheck);
		await message("Room still subscribed");
		const bytes = new TextEncoder().encode("A file through the original grant");
		const upload = await workspace.prepareUpload(
			"upload",
			(await workspace.snapshot()).revision,
			"room",
			"With a file",
			"[]",
			["hello.txt", "revoked.txt"].map((name) =>
				new binding.RoomsBrowserSource(
					name,
					"text/plain",
					bytes.length,
					0,
					0,
					(offset, length) => Promise.resolve(bytes.slice(offset, offset + length)),
				)
			),
			undefined,
			new Uint32Array(),
		);
		held.push(upload);
		const uploaded = await settle(upload);
		if (!uploaded.filesComplete) throw new Error(`Upload failed: ${JSON.stringify(uploaded)}`);
		const event = await message("With a file");
		if (event.files.length !== 2 || event.files[0].description().name !== "hello.txt") {
			throw new Error("room notification lost its typed attachment");
		}
		const file = event.files[0];
		const read = await file.read("0", bytes.length);
		if (new TextDecoder().decode(read) !== new TextDecoder().decode(bytes)) {
			throw new Error("mediated file bytes differ");
		}
		const stoppedDisplay = new AbortController();
		stoppedDisplay.abort();
		let displayCancelled = false;
		try { await file.open(undefined, stoppedDisplay.signal); } catch { displayCancelled = true; }
		if (!displayCancelled) throw new Error("cancelled managed display retained a URL");
		let displayedBytes = 0;
		const displayed = await file.open((count) => { displayedBytes = count; });
		held.push(displayed);
		if (displayedBytes !== bytes.length || new TextDecoder().decode(await (await fetch(displayed.url)).arrayBuffer()) !== new TextDecoder().decode(bytes)) {
			throw new Error("managed display lost exact bytes or progress");
		}
		const archive = await workspace.deviceHistory(true);
		const archiveText = await workspace.deviceHistory(false);
		held.push(archive, archiveText);
		const archived = async (text) => {
			return await bounded((async () => {
				for (;;) {
					const page = await archive.read(archiveFilter, "0", 100);
					const record = page.records.find((entry) => entry.record.kind === "line" && entry.record.text === text)?.record;
					if (record && record.attachments.every((file) => file.blob != null)) return record;
					await new Promise((resolve) => setTimeout(resolve, 10));
				}
			})(), `waiting for independently recorded ${text}`);
		};
		const archivedFile = await archived("With a file");
		const archivedBlob = await archive.attachment(JSON.stringify(archivedFile), 0);
		held.push(archivedBlob);
		if (new TextDecoder().decode(await archivedBlob.read("0", bytes.length)) !== new TextDecoder().decode(bytes)) {
			throw new Error("managed archive lost captured attachment bytes");
		}
		const archivedDisplay = await archive.openAttachment(JSON.stringify(archivedFile), 0);
		held.push(archivedDisplay);
		if (new TextDecoder().decode(await (await fetch(archivedDisplay.url)).arrayBuffer()) !== new TextDecoder().decode(bytes)) {
			throw new Error("managed archive display lost captured bytes");
		}
		let textRefused = false;
		try { await archiveText.attachment(JSON.stringify(archivedFile), 0); } catch { textRefused = true; }
		if (!textRefused) throw new Error("text-only local history disclosed a blob");
		textRefused = false;
		try { await archiveText.openAttachment(JSON.stringify(archivedFile), 0); } catch { textRefused = true; }
		if (!textRefused) throw new Error("text-only history materialized a file");
		activityStopped = true;
		const unseen = await workspace.prepareCommand("no-viewer", (await workspace.snapshot()).revision,
			"say", ["room", "Recorded without a presentation consumer"]);
		held.push(unseen);
		await settle(unseen);
		await activityPump;
		await archived("Recorded without a presentation consumer");
		await lifecycle(control, "pause", (await control.inspect()).revision);
		let archiveRefused = false;
		try { await archivedBlob.read("0", bytes.length); } catch { archiveRefused = true; }
		if (!archiveRefused) throw new Error("archived blob bypassed paused viewer admission");
		for (const open of [() => file.open(), () => archive.openAttachment(JSON.stringify(archivedFile), 0)]) {
			let blocked = false;
			try { await open(); } catch { blocked = true; }
			if (!blocked) throw new Error("display materialization bypassed paused source admission");
		}
		for (const sender of [roomTyping, directTyping]) {
			let blocked = false;
			try { await sender.set(true); } catch { blocked = true; }
			if (!blocked) throw new Error("a paused initiating source sent typing");
		}
		refused = false;
		try {
			await file.read("0", bytes.length);
		} catch {
			refused = true;
		}
		if (!refused) throw new Error("retained file bypassed the original paused grant");
		await lifecycle(control, "resume", (await control.inspect()).revision);
		await archivedBlob.read("0", bytes.length);
		await file.read("0", bytes.length);
		file.release();
		refused = false;
		try {
			await file.read("0", bytes.length);
		} catch {
			refused = true;
		}
		if (!refused) throw new Error("released incoming file regained custody");
		const retained = event.files[1];
		await retained.read("0", bytes.length);
		await managedRetention({ workspace, peer: peerSession, observation, blob: archivedBlob, bounded });
		await lifecycle(control, "revoke", (await control.inspect()).revision);
		refused = false;
		try {
			await retained.read("0", bytes.length);
		} catch {
			refused = true;
		}
		if (!refused) throw new Error("retained file bypassed the original revoked grant");
		await app.stopRooms();
		await app.stopRooms();
		report = { ready: 0, failures: [] };
		await lifecycle(root, "pause", (await root.inspect()).revision);
		await app.startRooms((next) => {
			report = next;
			reported();
		});
		while (!report.sourceFailure) await new Promise((resolve) => reported = resolve);
		if (report.ready !== 0) throw new Error("paused workspace startup reported readiness");
		await lifecycle(root, "resume", (await root.inspect()).revision);
		await app.stopRooms();
	} catch (error) {
		console.error("managed Rooms journey failed before cleanup:", error);
		throw error;
	} finally {
		activityStopped = true;
		lifecycleChanged();
		peerStopped = true;
		if (peerObservation) { await peerObservation.cancel(); peerObservation.free(); }
		if (observation) {
			await observation.cancel();
			observation.free();
		}
		for (const file of files) {
			file.release();
			file.free();
		}
		for (const handle of held.reverse()) handle.free();
		for (const hand of incoming) { hand.release(); hand.free(); }
		if (peerApp) {
			await peerApp.close();
			if (peerPump) await peerPump.catch((error) => { if (!peerStopped) throw error; });
			peerActivity?.free();
			peerApp.free();
		}
		await app.close();
		if (activityPump) await activityPump;
		activityReader?.free();
		app.free();
	}
}
