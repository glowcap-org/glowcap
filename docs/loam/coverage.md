---
type: static
description: A table of each managed access surface, the decision that owns its contract, and the tests that prove it.
audience: human
sources:
  - resource: /src/loam/access/
  - resource: /test/loam/
---

# Managed access coverage

Each row names a managed access feature, the design record that explains it,
and its tests. Managed access is Loam's layer for resources, grants, and the
references that use and control them, exposed in Zig as `glowcap.loam.access`.
Tests that need no storage engine live in [`test/loam/access/`](../../test/loam/access/).
Rows marked "engine" are shared [engine scenarios](../../test/loam/engines/) that run on both disk engines,
with engine-specific tests under [`test/loam/sqlite/`](../../test/loam/sqlite/)
and [`test/loam/lmdb/`](../../test/loam/lmdb/).

| Part | Design record | Tests |
| --- | --- | --- |
| Resource graph | [ADR-0046](../decisions/adr/ADR-0046-resource-scopes-and-permissions.md) | [`graph_test.zig`](../../test/loam/access/graph_test.zig), [`scope_test.zig`](../../test/loam/access/scope_test.zig) |
| Grant ledger and prepared writes | [ADR-0046](../decisions/adr/ADR-0046-resource-scopes-and-permissions.md), [ADR-0047](../decisions/adr/ADR-0047-prepared-grant-mutations.md), [ADR-0046](../decisions/adr/ADR-0046-resource-scopes-and-permissions.md), [ADR-0046](../decisions/adr/ADR-0046-resource-scopes-and-permissions.md) | [`grants_test.zig`](../../test/loam/access/grants_test.zig), [`grant_transaction_test.zig`](../../test/loam/access/grant_transaction_test.zig), [`applicability_test.zig`](../../test/loam/access/applicability_test.zig) |
| Use and control references | [ADR-0046](../decisions/adr/ADR-0046-resource-scopes-and-permissions.md) | [`grant_capability_test.zig`](../../test/loam/access/grant_capability_test.zig) |
| Record views and plans | [ADR-0046](../decisions/adr/ADR-0046-resource-scopes-and-permissions.md), [ADR-0047](../decisions/adr/ADR-0047-prepared-grant-mutations.md) | [`resource_view_test.zig`](../../test/loam/access/resource_view_test.zig), [`grant_view_test.zig`](../../test/loam/access/grant_view_test.zig), [`grant_record_test.zig`](../../test/loam/access/grant_record_test.zig) |
| Owner storage and history | [ADR-0052](../decisions/adr/ADR-0052-managed-owner-lifecycle.md), [storage guide](access-storage.md) | [`owner_test.zig`](../../test/loam/access/owner_test.zig), [`change_history_test.zig`](../../test/loam/access/change_history_test.zig), engine [`history_test.zig`](../../test/loam/engines/history_test.zig) |
| Durable references | [ADR-0052](../decisions/adr/ADR-0052-managed-owner-lifecycle.md) | [`stored_capability_test.zig`](../../test/loam/access/stored_capability_test.zig), engine [`capability_test.zig`](../../test/loam/engines/capability_test.zig) |
| Hosted endpoints and receipts | [ADR-0052](../decisions/adr/ADR-0052-managed-owner-lifecycle.md), [ADR-0052](../decisions/adr/ADR-0052-managed-owner-lifecycle.md) | [`hosting_test.zig`](../../test/loam/access/hosting_test.zig), [`registration_test.zig`](../../test/loam/access/registration_test.zig), [`continuation_hosted_test.zig`](../../test/loam/access/continuation_hosted_test.zig), engine [`managed_hosting_test.zig`](../../test/loam/engines/managed_hosting_test.zig) |
| Derivation | [ADR-0052](../decisions/adr/ADR-0052-managed-owner-lifecycle.md) | [`sharing_test.zig`](../../test/loam/access/sharing_test.zig), engine [`sharing_test.zig`](../../test/loam/engines/sharing_test.zig) |
| Returned capabilities and reference fields | [ADR-0053](../decisions/adr/ADR-0053-returned-capability-authority.md), [ADR-0053](../decisions/adr/ADR-0053-returned-capability-authority.md), [references guide](references.md) | [`reference_test.zig`](../../test/loam/access/reference_test.zig), LMDB [`reference_test.zig`](../../test/loam/lmdb/reference_test.zig), [`loam_references_crash.zig`](../../test/loam_references_crash.zig) |
| Registered content graphs | [C and Rust guide](c-and-rust.md#registered-content-graphs) | [`content_graph_test.zig`](../../test/loam/access/content_graph_test.zig), [`content_graph_hosted_test.zig`](../../test/loam/access/content_graph_hosted_test.zig), engine [`content_graph_test.zig`](../../test/loam/engines/content_graph_test.zig) |
| Lifecycle and management | [ADR-0052](../decisions/adr/ADR-0052-managed-owner-lifecycle.md) | [`resource_lifecycle_test.zig`](../../test/loam/access/resource_lifecycle_test.zig), [`management_test.zig`](../../test/loam/access/management_test.zig), engine [`management_test.zig`](../../test/loam/engines/management_test.zig) |
| Calls that change several resources | [ADR-0046](../decisions/adr/ADR-0046-resource-scopes-and-permissions.md) | [`tree_hosted_test.zig`](../../test/loam/access/tree_hosted_test.zig), engine [`tree_crash_test.zig`](../../test/loam/engines/tree_crash_test.zig) |
| Describing access | [ADR-0046](../decisions/adr/ADR-0046-resource-scopes-and-permissions.md) | [`description_test.zig`](../../test/loam/access/description_test.zig) |
| Observing access | [observation guide](access-observation.md) | [`observation_test.zig`](../../test/loam/access/observation_test.zig), [`observation_hosted_test.zig`](../../test/loam/access/observation_hosted_test.zig), engine [`observation_test.zig`](../../test/loam/engines/observation_test.zig) |
| Owner cleanup | [managed access guide](access.md#bounded-owner-cleanup) | [`maintenance_test.zig`](../../test/loam/access/maintenance_test.zig), engine [`maintenance_test.zig`](../../test/loam/engines/maintenance_test.zig), LMDB [`maintenance_test.zig`](../../test/loam/lmdb/maintenance_test.zig) |
| Process loss | [Stability](../stability.md) | [`loam_managed_crash.zig`](../../test/loam_managed_crash.zig) |

The [C and Rust guide](c-and-rust.md#tests) lists the tests for C, Rust, and
the browser.
