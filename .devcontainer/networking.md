# Devcontainer networking

The devcontainer joins two Docker networks:

- `rooms-net` connects it to the rooms app. The name is fixed in both Compose
  files, and `initialize.sh` creates it before the container starts.
- `egress-net` connects agents to a host-specific backend. Its real Docker
  network name stays in the ignored `.devcontainer/.env`.

Set the egress network before rebuilding:

```sh
cp .devcontainer/.env.example .devcontainer/.env
# Set EGRESS_NET in .devcontainer/.env.
docker network create llm-backend-net
```

Use the name you put in `EGRESS_NET` for the `docker network create` command.
Then choose **Dev Containers: Rebuild and Reopen in Container**.

The rooms deployment has its own `EGRESS_NET`, usually
`cloudflare-tunnel-net`. The two stacks share only `rooms-net`.

## How the rooms peer connects

Inside `rooms-net`, a rooms peer fetches its bootstrap locator from
`http://pancake-rooms:8000/locator` (`rooms` is also a Docker DNS alias). It
then dials the returned `ocapn://<nodeid>.iroh` locator through iroh discovery.

Port 8000 serves the browser UI and locator endpoint. CapTP traffic does not
travel through that HTTP port.
