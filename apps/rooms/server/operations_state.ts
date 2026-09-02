// Durable intent for operator-managed listeners and IRC bridges. This document
// may contain a shared IRC feed credential, so it stays under the server's
// mode-0700 state directory and never enters snapshots or diagnostics.

import * as z from "zod/mini";
import { DURABLE_SWISS_ENTROPY_BYTES } from "@glowcap/runtime";
import {
	type IrcBridgeIntent,
	IrcBridgeIntentSchema,
	type IrcNetworkChoice,
	IrcNetworkChoiceSchema,
	sameIrcNetworkChoice,
} from "./irc_gateway/model.ts";
import { listenerOptionsFitTransport, ListenerOptionsSchema, ListenerTransportSchema } from "../lib/listeners.ts";
import { MAX_OPERATIONS_ROWS } from "../lib/limits.ts";
import { atomicWrite, readBoundedText } from "../lib/durable_file.ts";

const FILE = "operations.json";
const VERSION = 1;
const MAX_STATE_BYTES = 2 * 1024 * 1024;
const MAX_LISTENERS = 8;

export class RoomServerOperationsStateError extends Error {}

export const ListenerIntentSchema = z.strictObject({
	transport: ListenerTransportSchema,
	options: ListenerOptionsSchema,
});

const AuthorityEntropySchema = z.string().check(
	z.regex(new RegExp(`^[0-9a-f]{${DURABLE_SWISS_ENTROPY_BYTES * 2}}$`)),
);
const IrcBridgeAuthoritySchema = z.strictObject({
	publicationId: z.string().check(z.minLength(1), z.maxLength(128)),
	roomEntropy: AuthorityEntropySchema,
	stewardEntropy: AuthorityEntropySchema,
	generation: z.int().check(z.gte(0), z.lte(Number.MAX_SAFE_INTEGER)),
	issued: z.boolean(),
});

export type IrcBridgeAuthorityState = z.infer<typeof IrcBridgeAuthoritySchema>;

const OperationsDiskStateShapeSchema = z.strictObject({
	version: z.literal(VERSION),
	listeners: z.array(ListenerIntentSchema).check(z.maxLength(MAX_LISTENERS)),
	ircNetworks: z.array(IrcNetworkChoiceSchema).check(z.maxLength(MAX_OPERATIONS_ROWS)),
	ircBridges: z.array(IrcBridgeIntentSchema).check(z.maxLength(MAX_OPERATIONS_ROWS)),
	ircBridgeAuthorities: z.array(IrcBridgeAuthoritySchema).check(z.maxLength(MAX_OPERATIONS_ROWS)),
});

function validRelations(state: {
	listeners: readonly z.infer<typeof ListenerIntentSchema>[];
	ircNetworks: readonly IrcNetworkChoice[];
	ircBridges: readonly IrcBridgeIntent[];
	ircBridgeAuthorities: readonly IrcBridgeAuthorityState[];
}): boolean {
	const transports = new Set<string>();
	for (const listener of state.listeners) {
		if (transports.has(listener.transport) || !listenerOptionsFitTransport(listener.transport, listener.options)) {
			return false;
		}
		transports.add(listener.transport);
	}
	const channels = new Set<string>();
	const networks = new Map<string, IrcNetworkChoice>();
	const publicationIds = new Set<string>();
	const authorityEntropy = new Set<string>();
	for (const network of state.ircNetworks) {
		const key = network.network.toLowerCase();
		if (networks.has(key)) return false;
		networks.set(key, network);
	}
	for (const bridge of state.ircBridges) {
		const network = bridge.network.toLowerCase();
		if (!networks.has(network)) return false;
		const key = `${network}\u0000${bridge.channel.toLowerCase()}`;
		if (channels.has(key)) return false;
		channels.add(key);
		if (bridge.publicationId != null) {
			if (publicationIds.has(bridge.publicationId)) return false;
			publicationIds.add(bridge.publicationId);
		}
	}
	const authorityPublications = new Set<string>();
	for (const authority of state.ircBridgeAuthorities) {
		if (!publicationIds.has(authority.publicationId) || authorityPublications.has(authority.publicationId)) {
			return false;
		}
		authorityPublications.add(authority.publicationId);
		if (authorityEntropy.has(authority.roomEntropy) || authorityEntropy.has(authority.stewardEntropy)) return false;
		authorityEntropy.add(authority.roomEntropy);
		authorityEntropy.add(authority.stewardEntropy);
	}
	if (authorityPublications.size !== publicationIds.size) return false;
	return true;
}

export const OperationsDiskStateSchema = OperationsDiskStateShapeSchema.check(
	z.refine(validRelations, "listener transports, IRC channels, and bridge publication identities must be unique"),
);

