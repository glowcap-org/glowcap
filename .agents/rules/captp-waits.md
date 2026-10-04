---
description: "Product CapTP waits: every dial and settle in cli/, examples, and CLI tests names a finite budget."
globs: cli/**/*.zig, examples/zig/**, test/cli/**
paths:
  - "cli/**/*.zig"
  - "examples/zig/**"
  - "test/cli/**"
---

# glowcap — Product CapTP Waits

`SessionOptions.handshake` and `.settle` are `driver.Budget` with no default.
`.unbounded` compiles and is correct only for an in-process pair; anywhere a
partner can go silent it parks the process. A `.ms` of zero or less has already
expired.

- Product paths use `cli/ocapn.sessionOpts()`. Tests that dial name a finite
  budget too. `source-check` refuses `.unbounded` under `cli/` and
  `examples/zig/**`, where a reader would copy it.
- The buffer-explicit constructors take the handshake budget positionally, and
  their last argument must be bounded.
- Map `HandshakeTimedOut` / `WaitTimedOut` to exit code `timeout`.
  `test/cli/session_cases.zig` pins the silent-partner timeout.
- Hermetic goldens run under `zig build cli-test`. Do not write a parallel Zig
  dialer outside `cli/` and `test/cli/`.
