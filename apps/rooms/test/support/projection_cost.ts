// Count visits through the real projection; setup and teardown are unmeasured.
import { fixture, room } from "../session/managed_projection/fixture.ts";
import * as store from "../../web/ui/store.ts";
import type { Conv } from "../../web/ui/types.ts";

export function projectionCost(conversations: number, displayedLines: number) {
	let conversationVisits = 0;
	let lineIdReads = 0;
	const f = fixture();
	try {
		const rows = Array.from({ length: conversations }, (_, index) => ({
			...room(),
			id: `conversation-${index}`,
			name: `room-${index}`,
			lines: Array.from({ length: displayedLines / 2 }, (_, at) => ({
				get id() {
					lineIdReads++;
					return 2 * at + 1;
				},
				handle: `line-${index}-${at}`,
			})),
		}));
		f.current.intent.conversations = rows;
		f.current.intent.active = rows[0].id;
		f.apply();
		for (const row of rows) {
			const conversation = store.convByPersistId(f.page.projection, row.id)!;
			for (let at = 0; at < displayedLines; at++) {
				store.deliver(f.page.projection, conversation.key, {
					...store.chatItem(f.page.projection, "peer", "retained line", false),
					lineId: at + 1,
					held: at % 2 === 0,
				});
			}
		}
		const countValues = (convs: ReadonlyMap<string, Conv>) => {
			const values = convs.values.bind(convs);
			convs.values = () => {
				const iterator = values();
				const counted = new Proxy(iterator, {
					get(target, property) {
						if (property === Symbol.iterator) return () => counted;
						if (property === "next") {
							return () => {
								const result = target.next();
								if (!result.done) conversationVisits++;
								return result;
							};
						}
						const value = Reflect.get(target, property);
						return typeof value === "function" ? value.bind(target) : value;
					},
				});
				return counted;
			};
		};
		const set = f.page.projection.set.bind(f.page.projection);
		f.page.projection.set = (patch) => {
			if (patch.convs) countValues(patch.convs);
			set(patch);
		};
		f.page.projection.set({ convs: new Map(f.page.projection.get().convs) });
		conversationVisits = 0;
		lineIdReads = 0;
		f.apply();
		const visits = conversationVisits;
		for (const row of rows) {
			const conversation = store.convByPersistId(f.page.projection, row.id)!;
			const history = store.historyOf(f.page.projection, conversation.key);
			if (history.some((item, at) => item.kind !== "chat" || item.held !== (at % 2 === 0))) {
				throw new Error("projection changed exact displayed line custody");
			}
		}
		return { conversations, displayedLines, conversationVisits: visits, lineIdReads };
	} finally {
		f.close();
	}
}