export type ListenerIntent = z.infer<typeof ListenerIntentSchema>;
export type { IrcBridgeIntent };
type OperationsDiskState = z.infer<typeof OperationsDiskStateSchema>;

function fresh(): OperationsDiskState {
	return { version: VERSION, listeners: [], ircNetworks: [], ircBridges: [], ircBridgeAuthorities: [] };
}

function parse(text: string): OperationsDiskState {
	let decoded: unknown;
	try {
		decoded = JSON.parse(text);
	} catch {
		throw new Error("Rooms server operations state is not JSON");
	}
	const parsed = z.safeParse(OperationsDiskStateSchema, decoded);
	if (!parsed.success) {
		throw new Error(`Rooms server operations state is invalid:\n${z.prettifyError(parsed.error)}`);
	}
	return parsed.data;
}

function authorityEntropy(): string {
	return [...crypto.getRandomValues(new Uint8Array(DURABLE_SWISS_ENTROPY_BYTES))]
		.map((byte) => byte.toString(16).padStart(2, "0"))
		.join("");
}

function copyAuthority(authority: IrcBridgeAuthorityState): IrcBridgeAuthorityState {
	return { ...authority };
}

export class RoomServerOperationsState {
	readonly #directory: string | null;
	#disk: OperationsDiskState;
	#tail: Promise<void> = Promise.resolve();

	private constructor(directory: string | null, disk: OperationsDiskState) {
		this.#directory = directory;
		this.#disk = disk;
	}

	static async open(directory: string | null): Promise<RoomServerOperationsState> {
		if (directory == null) return new RoomServerOperationsState(null, fresh());
		await Deno.mkdir(directory, { recursive: true, mode: 0o700 });
		try {
			const disk = parse(
				await readBoundedText(`${directory}/${FILE}`, MAX_STATE_BYTES, "Rooms server operations state"),
			);
			return new RoomServerOperationsState(directory, disk);
		} catch (error) {
			if (!(error instanceof Deno.errors.NotFound)) {
				if (error instanceof RoomServerOperationsStateError) throw error;
				throw new RoomServerOperationsStateError(
					error instanceof Error ? error.message : String(error),
					{ cause: error },
				);
			}
			const state = new RoomServerOperationsState(directory, fresh());
			await state.#write(state.#disk);
			return state;
		}
	}

	listeners(): ListenerIntent[] {
		return this.#disk.listeners.map((intent) => ({ ...intent, options: { ...intent.options } }));
	}

	ircBridges(): IrcBridgeIntent[] {
		return this.#disk.ircBridges.map((intent) => ({ ...intent }));
	}

