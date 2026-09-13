---
description: "Committed helper scripts need one caller, one owner, a stable interface, and verification at the boundary they serve."
globs: **/*.sh, **/ops, glowcap, .agents/hooks/*, .agents/skills/**/bin/*, apps/**/scripts/**, tools/**/*.py, .devcontainer/**/*.py
---

# glowcap — Script Standard

A committed script is a small program, not disposable glue. It earns a file
when its behavior will be run again and an existing product command, build
helper, or library is not the clearer owner.

Standardizing a useful helper and deciding whether its behavior belongs are
separate decisions. A request for consistency is not a reason to delete the
helper. First judge the behavior, then either give it the contract below or
remove it because the behavior itself no longer earns a place.

## Before adding a file

Name the repeated effect and its caller. If the command is only useful for the
current investigation, run it from the shell or keep it outside the repository.
If it belongs, check for an existing command or script that should own one more
verb before creating another entry point.

[ADR-0150](../../docs/decisions/adr/ADR-0150-operations-fronts-and-script-placement.md)
owns placement:

- Contributor commands are `zig build` steps. A script may implement a step
  when it owns process supervision, shell integration, or another boundary the
  build graph cannot express clearly.
- A shipped deployable has one operator-facing front beside that deployable.
- Check and generator bodies live under `tools/check` and `tools/gen`.
- Container and agent workflow scripts stay with `.devcontainer/` and
  `.agents/`. Machine-specific facts stay in ignored `.local/` tooling.

Do not add a second public command merely to expose an internal script. The
public front is the build step, operations front, hook, or skill that owns it.

## Contract

Every committed script names or demonstrates:

- its caller and the effect it owns;
- its arguments, environment inputs, output, and failure status;
- whether it resolves paths from its own location or receives a working
  directory from its caller;
- the runtime already owned by the environment where it runs;
- cleanup, signal, retry, and destructive behavior that the effect requires;
- the focused test or check that proves its ordinary and failure paths.

Use POSIX `sh` only when the target host needs that portability. Use Bash when
arrays, process groups, or Bash-specific facilities make the implementation
clearer. Use Python or TypeScript when structured data or domain logic has
outgrown shell, and route the interpreter through the pinned toolchain. Do not
add a dependency for convenience that the target environment does not own.

Quote paths and values, reject malformed arguments before effects, and avoid
ambient working-directory assumptions. When a caller deliberately owns the
working directory, make that visible at the call site and exercise it in the
test. A script callable from outside the repository root needs a non-root-cwd
test.

## Maintenance

Change the caller, script, focused evidence, runtime inventory, and public
documentation together. Document the public command, not a script body users
should never invoke directly. An internal script's header names its public
caller so a future reader can find the owning interface.

Remove a script when its caller disappears, its effect moves into a better
owner, or the behavior no longer pays for its maintenance. Do not leave an
orphan, a compatibility wrapper, or two scripts that each own half of one
effect.
