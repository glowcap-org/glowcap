# Devcontainer networking

The devcontainer joins two Docker networks:

- `glowcap-rooms-net` connects it to the Rooms deployment. The name is fixed in both Compose
  files, and `initialize.sh` creates it before the container starts.
- `egress-net` gives the checkout ordinary outbound access. By default it is an
  isolated, worktree-specific bridge. It may instead name an existing network
  that exposes a host-specific agent backend.

The primary checkout needs no network setup. `initialize.sh` creates
`glowcap-dev-main-egress` on first use. A linked worktree gets its corresponding
name when it is configured:

```sh
bash .devcontainer/bin/configure.sh --port-offset 10000
```

To attach an existing backend instead, name it during initial configuration:

```sh
docker network create llm-backend-net  # only if another stack has not created it
bash .devcontainer/bin/configure.sh --egress-net llm-backend-net
```

Custom networks are external authority: startup requires them to exist and
never creates a misspelled name. Delete the ignored `.devcontainer/.env` and
run `configure.sh` again to change between the isolated default and a custom
network.

The Rooms deployment's example override publishes its web surface on host
loopback port 8080. It shares `glowcap-rooms-net` with the devcontainer.
Development bindings cannot use host port 8080, even when production is down.

Development host ports come from one baseline table plus a worktree offset.
The web baseline is 9080: main uses offset 0, while offsets 10000, 20000,
and 30000 give web ports 19080, 29080, and 39080. These sets do not overlap.
The devcontainer reserves its published host ports for its entire lifetime,
including when no development server is running inside it.

Existing ignored `.devcontainer/.env` files keep their assignments when
`configure.sh` runs. To adopt the development baselines, set the primary
checkout's entries to:

```dotenv
GLOWCAP_ROOMS_WEB_HOST_PORT=9080
GLOWCAP_ROOMS_CAPTP_HOST_PORT=10099
GLOWCAP_ROOMS_RELAY_HOST_PORT=10200
GLOWCAP_ROOMS_TRACE_HOST_PORT=10300
GLOWCAP_OCAPNVIZ_HOST_PORT=6173
GLOWCAP_DOCS_HOST_PORT=2990
```

For each linked worktree, add its offset to all six values above. Preserve
every checkout's other configuration, including its paths and egress network.
Check the proposed ports against the host's running containers and listeners,
then run `bash .devcontainer/bin/up.sh --rebuild` from each changed checkout on
the host. This recreates that devcontainer and disconnects its sessions;
it does not change the Rooms deployment or its volumes. Editing `.env` alone
does not release the old host bindings.

## How the rooms peer connects

Inside `glowcap-rooms-net`, a rooms peer fetches its bootstrap locator from
`http://glowcap-rooms-directory:8080/locator` (`directory` is also a Docker DNS alias). It
then dials the returned `ocapn://<nodeid>.iroh` locator through iroh discovery.

Port 8080 serves the browser UI and locator endpoint inside the container.
CapTP traffic does not travel through that HTTP port. Compose publishes every
canonical service port onto host loopback at the host port selected in this
worktree's ignored `.env`; the editor does not add a second forwarding layer.
Publishing on loopback leaves the same port numbers free on the machine's
tailnet addresses for a listener such as Tailscale Serve.
