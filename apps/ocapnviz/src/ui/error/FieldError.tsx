import type { EngineError } from "../../engine/errors.ts";
import { c, FONT, SIZE, SPACE } from "../tokens.ts";

/**
 * Inline field-bound error. The caller decides when to show it —
 * typically by running `engine.validate(intent)` synchronously on the
 * next-pending edit (Inspector ID blur, options-bar typing) and
 * passing the returned error in. Pure presentation; no bus
 * subscription.
 */
export function FieldError({ error }: { error: EngineError | null }) {
  if (!error) return null;
  return (
    <div
      role="alert"
      style={{
        marginTop: SPACE.xs,
        fontFamily: FONT.sans,
        fontSize: SIZE.xs,
        color: c.danger,
      }}
    >
      <span style={{ fontWeight: 600 }}>{error.detail}</span>
      <span style={{ color: c.textMuted, marginLeft: SPACE.xs }}>
        {error.recovery}
      </span>
    </div>
  );
}
