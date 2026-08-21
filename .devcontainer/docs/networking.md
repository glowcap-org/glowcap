# Devcontainer networking

The devcontainer joins two Docker networks:

- `rooms-net` connects it to the rooms app. The name is fixed in both Compose
  files, and `initialize.sh` creates it before the container starts.
- `egress-net` gives the checkout ordinary outbound access. By default it is an
  isolated, worktree-specific bridge. It may instead name an existing network
  that exposes a host-specific agent backend.

The primary checkout needs no network setup. `initialize.sh` creates
`pancake-main-egress` on first use. A linked worktree gets its corresponding
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

The rooms deployment has its own `EGRESS_NET`, usually
`cloudflare-tunnel-net`. The two stacks share only `rooms-net` unless the
operator explicitly gives them the same egress network.

## How the rooms peer connects

Inside `rooms-net`, a rooms peer fetches its bootstrap locator from
`http://pancake-rooms:8000/locator` (`rooms` is also a Docker DNS alias). It
then dials the returned `ocapn://<nodeid>.iroh` locator through iroh discovery.

Port 8000 serves the browser UI and locator endpoint inside the container.
CapTP traffic does not travel through that HTTP port. Compose publishes every
canonical service port onto the host port selected in this worktree's
ignored `.env`; the editor does not add a second forwarding layer.
