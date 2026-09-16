# Editing access grants

Status: active plan. This is the interaction specification for the
[Rooms access-grants plan](access-grants.md), with the same scope and
implementation sequence. The [roadmap](../../roadmap.md#durable-applications) owns
its priority. These controls are proposed behavior, not a shipped inventory.

## A common editing model

The [resource model](resource-model.md) defines the sharing choice:
share existing access, or create managed access. Direct sharing passes the
exact held capability and creates no new grant to edit. Sharing an owner
reference includes its owner powers; sharing an existing facet retains that
facet's limits and shared revocation boundary. The UI describes which
authority is being copied rather than promising recipient-specific control.

Creating managed access opens the common grant editor. The new facet may
initially have equal or narrower permissions, subject to the issuer's authority.
Its scope, policy, and lifecycle are separate from source identity and
durability. Show its source and supported lifetime alongside the controls.
Both original access and managed facets can be durable where their owner
supports restoration; revocable does not mean temporary.

The editor separates what access permits from whether it is active. This is
the same interaction contract for shareable resources and scoped content.

| Term | Meaning in the editor |
| --- | --- |
| Grant | The issued access being managed, including its policy, lifetime, and status. Its use facet is the capability a recipient holds. |
| Scope | Which resource or bounded content the grant covers. A preset does not silently change it. |
| Permission | One meaningful allowed action, such as reading history or posting messages. Protocol descriptions may call these rights. |
| Policy | The configured permissions and typed constraints for this grant. Labels are descriptive metadata, not permissions. |
| Preset | A named, described combination of policy values, such as Observer or Collaborator. Applying it edits a defined part of the policy. |
| Permission group | A related area of the editor with a declared set of fields. It may offer presets and individual controls. |
| Status | Active, paused, or revoked. Status controls whether configured permissions can currently be exercised. |

Reserve “grant” for the issued access as a whole. Calling every permission a
grant would confuse removing one permission with revoking the shared access.
Use “Access” and action labels in ordinary UI copy; users need not learn the
word facet to edit one.

A preset selector can use radio buttons because the user chooses one
combination at a time. The underlying permissions need not be mutually
exclusive: Observer and Collaborator can both include live observation.
Independent permissions use checkboxes. A real mutually exclusive policy
choice uses a typed alternative; a future history range, for example, could
choose a start boundary instead of exposing contradictory Boolean flags.
Permission sets can use bit masks internally, but a mask alone does not express
limits, resource scope, or relationships between fields.

Each preset defines both the fields it controls and their complete values.
Applying it replaces those fields, clearing permissions absent from the chosen
combination, and leaves other fields unchanged. For Boolean permissions, this
is replacement within a mask, not accumulation of every preset ever selected.
Preset groups that are independently editable own disjoint fields. Visual
sections may organize related controls without introducing another policy owner.

For example, a session's Participation group can select Observer or
Collaborator while History remains an independent checkbox. Selecting Observer
removes the group's interaction permission and preserves History. Editing an
individual permission inside the group shows Custom when the resulting values
match no preset. A History change does not make Participation custom because
History is outside that group's scope. Every preset has a name, description,
and inspectable expansion; the editor makes its scope clear before applying it.

Every preset chooser includes an explicit Custom action that opens the
individual permission controls with the current values intact. The user can
enter customization even when those values exactly match a named preset.
Editor mode and preset matching are separate: an exact match can be shown as
“Matches Observer” without closing the customizer or switching its mode.
Selecting a named preset applies its values; simply opening or closing the
customizer changes no authority. A viewer's editing limits remain visible in
custom mode, and read-only inspection confers no management power.

The application resource policy defines available permissions, group membership,
preset values, descriptions, and validation constraints. Generated metadata
lets each client present the same choices. The first implementation includes
resource-defined presets; it does not require an editor for authoring shared
presets or a centrally managed role hierarchy.

Saving records explicit policy values. A preset name is a description of a
match, never a live authority dependency. Changing a preset definition cannot
change already-issued access. New permissions are absent from existing grants
unless an authorized policy edit adds them within the issuance ceiling.
Administrative presets enumerate their powers instead of meaning every future
permission. Grant lineage continues to impose the deliberate dependencies
defined by the authority plan.

Preset application and individual edits obey the same management ceiling,
grant ceiling, and resource validation. An unavailable preset explains which
powers cannot be issued; it cannot silently apply a smaller set under the same
name or silently add prerequisites. The owner validates the entire proposed
change atomically. Dependent-field changes are shown together before saving.

The editor distinguishes configured permissions from effective access. A parent
restriction can make a configured permission temporarily unavailable without
rewriting the child's configuration or its preset selection. Explain that
restriction beside the affected control. Pausing keeps the configuration;
editing a paused grant does not resume it. Resuming restores only what the
current policy and ancestor limits permit. Revocation is terminal and cannot
be undone by a preset change. Creation and later editing use the same controls
and validation, including the option to issue initially paused access.

This is an application contract implemented by the resource's mutable grant
owner and mediated facets. Editing policy changes what those held facets will
do on later calls. It neither rewrites references already handed out nor adds
a universal property bag or pause operation to every OCapN capability.

## Prior art and the design choice

[Sandstorm's permissions and roles](https://docs.sandstorm.io/en/latest/developing/auth/)
provide a close precedent: applications define permission bits and named
bundles for sharing. Its
[RoleAssignment schema](https://github.com/sandstorm-io/sandstorm/blob/master/src/sandstorm/grain.capnp)
also supports adding and removing permissions from a bundle. Sandstorm documents
that changing a role definition affects existing shares. This plan chooses
explicit saved values so a preset edit cannot silently expand existing grants.

E's [caretaker and filtering-facet patterns](https://erights.org/talks/asian03/paradigm-revised.pdf)
provide the authority precedent: an intermediary can restrict operations or
stop forwarding while its recipient still holds the same reference. The editor
describes that behavior through permissions and lifecycle controls. These
precedents support the parts of the design; they do not establish that the
complete proposed Rooms interaction is already implemented elsewhere.

## Verification

These cases join the parent plan's implementation verification matrix.
They are requirements for future product tests, not claims of passing tests.

| Scenario | Evidence required |
| --- | --- |
| Preset editing | Switching presets clears omitted permissions inside its group and preserves fields outside it. Custom is always reachable without changing values. Exact matches never close the customizer. Matching uses only the group's fields; clients share definitions. |
| Policy and lifecycle | Editing paused access keeps it paused; resuming respects current ancestor limits; preset changes cannot revive revoked access. Invalid combinations and excessive presets fail atomically. |
| Preset independence | Changing a preset definition or adding a permission does not change an issued grant's saved policy or ceiling. Effective restrictions remain distinct from configured values. |
| Sharing modes | Direct sharing copies exact held authority without minting a grant. Managed sharing supports equal or narrower permissions and explains its separate controls, scope, source, and supported lifetime. |
