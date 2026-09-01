// Durable IRC network ownership and its demand-enacted feed transport.

import type { Argument } from "@pancake/runtime";
import type { IrcChannelRelay } from "../../irc/bridge/outbound.ts";
import { ircFold } from "../../irc/protocol.ts";
import { type IrcNetworkChoice, sameIrcNetworkChoice } from "../../lib/irc_gateway_client.ts";
import type { TroubleJournal } from "../journal.ts";
import { type DrivenIrcBridge, IrcNetworkFeed } from "./driver.ts";

export interface OperatorIrcNetwork {
	readonly key: string;
	readonly choice: IrcNetworkChoice;
	ready: Promise<void>;
	tail: Promise<void>;
	feed: IrcNetworkFeed | null;
}

export function ircNetworkKey(network: string): string {
	return ircFold(network);
}

/** The operator's retained network capabilities. A feed exists only while at
 * least one channel lease enacts its connection. */
export class OperatorIrcNetworks {
	readonly #networks = new Map<string, OperatorIrcNetwork>();

	constructor(readonly journal: TroubleJournal) {}

	async open(choice: IrcNetworkChoice, remember: () => Promise<void>): Promise<void> {
		const key = ircNetworkKey(choice.network);
		const existing = this.#networks.get(key);
		if (existing != null) {
			return await this.mutate(existing, () => {
				if (!sameIrcNetworkChoice(existing.choice, choice)) {
					throw new Error(`IRC network ${choice.network} is already open with different connection settings`);
				}
			});
		}
		const owner: OperatorIrcNetwork = {
			key,
			choice,
			ready: Promise.resolve(),
			tail: Promise.resolve(),
			feed: null,
		};
		this.#networks.set(key, owner);
		owner.ready = remember();
		try {
			await owner.ready;
		} catch (error) {
			if (this.#networks.get(key) === owner) this.#networks.delete(key);
			throw error;
		}
	}

	get(network: string): OperatorIrcNetwork | null {
		return this.#networks.get(ircNetworkKey(network)) ?? null;
	}

	choice(network: string): IrcNetworkChoice | null {
		return this.get(network)?.choice ?? null;
	}

	/** Serialize channel and retirement mutations beneath one network owner. */
	mutate<T>(owner: OperatorIrcNetwork, action: () => T | Promise<T>): Promise<T> {
		const result = owner.tail.then(async () => {
			await owner.ready;
			if (this.#networks.get(owner.key) !== owner) {
				throw new Error(`IRC network ${owner.choice.network} is not open`);
			}
			return await action();
		});
		owner.tail = result.then(() => {}, () => {});
		return result;
	}

	attach(owner: OperatorIrcNetwork, bridge: DrivenIrcBridge, relay: IrcChannelRelay): void {
		let feed = owner.feed;
		if (feed == null) {
			owner.feed = feed = new IrcNetworkFeed(owner.choice, (source, error) => this.journal.note(source, error));
		}
		feed.add(bridge, relay);
		feed.start();
	}

	detach(owner: OperatorIrcNetwork, bridge: DrivenIrcBridge): void {
		const feed = owner.feed;
		feed?.remove(bridge);
		if (feed?.empty) {
			feed.close();
			owner.feed = null;
		}
	}

	retire(owner: OperatorIrcNetwork): void {
		owner.feed?.close();
		owner.feed = null;
		if (this.#networks.get(owner.key) === owner) this.#networks.delete(owner.key);
	}

	snapshot(): Argument[] {
		return [...this.#networks.values()].map(({ choice, feed }) => [
			choice.network,
			feed?.status ?? "dormant",
			`${choice.host}:${choice.port}`,
			choice.nick,
			choice.sasl?.account ?? "",
			choice.tls,
			feed?.problem ?? "",
		]);
	}

	closeAll(): void {
		for (const owner of this.#networks.values()) owner.feed?.close();
		this.#networks.clear();
	}
}
