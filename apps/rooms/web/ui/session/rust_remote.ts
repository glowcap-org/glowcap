// Presentation adaptation for the Rust-owned session and file objects.
import { applicationModule } from "../application.ts";
import type { RoomsBrowserFile, RoomsBrowserSession } from "../../../../../zig-out/wasm/rooms/rooms_browser.js";
import type { AttachmentSource } from "../../../lib/attachment.ts";
import type { AttachedFile, AttachedRoomsRemote } from "./remote.ts";

function sources(files: AttachmentSource[]) {
	return files.map((file) =>
		new (applicationModule().RoomsBrowserSource)(
			file.name,
			file.mime,
			file.bytes?.length ?? file.size ?? 0,
			file.width ?? 0,
			file.height ?? 0,
			(offset: number, length: number) => {
				if (file.bytes != null) return Promise.resolve(file.bytes.subarray(offset, offset + length));
				if (file.read != null) return file.read(offset, length);
				return Promise.reject(new Error("The selected file has no byte source"));
			},
		)
	);
}
function fileObject(file: AttachedFile): RoomsBrowserFile {
	if (!(file instanceof applicationModule().RoomsBrowserFile)) {
		throw new Error("This file belongs to another session runtime");
	}
	return file;
}
export function rustRemote(session: RoomsBrowserSession): AttachedRoomsRemote {
	return {
		eraseBrowserArchive: () => session.eraseBrowserArchive(),
		chooseDirect: (directory, who, select) => session.chooseDirect(directory, who, select),
		reachDirectory: (locator, nick, defaultDirectory, signal) =>
			session.reachDirectory(locator, nick, defaultDirectory, signal),
		joinDestination: (destination, nick, defaultDirectory, signal) =>
			session.joinDestination(destination, nick, defaultDirectory, signal),
		acceptInvitation: (invitation) => session.acceptInvitation(invitation),
		takeRoomLink: (link, label) => session.takeRoomLink(link, label),
		chooseRoom: (directory, name, policy) => session.chooseRoom(directory, name, policy),
		operationsView: {
			retire: (category, query, limit, kind) => session.retireOperatorMatches(category, query, limit, kind),
			run: (capability, action, args) => session.runOperation(capability, action, args),
			loadPage: (category) => session.loadOperatorPage(category),
			listen: (listener) => session.listenOperations(listener),
			refresh: (capability, search, kind) => session.refreshOperations(capability, search, kind),
		},
		encodeWorkspace: (choices) => session.encodeWorkspace(choices),
		selectWorkspace: (persistence, link, home) => session.selectWorkspace(persistence, link, home),
		drafts: {
			stage: (conversation, text) => session.stageDraft(conversation, text),
			pending: (conversation) => session.pendingDraft(conversation),
			retire: (conversation) => session.retireDraft(conversation),
			cancelSave: (conversation) => session.cancelDraftSave(conversation),
			clearSent: (conversation) => session.clearSentDraft(conversation),
			save: (conversation, text, delayed) => session.saveDraft(conversation, text, delayed),
		},
		runCommand: (name, args) => session.runCommand(undefined, name, args),
		writes: {
			files: (conversation, caption, files) =>
				session.sendFiles(undefined, undefined, conversation, caption, sources(files)),
			refile: (conversation, line, caption, keep, files) =>
				session.refileLine(
					undefined,
					undefined,
					conversation,
					line,
					caption,
					new Uint32Array(keep),
					sources(files),
				),
			checkpoint: (value, adopt) => session.replaceCheckpoint(undefined, undefined, JSON.stringify(value), adopt),
		},
		driving: () => session.driving(),
		settleRevision: (revision) => session.settleRevision(revision),
		snapshot: () => session.snapshot(),
		verifySibling: (link) => session.verifySibling(link),
		watch: (changed, _event, operations, history) => session.watch(changed, undefined, operations, history),
		listenLines: (listener) => session.listenLines(listener),
		listenHistory: (listener) => session.listenHistory(listener),
		command: (id, base, name, args) => session.command(id, base, name, args),
		setTyping: (conversation, on) => session.typing(conversation, on),
		lastEditableLine: (conversation) => session.lastEditableLine(conversation),
		ignoredNickname: (conversation) => session.ignoredNickname(conversation),
		inviteToRoom: (conversation, who) => session.inviteToRoom(conversation, who),
		roomLinkFor: (conversation, name) => session.roomLinkFor(conversation, name),
		editLine: (id, base, conversation, line, text) =>
			session.command(id, base, "editLine", [conversation, String(line), text]),
		withdrawLine: (id, base, conversation, line) =>
			session.command(id, base, "withdrawLine", [conversation, String(line)]),
		replace: (id, base, checkpoint) => session.replaceCheckpoint(id, base, JSON.stringify(checkpoint), false),
		adoptWorkspace: (id, base, checkpoint) => session.replaceCheckpoint(id, base, JSON.stringify(checkpoint), true),
		sendFiles: (id, base, conversation, caption, files) =>
			session.sendFiles(id, base, conversation, caption, sources(files)),
		refileLine: (id, base, conversation, line, caption, keep, files) =>
			session.refileLine(id, base, conversation, line, caption, Uint32Array.from(keep), sources(files)),
		readHistory: (kind, directory, conversation) => session.readHistory(kind, directory, conversation),
		roomBridgeForm: (conversation) => session.roomBridgeForm(conversation),
		operatorSnapshot: (scope, query = "", kind) => session.operatorSnapshot(scope, query, kind),
		operatorPage: (scope, category, cursor, query = "", kind) =>
			session.operatorPage(scope, category, cursor, query, kind),
		operatorRetireMatching: (scope, category, query, limit, kind) =>
			session.operatorRetireMatching(scope, category, query, limit, kind),
		operationsSnapshot: (scope, capability) => session.operationsSnapshot(scope, capability),
		shareArchiveHistory: (kind, conversation, peer) => session.shareArchive(kind, conversation, peer, false),
		offerDurableArchive: (kind, conversation, peer) => session.shareArchive(kind, conversation, peer, true),
		readArchiveShare: (id) => session.readArchiveShare(id),
		dropArchiveShare: (id) => session.dropArchiveShare(id),
		listIssuedArchiveShares: () => session.listIssuedArchiveShares(),
		revokeIssuedArchiveShare: (id) => session.revokeIssuedArchiveShare(id),
		publishPeeredRoom: (id, base, intent) =>
			session.command(id, base, "publishPeeredRoom", [JSON.stringify(intent)]),
		revokePeeredRoom: (id, base, peer) => session.command(id, base, "revokePeeredRoom", [peer]),
		fetchAttachment: (attachment, progress, signal) => fileObject(attachment).open(progress, signal),
		fetchArchivedAttachment: (record, index, progress, signal) =>
			session.openArchivedFile(JSON.stringify(record), index, progress, signal),
		releaseAttachment: (attachment) => fileObject(attachment).release(),
		resolveEffect: (id, outcome) => session.resolveEffect(id, outcome === "committed"),
		resumeEffect: (id) => session.resumeEffect(id),
		issueGrant: (id, rights, label, history) => session.issueGrant(id, rights, label, history),
		revokeGrant: (id) => session.revokeGrant(id),
		changeGrant: (id, patch) => session.changeGrant(id, patch.rights, patch.history, patch.suspended, patch.note),
	};
}
