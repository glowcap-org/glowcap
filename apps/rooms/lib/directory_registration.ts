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

const REGISTER_ACK_TIMEOUT_MS = 10_000;

export interface DirectoryRegisterOptions {
	onMintInboxFor?: (peer: string, registrationId: string) => void;
	onDirectRequested?: (peer: string, registrationId: string) => void;
	reconnectVoucher?: Uint8Array;
}

export class DirectoryRegistration {
	readonly #session: Session;
	readonly #directory: Ref;
	readonly #releaseLocal: (ref: Ref) => void;
	readonly #onIntroducible: (peer: string, registrationId: string) => void;
	#nameCapability: Promise<Ref> | null = null;

	constructor(
		session: Session,
		directory: Ref,
		releaseLocal: (ref: Ref) => void,
		onIntroducible: (peer: string, registrationId: string) => void,
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
		const { onMintInboxFor, onDirectRequested, reconnectVoucher } = options;
		const acknowledgement = Promise.withResolvers<string>();
		// Capability ownership settles before this is awaited below. Observe an
		// earlier refusal now without changing the later caller-visible answer.
		void acknowledgement.promise.catch(() => {});
		let settled = false;
		const settle = (complete: () => void) => {
			if (settled) return;
			settled = true;
			clearTimeout(timer);
			complete();
		};
		const timer = setTimeout(
			() => settle(() => acknowledgement.reject(new Error(`register("${nick}") was not acknowledged in time`))),
			REGISTER_ACK_TIMEOUT_MS,
		);
		let inbox: Ref;
		try {
			inbox = this.#session.spawn((verb, args) => {
				releaseUnclaimedCapabilityArguments(
					this.#session,
					args,
					"the registration inbox could not return an unexpected capability",
				);
				if (verb !== NOTIFY) return null;
				const event = args[0];
				const peer = typeof args[1] === "string" ? args[1] : "";
				const registrationId = typeof args[2] === "string" ? args[2] : "";
				if (event === "registered") {
					parseRegistrationId(registrationId, `register("${nick}")`);
					settle(() => acknowledgement.resolve(registrationId));
				} else if (event === "mintInboxFor" && peer) {
					onMintInboxFor?.(peer, parseRegistrationId(registrationId, "mintInboxFor"));
				} else if (event === DIRECT_REQUESTED && peer) {
					onDirectRequested?.(peer, parseRegistrationId(registrationId, "directRequested"));
				} else if (event === "introducible" && peer) {
					this.#onIntroducible(peer, parseRegistrationId(registrationId, "introducible"));
				}
				return null;
			});
		} catch (error) {
			settle(() => acknowledgement.reject(error));
			return acknowledgement.promise;
		}
		let sent: ReturnType<Session["send"]>;
		try {
			sent = this.#session.send(
				this.#directory,
				REGISTER,
				reconnectVoucher === undefined ? [nick, locator, inbox] : [nick, locator, inbox, reconnectVoucher],
			);
		} catch (error) {
			void retainCleanupFailures(error, [() => this.#session.release(inbox)]).then((primary) =>
				settle(() => acknowledgement.reject(primary))
			);
			return acknowledgement.promise;
		}
		const prior = this.#nameCapability;
		const pendingNameCapability = sent.then(
			(reply) => {
				this.#releaseLocal(inbox);
				if (!(reply instanceof Ref)) {
					const error = new Error(`register("${nick}") did not return a name capability`);
					settle(() => acknowledgement.reject(error));
					throw error;
				}
				return reply;
			},
			async (error) => {
				const primary = await retainCleanupFailures(error, [() => this.#session.release(inbox)]);
				settle(() => acknowledgement.reject(primary));
				throw primary;
			},
		);
		const nameCapability = claimCapabilityWithin(
			this.#session,
			pendingNameCapability,
			`register("${nick}") did not answer with its name capability`,
			REQUEST_TIMEOUT_MS,
		);
		this.#nameCapability = nameCapability;
		void nameCapability.then(
			() => {
				if (this.#nameCapability === nameCapability && prior != null) {
					void prior.then(this.#releaseLocal, () => {});
				}
			},
			() => {
				if (this.#nameCapability === nameCapability) this.#nameCapability = prior;
			},
		);
		// Capability ownership commits or rolls back before this attempt answers.
		// The acknowledgement names that committed registration; it must not race
		// ahead and expose the replacement promise as the current authority.
		return nameCapability.then(() => acknowledgement.promise);
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

	async offerInbox(forNick: string, registrationId: string, inbox: Ref): Promise<void> {
		await ask(
			this.#session,
			this.#directory,
			OFFER_INBOX,
			[forNick, registrationId, inbox],
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
