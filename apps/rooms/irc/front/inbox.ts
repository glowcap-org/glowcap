// Direct-message inboxes for the IRC client front. Disconnect retires every
// alias and leaves old issued capabilities on their exact disconnected actor;
// reconnect therefore mints fresh authority and never retargets an old holder.

import { type Behavior, currentSession, type Host, Ref, type Session } from "@pancake/runtime";
import { readAttachments } from "../../lib/attachment.ts";
import { type InboxOfferer, type InboxPublisher, inboxPublisher } from "../../lib/dm_inbox.ts";
import { DM } from "../../lib/protocol.ts";
import type { Directory } from "../../lib/room_client.ts";
import { ircFold } from "../protocol.ts";
import { IRC_FRONT_CLIENT_LIMIT, IRC_FRONT_INBOX_LIMIT } from "./limits.ts";

export const IRC_FRONT_INBOX_ROUTE_LIMIT = IRC_FRONT_CLIENT_LIMIT;

interface InboxRoute {
	directory: Directory | null;
	receive: ((peer: string, text: string, attachmentCount: number) => void) | null;
	onError: ((peer: string, error: unknown) => void) | null;
	offerer: InboxOfferer;
}

export class IrcInboxRouter {
	readonly #publisher: InboxPublisher;
	readonly #routes = new Map<string, InboxRoute>();

	constructor(publisher: InboxPublisher) {
		this.#publisher = publisher;
	}

	attach(
		nick: string,
		directory: Directory,
		receive: (peer: string, text: string, attachmentCount: number) => void,
		onError: (peer: string, error: unknown) => void,
	): { offer: (peer: string) => void; detach: () => Promise<void> } {
		const key = ircFold(nick);
		let route = this.#routes.get(key);
		if (route === undefined) {
			if (this.#routes.size >= IRC_FRONT_INBOX_ROUTE_LIMIT) {
				throw new Error(`IRC front already holds ${IRC_FRONT_INBOX_ROUTE_LIMIT} active inbox routes`);
			}
			const state = { directory: null, receive: null, onError: null } as InboxRoute;
			state.offerer = this.#publisher.offerer({
				dir: () => state.directory,
				behaviorFor: (peer) => this.#behavior(state, peer),
				onError: (peer, error) => state.onError?.(peer, error),
			});
			route = state;
			this.#routes.set(key, route);
		}
		if (route.receive !== null) throw new Error(`IRC nickname "${nick}" already has an active inbox route`);
		route.directory = directory;
		route.receive = receive;
		route.onError = onError;
		return {
			offer: route.offerer.offer,
			detach: async () => {
				if (route!.directory !== directory) return;
				route!.directory = null;
				route!.receive = null;
				route!.onError = null;
				this.#routes.delete(key);
				await route!.offerer.close();
			},
		};
	}

	#behavior(route: InboxRoute, peer: string): Behavior {
		return (verb, args) => {
			if (verb !== DM) throw new Error(`dm inbox has no method ${verb}`);
			const reply = args[1];
			const arriving = currentSession();
			const attachments = readAttachments(args, reply instanceof Ref ? 2 : 1);
			if (arriving !== null) {
				for (const attachment of attachments) {
					releaseIrcRef(arriving, attachment.blob, "unsupported DM file");
				}
				if (reply instanceof Ref) releaseIrcRef(arriving, reply, "unused DM reply route");
			}
			if (route.receive === null) throw new Error("the IRC recipient disconnected");
			route.receive(peer, typeof args[0] === "string" ? args[0] : "", attachments.length);
			return null;
		};
	}
}

export function frontInboxRouter(host: Host): IrcInboxRouter {
	return new IrcInboxRouter(inboxPublisher(host, IRC_FRONT_INBOX_LIMIT));
}

/** Return one capability occurrence IRC cannot represent without replacing
 * the accepted message or socket refusal that remains the primary outcome. */
export function releaseIrcRef(session: Session, ref: Ref, what: string): void {
	try {
		session.release(ref);
	} catch (error) {
		console.error(`rooms IRC front could not release ${what}:`, reason(error));
	}
}

function reason(error: unknown): string {
	return error instanceof Error ? error.message : String(error);
}
