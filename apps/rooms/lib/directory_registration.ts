// One Directory connection's registered nickname and direct-message discovery.

import { Ref, retainCleanupFailures, type Session } from "@glowcap/runtime";
import { ask } from "./ask.ts";
import { claimCapabilityWithin } from "./capability_cleanup.ts";
import { parseRegistrationId } from "./directory_publications.ts";
import { REQUEST_TIMEOUT_MS } from "./limits.ts";
import { releaseUnclaimedCapabilityArguments } from "./argument_custody.ts";
import {
	DIRECT_REQUESTED,
	MEMBER_REGISTRATION,
	NOTIFY,
	OFFER_INBOX,
	REGISTER,
	REQUEST_DIRECT,
	VOUCHER,
} from "./protocol.ts";

export interface DirectoryRegisterOptions {
	onMintInboxFor?: (peer: string, registrationId: string, opening: string) => void;
	onDirectRequested?: (peer: string, registrationId: string) => void;
	reconnectVoucher?: Uint8Array;
}

export class DirectoryRegistration {
	readonly #session: Session;
	readonly #directory: Ref;
	readonly #releaseLocal: (ref: Ref) => void;
	readonly #onIntroducible: (peer: string, registrationId: string, opening: string) => void;
	#nameCapability: Promise<Ref> | null = null;
	#registering = false;

	constructor(
		session: Session,
		directory: Ref,
		releaseLocal: (ref: Ref) => void,
		onIntroducible: (peer: string, registrationId: string, opening: string) => void,
	) {
		this.#session = session;
		this.#directory = directory;
		this.#releaseLocal = releaseLocal;
		this.#onIntroducible = onIntroducible;
	}

	register(
		nick: string,
		locator: string,
		options: DirectoryRegisterOptions = {},
	): Promise<string> {
		if (this.#registering) return Promise.reject(new Error("a directory registration is already pending"));
		const { onMintInboxFor, onDirectRequested, reconnectVoucher } = options;
		let registrationId: string | null = null;
		const inbox = this.#session.spawn((verb, args) => {
			releaseUnclaimedCapabilityArguments(
				this.#session,
				args,
				"the registration inbox could not return an unexpected capability",
			);
			if (verb !== NOTIFY) return null;
			const event = args[0];
			const peer = typeof args[1] === "string" ? args[1] : "";
			const id = typeof args[2] === "string" ? args[2] : "";
			if (event === "mintInboxFor" && peer) {
				onMintInboxFor?.(peer, parseRegistrationId(id, "mintInboxFor"), parseDirectOpening(args[3]));
			} else if (event === DIRECT_REQUESTED && peer) {
				onDirectRequested?.(peer, parseRegistrationId(id, "directRequested"));
			} else if (event === "introducible" && peer) {
				this.#onIntroducible(peer, parseRegistrationId(id, "introducible"), parseDirectOpening(args[3]));
			}
			return null;
		});
		const prior = this.#nameCapability;
		this.#registering = true;
		const nameCapability = claimCapabilityWithin(
			this.#session,
			() => {
				let sent: ReturnType<Session["send"]>;
				try {
					sent = this.#session.send(
						this.#directory,
						REGISTER,
						reconnectVoucher === undefined
							? [nick, locator, inbox]
							: [nick, locator, inbox, reconnectVoucher],
					);
				} catch (error) {
					return retainCleanupFailures(error, [() => this.#session.release(inbox)]).then((primary) => {
						throw primary;
					});
				}
				return sent.then(
					(reply) => {
						this.#releaseLocal(inbox);
						try {
							if (
								!Array.isArray(reply) || reply.length !== 3 || reply[0] !== nick ||
								!(reply[2] instanceof Ref)
							) {
								throw new Error(
									`register("${nick}") did not return its committed name, identity and capability`,
								);
							}
							registrationId = parseRegistrationId(reply[1], `register("${nick}")`);
							return reply[2];
						} catch (error) {
							releaseUnclaimedCapabilityArguments(
								this.#session,
								[reply],
								"the invalid registration result could not return its capabilities",
							);
							throw error;
						}
					},
					async (error) => {
						throw await retainCleanupFailures(error, [() => this.#session.release(inbox)]);
					},
				);
			},
			`register("${nick}") did not answer with its name capability`,
			REQUEST_TIMEOUT_MS,
		);
		this.#nameCapability = nameCapability;
		void nameCapability.then(
			() => {
				this.#registering = false;
				if (this.#nameCapability === nameCapability && prior != null) {
					void prior.then(this.#releaseLocal, () => {});
				}
			},
			() => {
				this.#registering = false;
				if (this.#nameCapability === nameCapability) this.#nameCapability = prior;
			},
		);
		return nameCapability.then(() => {
			if (registrationId === null) throw new Error("registration result has no identity");
			return registrationId;
		});
	}

	async requestDirect(peer: string, registrationId: string): Promise<void> {
		await ask(
			this.#session,
			this.#directory,
			REQUEST_DIRECT,
			[peer, registrationId],
			`the directory did not answer requesting a reciprocal route from "${peer}"`,
		);
	}

	async memberRegistration(peer: string): Promise<string> {
		const registrationId = await ask(
			this.#session,
			this.#directory,
			MEMBER_REGISTRATION,
			[peer],
			`the directory did not answer resolving the current registration for "${peer}"`,
		);
		return parseRegistrationId(registrationId, `memberRegistration("${peer}")`);
	}

	async nameVoucher(): Promise<Uint8Array | null> {
		const pending = this.#nameCapability;
		if (pending == null) return null;
		const nameCapability = await pending;
		const voucher = await ask(
			this.#session,
			nameCapability,
			VOUCHER,
			[],
			"the directory did not answer minting a name voucher",
		);
		if (!(voucher instanceof Uint8Array)) throw new Error("the directory answered an invalid name voucher");
		return voucher;
	}

	async offerInbox(forNick: string, registrationId: string, opening: string, inbox: Ref): Promise<void> {
		await ask(
			this.#session,
			this.#directory,
			OFFER_INBOX,
			[forNick, registrationId, parseDirectOpening(opening), inbox],
			`the directory did not answer offering an inbox for ${forNick}`,
		);
	}

	/** Remove and return the current name capability after any replacement
	 * attempt settles. A failed replacement restores its predecessor before this
	 * loop observes the field again. */
	async takeNameCapability(): Promise<Ref | null> {
		let pending = this.#nameCapability;
		while (pending != null) {
			const capability = await pending.catch(() => null);
			if (this.#nameCapability === pending) {
				this.#nameCapability = null;
				return capability;
			}
			pending = this.#nameCapability;
		}
		return null;
	}
}

/** Opening identity is descriptive and bounded; registrations own authority. */
export function parseDirectOpening(value: unknown): string {
	if (typeof value !== "string" || value.length === 0 || value.length > 128) {
		throw new Error("a direct opening needs a bounded identity");
	}
	return value;
}
