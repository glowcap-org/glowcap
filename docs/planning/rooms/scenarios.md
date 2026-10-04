# Rooms sharing walkthroughs

Status: active plan. These phase 1 walkthroughs join the opening examples in
the [access plan](access-grants.md). They make the proposed interaction
reviewable across issue, use, change, delegation, reconnect and revocation.
They are implementation acceptance scenarios, not reports of passing tests.
The [operation matrix](authority.md) and [storage contract](persistence.md)
own exact requirements and transaction boundaries.

## A session display

| Step | Interaction and required result |
| --- | --- |
| Issue | The session owner selects Create managed access, label “display”, Observer, History off, no custody powers and persistent lifetime on a native durable owner. It sets an explicit ceiling permitting later InteractWorkspace promotion if desired. |
| Use | The display sees authorized live workspace state. Old history, archived files, pending-effect controls and raw room/operator capabilities are absent. Held subscription deliveries consult the attachment grant. |
| Change | The owner changes to Collaborator within the ceiling, then pauses. The same link stays valid; paused status carries no workspace content. Editing policy while paused does not resume it. |
| Delegate | A copy is the same grant. A managed child is available only when delegation was explicitly allowed and is bounded by current terms. It cannot recover the session's root or control capability. |
| Reconnect | The display restores its exact endpoint and cursor. Expired visible event history yields a current scoped snapshot; History off never triggers archive replay. A browser-live owner instead reports that its tab lifetime ended. |
| Revoke | The owner confirms the exact grant/revision. The display and its dependent children stop; session-owned room seats and independently attached views continue. Retained file proxies cannot escape through an older attachment. |

## A room helper who can speak

| Step | Interaction and required result |
| --- | --- |
| Issue | A room owner creates a Single admission, Can rejoin offer with Speaker, optional ReadFile, History off, Upload/SetTopic/Invite off. Its explicit ceiling can allow later promotion. The invitation does not include the issuer's control. |
| Use | Acceptance atomically stores exact continuing access and receipt. Join returns a seat; post and typing work, while files, topic and minting offers refuse. The recipient status page describes the retained return route. |
| Change | Promotion requires current source and management ceiling. Newly permitted facilities can be acquired at the committed revision. Narrowing makes retained older facets refuse before their next effect/chunk. |
| Delegate | With Invite off, the helper cannot mint another admission. It can still forward its bearer access; the UI describes the shared grant and four-seat ceiling rather than promising a ban on sharing. |
| Reconnect | The helper rejoins through exact continuing access, not ensureRoomLink. Receipt retry after lost acceptance returns the same result; grant/seat limits prevent duplicate admission. Old seat work retires before replacement. |
| Revoke | Close invitation preserves the helper's access. Revoke branch terminates accepted access and its seats. Kick alone ends a seat; the continuing grant may rejoin. Public or independent entrances remain visible as separate routes. |

## A directory visitor and a creator

| Step | Interaction and required result |
| --- | --- |
| Issue | The administrator issues Member directory access for browsing, presence, introductions and signaling, then a separately controlled CreateRoom grant. PublishListing and management are absent. |
| Use | Registration returns a dependent name/voucher. Creation records a new independent room and exact ownership result before replying. A discovery row contains only a public offer; listing does not grant hidden room content. |
| Change | Narrowing Member to Visitor releases name presence, inbox custody, pending introductions and signaling exchanges. Independently established direct peers remain valid. Restoring Presence permits a new registration, not an old voucher replay. |
| Delegate | A child directory grant remains bounded by its source. A newly created independent room has explicitly issued ownership; it is not a dependent directory child because it happens to appear in a list. |
| Reconnect | Native access restores exact endpoints. Authenticated registration continuity or the old live name's one-use voucher replaces a stale claim, with fresh current grant checks. Names in workspace intent supply no authority. |
| Revoke | Revoke CreateRoom stops further creation without destroying created rooms or releasing their storage quota. Revoke Member removes dependent directory services without revoking separately held room or direct capabilities. |

