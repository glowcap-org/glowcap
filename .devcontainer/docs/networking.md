# Devcontainer networking

The devcontainer joins two Docker networks:

- `rooms-net` connects it to the rooms app. The name is fixed in both Compose
  files, and `initialize.sh` creates it before the container starts.
- `egress-net` gives the checkout ordinary outbound access. By default it is an
  isolated, worktree-specific bridge. It may instead name an existing network
  that exposes a host-specific agent backend.

The primary checkout needs no network setup. `initialize.sh` creates
`glowcap-main-egress` on first use. A linked worktree gets its corresponding
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

The Rooms deployment publishes its web surface on host loopback and shares
only `rooms-net` with the devcontainer.

## How the rooms peer connects

Inside `rooms-net`, a rooms peer fetches its bootstrap locator from
`http://glowcap-rooms:8000/locator` (`rooms` is also a Docker DNS alias). It
then dials the returned `ocapn://<nodeid>.iroh` locator through iroh discovery.

Port 8000 serves the browser UI and locator endpoint inside the container.
CapTP traffic does not travel through that HTTP port. Compose publishes every
canonical service port onto host loopback at the host port selected in this
worktree's ignored `.env`; the editor does not add a second forwarding layer.
Publishing on loopback leaves the same port numbers free on the machine's
tailnet addresses for a listener such as Tailscale Serve.
