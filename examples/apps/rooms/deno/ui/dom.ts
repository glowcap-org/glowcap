// ── Typed element handles ──────────────────────────────────────────────────
// Every control the script drives, resolved once. el() asserts the element exists
// — the markup in page.html is fixed, so a missing id is a bug, not a runtime
// branch — and narrows to the concrete element type each call site needs.
export function el<T extends HTMLElement = HTMLElement>(id: string): T {
	return document.getElementById(id) as T;
}
export const log = el("log");
export const joinScreen = el("joinScreen");
export const joinForm = el<HTMLFormElement>("joinForm");
export const roomInput = el<HTMLInputElement>("room");
export const nickInput = el<HTMLInputElement>("nick");
export const nickError = el("nickError");
export const joinBtn = el<HTMLButtonElement>("joinBtn");
export const statusEl = el("status");
export const dot = el("dot");
export const banner = el("banner");
export const composer = el<HTMLFormElement>("composer");
export const lineInput = el<HTMLTextAreaElement>("line");
export const sendBtn = el<HTMLButtonElement>("sendBtn");
export const roomListEl = el("roomList");
export const dmListEl = el("dmList");
export const presenceSummary = el("presenceSummary");
export const membersEl = el("members");
export const roomName = el("roomName");
export const roomSigil = el("roomSigil");
export const roomMeta = el("roomMeta");
export const provenance = el("provenance");
export const provenanceText = el("provenanceText");
export const membersToggle = el<HTMLButtonElement>("membersToggle");
export const themeToggle = el<HTMLButtonElement>("themeToggle");
export const notifyToggle = el<HTMLButtonElement>("notifyToggle");
export const content = el("content");
export const jumpBtn = el<HTMLButtonElement>("jump");
export const newRoomBtn = el<HTMLButtonElement>("newRoomBtn");
export const newRoom = el("newRoom");
export const newRoomInput = el<HTMLInputElement>("newRoomInput");
export const newDmBtn = el<HTMLButtonElement>("newDmBtn");
export const newDm = el("newDm");
export const newDmInput = el<HTMLInputElement>("newDmInput");
export const emojiBtn = el<HTMLButtonElement>("emojiBtn");
export const emojiPop = el("emojiPop");
export const app = document.querySelector(".app") as HTMLElement;
export const backBtn = el<HTMLButtonElement>("backBtn");
export const sheetScrim = el("sheetScrim");
// The mobile layout is a list-then-conversation stack; these gate the phone-only
// navigation (back button, roster sheet) without affecting the desktop split.
export const mobileMQ = matchMedia("(max-width: 820px)");
export const isMobile = () => mobileMQ.matches;
