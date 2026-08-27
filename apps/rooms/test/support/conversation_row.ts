import type { Locator, Page } from "playwright";

function exactText(text: string): RegExp {
	return new RegExp(`^${text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}$`);
}

function namedRow(
	page: Page,
	list: "roomList" | "dmList",
	name: string,
	selected: boolean,
	className?: string,
): Locator {
	const row = page.locator(`#${list} li${selected ? ".here" : ""}${className == null ? "" : `.${className}`}`);
	const named = page.locator(list === "roomList" ? ".rname-text" : ".rname").filter({ hasText: exactText(name) });
	return row.filter({ has: named });
}

export function namedRoomRow(page: Page, name: string, selected = false, className?: string): Locator {
	return namedRow(page, "roomList", name, selected, className);
}

export function namedDirectRow(page: Page, name: string, selected = false): Locator {
	return namedRow(page, "dmList", name, selected);
}
