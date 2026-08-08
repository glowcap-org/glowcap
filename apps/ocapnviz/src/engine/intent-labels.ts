/**
 * Undo / redo tooltip labels for every `BuilderIntent`. Extracted
 * from `engine.ts` because the mapping is presentation, not engine
 * mechanics — it grows whenever the UI wants a more specific verb
 * ("Rename peer" vs "Edit peer") without touching engine semantics.
 *
 * Pure function over the intent payload. Tests live alongside.
 */

import type { BuilderIntent } from "./engine.ts";
import { PEER_TRAJECTORY, SESSION_TRAJECTORY } from "./trajectory.ts";

/** Forward-direction label for an intent — drives the "Undo X" /
 * "Redo X" tooltips. `update-peer` narrows by patch shape so the
 * label reflects the actual edit ("Rename peer" etc.).
 *
 * Every label in this table is an imperative verb followed by what it acts
 * on, in sentence case, so the menu reads as one list of commands: "Set
 * session start", "Clear session start". A label that named the resulting
 * STATE instead of the act ("Make peer eternal" for clearing a start) broke
 * that on both counts, and taught a word the app uses nowhere else. */
export function intentLabel(intent: BuilderIntent): string {
  switch (intent.kind) {
    case "add-peer":
      return "Add peer";
    case "clear-peer-position":
      return "Unpin peer";
    case "reposition-peer":
      return "Move peer";
    case "clear-endpoint-position":
      return "Unpin session end";
    case "reposition-endpoint":
      return "Move session end";
    case "update-peer": {
      const fields = Object.keys(intent.patch);
      if (fields.length === 1 && fields[0] === "label") return "Rename peer";
      if (fields.length === 1 && fields[0] === "profile") {
        return "Change profile";
      }
      if (fields.length === 1 && fields[0] === "designator") {
        return "Edit designator";
      }
      return "Edit peer";
    }
    case "open-session":
      return "Open session";
    case "send-message":
      return "Send message";
    case "delete-peer":
      return "Delete peer";
    case "delete-session":
      return "Delete session";
    case "delete-message":
      return "Delete message";
    case "update-session": {
      const fields = Object.keys(intent.patch);
      if (fields.length === 1 && fields[0] === "codec") return "Change codec";
      if (fields.length === 1 && fields[0] === "captpVersion") {
        return "Change CapTP version";
      }
      if (fields.length === 1 && fields[0] === "state") {
        return "Change session state";
      }
      if (fields.length === 1 && fields[0] === "transport") {
        return "Change transport";
      }
      return "Edit session";
    }
    case "update-message":
      return "Edit message";
    case "move-entity-span":
      return intent.move.kind === "translate" ? "Move span" : "Resize span";
    case "move-event":
      return intent.move.kind === "resize-end"
        ? "Adjust flight time"
        : "Move event";
    case "set-peer-end":
      return "Set peer end";
    case "set-peer-duration":
      return "Set peer duration";
    case "clear-peer-end":
      return "Clear peer end";
    case "set-peer-start":
      return "Set peer start";
    case "clear-peer-start":
      return "Clear peer start";
    case "set-session-start":
      return "Set session start";
    case "clear-session-start":
      return "Clear session start";
    case "set-message-start":
      return "Set message start";
    case "clear-message-start":
      return "Clear message start";
    case "set-message-end":
      return "Set message arrival";
    case "set-message-duration":
      return "Set message flight";
    case "set-session-end":
      return "Set session end";
    case "set-session-duration":
      return "Set session duration";
    case "clear-session-end":
      return "Clear session end";
    case "set-session-keyframe":
      return `Change session ${SESSION_TRAJECTORY[intent.property].noun}`;
    case "remove-session-keyframe":
      return `Remove session ${
        SESSION_TRAJECTORY[intent.property].noun
      } change`;
    case "set-session-initial-state":
      return "Change initial session state";
    case "update-session-endpoint": {
      // Attaching and detaching are the edits a reader recognizes by
      // name, so they get their own verbs; the rest are one edit of
      // the end.
      const p = intent.patch;
      if (p.peer === null) return "Detach session end";
      if (p.peer !== undefined) return "Attach session end";
      const fields = Object.keys(p);
      if (fields.length === 1 && fields[0] === "designator") {
        return "Edit end claim";
      }
      if (fields.length === 1 && fields[0] === "attributedBy") {
        return "Change end attribution";
      }
      return "Edit session end";
    }
    case "set-peer-update":
      return `Change peer ${PEER_TRAJECTORY[intent.property].noun}`;
    case "remove-peer-update":
      return `Remove peer ${PEER_TRAJECTORY[intent.property].noun} change`;
    case "reorder-row":
      return "Reorder timeline rows";
    case "set-row-vis-mode":
      switch (intent.mode) {
        case "visible":
          return "Show row";
        case "label":
          return "Hide label";
        case "body":
          return "Hide body";
        case "both":
          return "Hide row";
      }
      return "Set row visibility";
    case "set-category-vis-mode":
      switch (intent.mode) {
        case "visible":
          return `Show all ${intent.category}`;
        case "label":
          return `Hide all ${intent.category} labels`;
        case "body":
          return `Hide all ${intent.category} bodies`;
        case "both":
          return `Hide all ${intent.category}`;
      }
      return `Set all ${intent.category} visibility`;
    case "set-all-vis-mode":
      switch (intent.mode) {
        case "visible":
          return "Show all rows";
        case "label":
          return "Hide all labels";
        case "body":
          return "Hide all bodies";
        case "both":
          return "Hide all rows";
      }
      return "Set all rows visibility";
    case "rename-peer":
      return "Rename peer";
    case "rename-session":
      return "Rename session";
    case "rename-message":
      return "Rename message";
  }
}
