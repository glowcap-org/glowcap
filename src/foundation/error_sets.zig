//! Naming an exact error set where Zig cannot infer one: a recursive walk, or
//! a function-pointer type declared before its implementation. Spelling either
//! as `anyerror` hides every error from the callers' `switch` and from the
//! classifiers above. `Of` names a non-recursive callee's inferred set, so the
//! spelled set is the union of what the function calls and nothing wider.

/// The error set `function` returns. `function` must be non-generic and
/// return an error union.
pub fn Of(comptime function: anytype) type {
    const R = @typeInfo(@TypeOf(function)).@"fn".return_type.?;
    return @typeInfo(R).error_union.error_set;
}
