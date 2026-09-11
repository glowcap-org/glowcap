// The mark as a lit 3D scene: the shaders, assembled.
//
// The flat mark's shapes drawn with a graphics device behind them looked like
// the flat mark with a glow on it. If the mark is going to cost a device, the
// device has to buy something the drawing cannot have, and that is a real
// object with a real light inside it. So this is a mushroom in three
// dimensions, sphere-traced, drawn the way the flat mark is drawn: two flat
// tones and an amber line, with windows in the cap that are dark before the
// light and lamps after it. The light is what the device is for. Its beams
// are cones of lit mist that a view ray marches through, its spill falls from
// under the brim onto the floor, dust drifts up through it, and the whole
// thing blooms in a second pass.
//
// The scene shader is three files concatenated: the field (where the
// mushroom is), the light (what a lamp puts into the air), and the scene (one
// pixel of one frame). WGSL resolves module-scope names in any order, so the
// order here is for reading.

import { FIELD } from "./mark_gpu_field.ts";
import { LIGHT } from "./mark_gpu_light.ts";
import { SCENE } from "./mark_gpu_scene.ts";

export { BLUR, COMPOSITE } from "./mark_gpu_post.ts";

/** The scene pass: one module, both stages. */
export const SHADER = FIELD + LIGHT + SCENE;