## Existing session authority and a managed equivalent

| Step | Interaction and required result |
| --- | --- |
| Issue | Send existing access hands over the exact session capability already held, including owner powers if it is an owner capability. Create managed access separately issues equal or narrower delegable terms with an immutable source dependency. |
| Use | Both references exercise their declared operations. Equal initial permissions do not confer the issuer's separate management control or unrelated room/operator references. |
| Change | A direct copy has no recipient-specific policy editor. The managed grant has its own control, ceiling, revision and pause state. Editing one grant never retargets a copied source link. |
| Delegate | Direct forwarding preserves the exact existing boundary. Managed descendants retain ancestry, current policy limits and aggregate quotas. A control descendant is separately attenuated and cannot inspect siblings. |
| Reconnect | A persistent direct share saves the exact existing role; a persistent managed share saves its endpoint. Durable storage cannot extend a live-only upstream dependency beyond its host lifetime. Unsupported saves refuse before writing. |
| Revoke | Revoking the managed child preserves separately held original access. Revoking its source disables the dependent branch. Revoking only the issuer control preserves independent use authority; copied original data cannot be recalled. |

## One message from a nested room

| Step | Interaction and required result |
| --- | --- |
| Issue | The sender selects one authorized message and Create managed access. The target is an exact message scope with ReadContent and permitted file projections; no parent/collection browsing or administration is included. |
| Use | The recipient opens a focused message view, then places that exact facet in another room. Source label and authored context are disclosed only when authorized. Reply in source requires separately held posting authority; Discuss here posts to the destination. |
| Change | Narrow ReadFile or pause the share. Retained file readers, previews, search entries and queued notifications stop redisclosing data. An explicit source edit/withdraw changes the message state through all its authorized views. |
| Delegate | A separately managed reshare retains the source facet as upstream authority across owners. Copying the existing facet keeps the same grant; quoting received text creates new data with separate ownership. |
| Reconnect | The destination saves the exact facet with a checked sturdyref or local restoration edge. Restoration never follows a source path through a broad room root. A partition reports unreachable access without promising a remote revocation commit. |
| Revoke | Revoking the reshare disables it and its dependents. Independent original-message access remains usable. The destination entry shows unavailable status without revealing siblings or fetching a stronger source entrance. |

## Reorganization and audience

Rename keeps stable identities, grants, reply targets and ordering. A same-owner
move/split/merge preview names the exact selection, source/destination revisions,
subtree coverage changes and preserved object grants. Newly exposing messages
requires a bounded audience-change management control in addition to Reorganize.
The owner commits structural/content changes atomically within the shared
16-effect bound. Oversized selections refuse before any move; a stale preview
requires another preview. Independent exact grants remain bound to their object;
parent-dependent grants can lose effective coverage after reparenting.

Merging chooses one destination and archives emptied source conversations;
their stable IDs remain resolvable within authority, and source-scoped grants
do not become destination-wide grants. Moved messages preserve authored
context and source-relative order. Destination insertion is an explicit audience
change, not a sender-controlled timestamp trick around a history floor.

Across owners, moving a placement inserts the same retained capability at the
destination and removes the source placement through separate authorized acts.
If insertion succeeds and removal fails, the UI reports two placements and
offers an exact removal retry. It does not claim an atomic ownership transfer.
A copied message gets new identity and authored copy context; received bytes
cannot be revoked by changing the original grant.

## Review and proof checklist

The end-to-end proof for each walkthrough must hold older topic/file/line/name
references across a change, lose an acknowledgement at the authority commit,
reconnect with the exact retained terms, and keep an independent capability
usable on the same connection. Every displayed success has an owner commit;
every partial or unavailable operation has a named recovery route. Recipient
status and management inventory disclose only their held scope. Native/Wasm,
keyboard/narrow-screen and outside-peer requirements follow the owning
[integration matrix](access-grants.md#verification-matrix).
