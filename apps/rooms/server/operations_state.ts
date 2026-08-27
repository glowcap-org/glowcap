// Durable intent for operator-managed listeners and IRC bridges. This document
// may contain a shared IRC feed credential, so it stays under the server's
// mode-0700 state directory and never enters snapshots or diagnostics.

import * as z from "zod/mini";
import { IrcJoinChoiceSchema } from "../lib/irc_gateway_client.ts";
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

const OperationsDiskStateShapeSchema = z.strictObject({
	version: z.literal(VERSION),
	listeners: z.array(ListenerIntentSchema).check(z.maxLength(MAX_LISTENERS)),
	ircBridges: z.array(IrcJoinChoiceSchema).check(z.maxLength(MAX_OPERATIONS_ROWS)),
});

type OperationsDiskStateShape = z.infer<typeof OperationsDiskStateShapeSchema>;

function validRelations(state: OperationsDiskStateShape): boolean {
	const transports = new Set<string>();
	for (const listener of state.listeners) {
		if (transports.has(listener.transport) || !listenerOptionsFitTransport(listener.transport, listener.options)) {
			return false;
		}
		transports.add(listener.transport);
	}
	const channels = new Set<string>();
	for (const bridge of state.ircBridges) {
		const key = `${bridge.network}\u0000${bridge.channel}`.toLowerCase();
		if (channels.has(key)) return false;
		channels.add(key);
	}
	return true;
}

export const OperationsDiskStateSchema = OperationsDiskStateShapeSchema.check(
	z.refine(validRelations, "listener transports and IRC channels must be unique"),
);

export type ListenerIntent = z.infer<typeof ListenerIntentSchema>;
export type IrcBridgeIntent = z.infer<typeof IrcJoinChoiceSchema>;
type OperationsDiskState = z.infer<typeof OperationsDiskStateSchema>;

function fresh(): OperationsDiskState {
	return { version: VERSION, listeners: [], ircBridges: [] };
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
		return this.#disk.ircBridges.map((intent) => ({
			...intent,
			...(intent.sasl == null ? {} : { sasl: { ...intent.sasl } }),
		}));
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

	rememberIrcBridge(intent: IrcBridgeIntent): Promise<void> {
		const key = `${intent.network}\u0000${intent.channel}`.toLowerCase();
		return this.#mutate((current) => ({
			...current,
			ircBridges: [
				...current.ircBridges.filter((saved) => `${saved.network}\u0000${saved.channel}`.toLowerCase() !== key),
				intent,
			],
		}));
	}

	forgetIrcBridge(network: string, channel: string): Promise<void> {
		const key = `${network}\u0000${channel}`.toLowerCase();
		return this.#mutate((current) => ({
			...current,
			ircBridges: current.ircBridges.filter((saved) =>
				`${saved.network}\u0000${saved.channel}`.toLowerCase() !== key
			),
		}));
	}

	#mutate(change: (current: OperationsDiskState) => OperationsDiskState): Promise<void> {
		const run = this.#tail.then(async () => {
			const next = change(this.#disk);
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
