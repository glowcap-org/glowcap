# Optional Rooms account custody

Status: proposed companion contract for the [hosting plan](rooms-hosting.md).
Delete it with that plan when the account milestone lands.

Accounts offer recovery for explicitly entrusted session access. Hosting,
local sessions and browser ownership do not depend on this service.
The hosting plan owns implementation order and acceptance checks.

## Acquisition and lifetime

An OIDC provider authenticates a login. Rooms owns the account and its held
capabilities. The provider stores no session inventory or bearer references.
An account can retain access to several sessions, and several accounts can
hold different access to one session. Neither owns the other by containment.

The private account record maps verified issuer and subject pairs to its
local account identity. Linking another provider requires account-management
authority and fresh proof of that identity. Email or nickname equality never
merges accounts. Provider-specific subject identifiers cannot be joined
across deployments by guess.

Use configured OIDC issuers, authorization code flow and PKCE. Validate
issuer, signature, audience, expiry, nonce and initiating login state through
a maintained OIDC implementation. Operator configuration bounds discovery
network access. Provider tokens stay at this edge. Keycloak and Google are
the first self-hosted and hosted interoperability targets for one adapter.

After login, the account lists only explicitly retained access. Session
creation consumes a hosting allocation, separate from login. The allocation
caps aggregate storage and work across its sessions. Account-to-session
placement is many-to-many and cannot assume a shared transaction.

Bridge HTTPS login to CapTP with single-use redemption tied to the initiating
browser login and its pending CapTP attachment. The receiver proves custody
of that attachment. Record issuance before delivery so a retry recovers the
same live result. A provider token or reusable root link is not the bridge.

Enrolling managed session access explicitly supplies a narrow capability
at the session's host for opening and retiring device attachments. Its
ceiling is the retained source access. It cannot inspect siblings, change
that source grant or recover private root management. The account keeps
this opening authority private. Browsers receive their attachment only.

The host creates a live dependent endpoint guarded by the source access and
a local revocation cell. Returned managed readers and callbacks inherit
both guards. Independent management is separately held and requested.
Chat and file calls go directly to the session host, with local checks.
The account service and provider are absent from this data path.

These attachment rules apply only to account-acquired views. Local sessions
and independently held capabilities retain their own lifetimes and reconnect
contracts.

A login is not a permanent grant. Its live attachment has bounded state and
ends on confirmed revocation, host restart or loss of its owning browser
connection. Connection-loss cleanup must not revoke siblings using that
connection. Reconnecting performs fresh account acquisition. Durable device
access for an agent or explicitly remembered client is a separately issued
managed grant, with its own owner and revocation control.

An attachment transitions from pending to open to closed. Cancellation can
close it while pending, and closed is terminal. Before approval, the account
records the exact pending target and its cancellation authority. A delayed
approval after cancellation fails instead of creating a replacement.
Issuance retries address that same generation, and a host restart ends it.

The owning browser connection is the connection that proved possession of
the pending attachment, not the account service's approving connection.
Losing one account-service connection cannot retire unrelated browsers.
Each login view also has an independent close handle even when several
views share one browser connection.

Persist opening authority and operation keys rather than raw live handles.
Bound issuance receipts by the login lifetime and refuse replay outside the
retained sequence window. Account restart can reconcile an existing result
through its opening authority. A persisted login fence prevents replacement
issuance. Target restart invalidates the old live generation.

Sign-out ends local custody, fences further account acquisition and requests
revocation of its attachments. Remove-device does this for the device's
managed access. Revoke-access changes the underlying session grant at its
owner. Requests and confirmations are explicit. An unreachable host stays
pending, with no claim that its access has ended.

Connection failure detection is not a revocation deadline. A partitioned
account service cannot guarantee bounded remote revocation while also letting
clients call their hosts directly and remain available indefinitely.
The default chooses direct capability access and availability. It does not
introduce periodic renewal or a global device-lease service.

A deployment requiring bounded authorization during partitions must select
an explicit expiry contract and its availability cost. That is a distinct
attachment policy, not an unnoticed property of OIDC sign-in. The base
implementation does not build a challenge protocol for that unrequested
requirement. The local source-and-lifetime guard leaves a place to add expiry
without changing membership, storage or CapTP.

A provider outage blocks new login through that provider. Existing admitted
logins and session attachments continue under their own lifetimes. Provider
logout alone does not revoke Rooms capabilities. Account suspension fences
new acquisition and initiates explicit attachment revocation. Ending a view
does not stop the session's independently authorized recording or membership.

The default hosted account trusts its provider for recovery and its hosting
operator with server-held state. Provider takeover can compromise recoverable
access. An owner can keep independent management and recovery capabilities
outside the account. Explicitly delegated capabilities and disclosed data
cannot be recalled by account sign-out.

A guest or agent can use a scoped capability without a provider identity.
Remembering it in an account is explicit and never enlarges authority.
A foreign session without the managed attachment contract remains an exact
held capability. Do not label it as account-managed device access or silently
proxy its calls to manufacture that behavior.

Creation across account and hosting partitions first records the intent,
then creates through a stable operation key and adopts the returned access.
A lost reply recovers the same receipt, not another session. Unclaimed
creations remain charged to their allocation until recovered or retired.
Account indexing does not imply a distributed commit.

## Sources

- Identity and acquisition standards: [OpenID Connect Core](https://openid.net/specs/openid-connect-core-1_0.html)
  and [OAuth security best practice](https://www.rfc-editor.org/rfc/rfc9700.html).
- Provider integration references: [Keycloak OIDC](https://www.keycloak.org/securing-apps/oidc-layers)
  and [Google OIDC](https://developers.google.com/identity/openid-connect/openid-connect).
