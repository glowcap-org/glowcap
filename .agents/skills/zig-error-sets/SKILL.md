---
name: zig-error-sets
description: >-
  Use when narrowing `anyerror` returns, writing or naming a Zig error set,
  breaking an inferred-error-set dependency loop, or reading an error-set
  compile error on this toolchain. Not for ordinary Zig edits that touch no
  error-set types.
---

# Zig error sets on this toolchain

## What compiles

- Narrowing works by **inference** (`!T`). An inferred error set coerces only
  to `anyerror`. A narrower set cannot receive it at a parameter or a declared
  return.
- `@TypeOf` resolves an inferred set to `anyerror` outside the call graph. A
  file-scope `@typeInfo` probe sees `anyerror`, not the members.
- A **declared** set on a function whose callees have inferred sets fails to
  compile, because the callee's set cannot be checked against it.
- **Mutually recursive** functions cannot both carry inferred sets ("dependency
  loop with length N"). Break the cycle with `anyerror` on one side and name
  the loop on site. Self-recursion with inference is fine.
- A caller's `switch` **prong** naming an error the callee's per-instantiation
  set cannot produce fails to compile after narrowing. Map by error-value
  comparison (`err == error.X`) instead of a prong.

## What is worth writing

- Default to `!T` inference. Write a set out by name (`pub const Error =
  error{...}`) only when a caller switches on it, so the named set stays owned
  by a switcher.
- A type-erased callback slot (`*const fn (*anyopaque, ...) anyerror!...`)
  keeps `anyerror`: its implementors are unknown at the declaration. Leave one
  comment on the vtable type, not one per slot. Implementations inherit the
  slot's set.
- A survivor that keeps `anyerror` names its reason where it lives: the
  dependency loop, the handler boundary, or the anyerror-typed callee it
  projects through.

## Enumerating a resolved set

Inside a function that is analyzed and calls the target, a comptime probe
prints the callee's resolved members:

```zig
comptime {
    const s = @typeInfo(@typeInfo(@TypeOf(callee)).@"fn".return_type.?)
        .@"error_union".error_set;
    for (@typeInfo(s).@"error_set".error_names.?) |name| @compileLog(name);
}
```

Remove the probe before committing: `@compileLog` fails the build.

## Procedure

Survey `) anyerror!` in return positions. Classify each site: vtable slot
(keep, comment the vtable type), concrete function (narrow by inference),
mutual-recursion family or boundary (keep, name the reason on site). A
narrowed signature compiles every layer that implements it, so run the bare
test suite once before the final gate. Expect consumer fixes in other layers
where a per-instantiation set exposed a dead prong.