	ircNetworks(): IrcNetworkChoice[] {
		return this.#disk.ircNetworks.map((intent) => ({
			...intent,
			...(intent.sasl == null ? {} : { sasl: { ...intent.sasl } }),
		}));
	}

	ircBridgeAuthority(publicationId: string): IrcBridgeAuthorityState | null {
		const authority = this.#disk.ircBridgeAuthorities.find((row) => row.publicationId === publicationId);
		return authority == null ? null : copyAuthority(authority);
	}

	ircBridgeAuthorities(): IrcBridgeAuthorityState[] {
		return this.#disk.ircBridgeAuthorities.map(copyAuthority);
	}

	issueIrcBridgeSteward(publicationId: string): Promise<IrcBridgeAuthorityState> {
		let issued: IrcBridgeAuthorityState | null = null;
		return this.#mutate((current) => {
			const authority = current.ircBridgeAuthorities.find((row) => row.publicationId === publicationId);
			if (authority == null) throw new Error("that IRC bridge authority is not current");
			if (authority.issued) {
				issued = authority;
				return current;
			}
			if (authority.generation === Number.MAX_SAFE_INTEGER) {
				throw new Error("IRC bridge moderator generation is exhausted");
			}
			issued = { ...authority, issued: true, generation: authority.generation + 1 };
			return {
				...current,
				ircBridgeAuthorities: current.ircBridgeAuthorities.map((row) =>
					row.publicationId === publicationId ? issued! : row
				),
			};
		}).then(() => copyAuthority(issued!));
	}

	revokeIrcBridgeSteward(publicationId: string, stewardEntropy: string): Promise<IrcBridgeAuthorityState> {
		let revoked: IrcBridgeAuthorityState | null = null;
		return this.#mutate((current) => {
			const authority = current.ircBridgeAuthorities.find((row) => row.publicationId === publicationId);
			if (authority == null || !authority.issued || authority.stewardEntropy !== stewardEntropy) {
				throw new Error("that IRC bridge moderator capability is not current");
			}
			if (authority.generation === Number.MAX_SAFE_INTEGER) {
				throw new Error("IRC bridge moderator generation is exhausted");
			}
			revoked = {
				...authority,
				stewardEntropy: authorityEntropy(),
				generation: authority.generation + 1,
				issued: false,
			};
			return {
				...current,
				ircBridgeAuthorities: current.ircBridgeAuthorities.map((row) =>
					row.publicationId === publicationId ? revoked! : row
				),
			};
		}).then(() => copyAuthority(revoked!));
	}

	rememberIrcNetwork(intent: IrcNetworkChoice): Promise<void> {
		const key = intent.network.toLowerCase();
		return this.#mutate((current) => {
			const existing = current.ircNetworks.find((saved) => saved.network.toLowerCase() === key);
			if (existing != null) {
				if (!sameIrcNetworkChoice(existing, intent)) {
					throw new Error(`IRC network ${intent.network} already has different connection settings`);
				}
				return current;
			}
			return {
				...current,
				ircNetworks: [
					...current.ircNetworks,
					{ ...intent, ...(intent.sasl == null ? {} : { sasl: { ...intent.sasl } }) },
				],
			};
		});
	}

	forgetIrcNetwork(network: string): Promise<void> {
		const key = network.toLowerCase();
		return this.#mutate((current) => {
			const bridges = current.ircBridges.filter((saved) => saved.network.toLowerCase() !== key);
			const publications = new Set(bridges.map((bridge) => bridge.publicationId));
			return {
				...current,
				ircNetworks: current.ircNetworks.filter((saved) => saved.network.toLowerCase() !== key),
				ircBridges: bridges,
				ircBridgeAuthorities: current.ircBridgeAuthorities.filter((row) => publications.has(row.publicationId)),
			};
		});
	}

	rememberListener(intent: ListenerIntent): Promise<void> {
		return this.#mutate((current) => ({
			...current,
			listeners: [...current.listeners.filter((saved) => saved.transport !== intent.transport), intent],
		}));
	}

	forgetListener(transport: string): Promise<void> {
		return this.#mutate((current) => ({
			...current,
			listeners: current.listeners.filter((saved) => saved.transport !== transport),
		}));
	}

	rememberIrcBridge(
		intent: Pick<IrcBridgeIntent, "network" | "channel"> & { publicationId?: string },
	): Promise<string> {
		const key = `${intent.network}\u0000${intent.channel}`.toLowerCase();
		const publicationId = intent.publicationId ?? crypto.randomUUID();
		const persisted: IrcBridgeIntent = { network: intent.network, channel: intent.channel, publicationId };
		return this.#mutate((current) => {
			const prior = current.ircBridges.find((saved) =>
				`${saved.network}\u0000${saved.channel}`.toLowerCase() === key
			);
			if (prior?.publicationId === publicationId) return current;
			const authorities = prior == null
				? current.ircBridgeAuthorities
				: current.ircBridgeAuthorities.filter((row) => row.publicationId !== prior.publicationId);
			return {
				...current,
				ircBridges: [
					...current.ircBridges.filter((saved) =>
						`${saved.network}\u0000${saved.channel}`.toLowerCase() !== key
					),
					persisted,
				],
				ircBridgeAuthorities: [
					...authorities,
					{
						publicationId,
						roomEntropy: authorityEntropy(),
						stewardEntropy: authorityEntropy(),
						generation: 0,
						issued: false,
					},
				],
			};
		}).then(() => publicationId);
	}

	forgetIrcBridge(network: string, channel: string): Promise<void> {
		const key = `${network}\u0000${channel}`.toLowerCase();
		return this.#mutate((current) => {
			const bridges = current.ircBridges.filter((saved) =>
				`${saved.network}\u0000${saved.channel}`.toLowerCase() !== key
			);
			const publications = new Set(bridges.map((bridge) => bridge.publicationId));
			return {
				...current,
				ircBridges: bridges,
				ircBridgeAuthorities: current.ircBridgeAuthorities.filter((row) => publications.has(row.publicationId)),
			};
		});
	}

	#mutate(change: (current: OperationsDiskState) => OperationsDiskState): Promise<void> {
		const run = this.#tail.then(async () => {
			const next = change(this.#disk);
			if (next === this.#disk) return;
			const parsed = z.safeParse(OperationsDiskStateSchema, next);
			if (!parsed.success) {
				throw new Error(`Rooms server operations change is invalid:\n${z.prettifyError(parsed.error)}`);
			}
			if (JSON.stringify(parsed.data) === JSON.stringify(this.#disk)) return;
			await this.#write(parsed.data);
			this.#disk = parsed.data;
		});
		this.#tail = run.then(() => {}, () => {});
		return run;
	}

	async #write(disk: OperationsDiskState): Promise<void> {
		if (this.#directory == null) return;
		const bytes = new TextEncoder().encode(JSON.stringify(disk) + "\n");
		if (bytes.length > MAX_STATE_BYTES) throw new Error("Rooms server operations state is too large");
		await atomicWrite(`${this.#directory}/${FILE}`, bytes);
	}
}
