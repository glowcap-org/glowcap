# Interface authoring comparison

`comparison.syrup` is the direct input and independent expected description.
It was constructed with the pinned upstream Python Syrup encoder from explicit
records and dictionaries, without either comparison adapter. The proposed text
in `comparison.interface` must reproduce those bytes before shared validation.
The Cap'n Proto adapter uses the same expected description.

| Case | Retained mapping and evidence |
| --- | --- |
| Bounds | Name counts UTF-8 bytes from 1 to 64. Count is integer 0 through 16. Both reach the checked model. Factory.add also reaches the existing bounded creation emitter |
| Selectors | Direct has no selector. Named preserves the empty symbol, `then`, and `a-b` |
| Presence | Required undefined and optional undefined remain different parameter descriptions. The text runtime proof sends zero arguments and one void argument |
| Null | Null input and result survive description checking. Existing call targets refuse both with `UnsupportedTarget` |
| Pending references | Factory accepts Reader and promise of Reader. Prepared retains the existing receipt shape with promise of value |
| Unknown breaks | Ordinary calls leave remote breaks open. The runtime proof preserves an unlisted reason. The method description has no declared-break metadata |

The text adapter accepts module declarations, aliases, interfaces, primitive
comparison types, bounded primitives, named references, promise arguments,
trailing optional parameters, direct calls, exact quoted names, `tell`, and
`@loam.receipt`. It uses the proposed syntax from the
[language reference](../../../docs/research/interface-language-example.md).
Imports, copied records, unions, and `throws` are outside this comparison.
They are refused rather than discarded. These adapters do not select a
production authoring frontend.

## Reproduce

Run commands through `.agents/skills/work/bin/glowcap-dev` from the repository
root. The interface test step builds the comparison checker. It reads build inputs only.

```sh
zig build interface-test
zig-out/bin/interface-authoring text test/interface/authoring/comparison.interface
zig-out/bin/interface-authoring syrup test/interface/authoring/comparison.syrup
zig-out/bin/interface-authoring text test/interface/authoring/comparison.interface description comparison.Reader read unused zig-out/comparison.syrup
cmp test/interface/authoring/comparison.syrup zig-out/comparison.syrup
zig-out/bin/interface-authoring syrup test/interface/authoring/comparison.syrup rust comparison.Reader read authoring_read zig-out/authoring_read.rs
zig build gen-interface-fixtures-check interface-conversation-check
```

After input format and path, emission takes target, receiver, selector, generated
function name, and output path. Use `--direct` for an absent selector and `''`
for the empty symbol. Targets are `description`, `rust`, `ts`, and the existing
`zig` creation projection. Every path reads the canonical description and calls
`Model.init` before emission. The text path does so before returning its bytes.

`interface-test` compares exact independent descriptions and checked selections.
It changes the Name bound to 32, Reader.read's reply to undefined, and the `a-b`
wire name to `renamed`, then checks the affected existing emitters. It refuses
invalid bounds, unresolved names, nontrailing optional parameters, duplicates,
and unsupported syntax. Syntax diagnostics include a byte offset, line, and
column. Shared model refusals identify the validation boundary, without a
field-specific source location.

The TypeScript runtime proof starts from proposed text through the same emitter
as direct Syrup. Both session profiles check presence, immediate sending, a
passable pending input before settlement, and an unknown remote break.
The shared runtime corpus remains the evidence for the other emitter paths.
A description match alone does not establish runtime support for a type.

The adapter has no new production dependency. An arena owns decoded tokens and
encoded fragments for one compilation, and the caller owns the final canonical
byte copy. The shared reader's input, node, and depth limits also bound this
adapter. Handwritten parser, checker, tests, and generated output are counted
separately when comparing authoring cost. The measured generation report is
unchanged by this comparison.
