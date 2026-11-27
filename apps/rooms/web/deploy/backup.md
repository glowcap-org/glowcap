---
type: static
description: Back up and restore a Rooms deployment, its identities and bot members.
audience: human
sources:
  - resource: /apps/rooms/web/deploy/
  - resource: /cli/app/rooms/deployment/
---

# Back up a stopped stack

Run this in the configuration directory printed by `deployment doctor`. Choose a backup directory outside that
configuration. The example creates one under your home.

Set the volume names to match your override. For the example bot, include `glowcap-rooms-bot-session-state` (session identity and grants),
`glowcap-rooms-bot-state` (settings, saved link and position), and `glowcap-rooms-bot-home` (agent files).
For [named members](members.md), the script stops each member project and finds its volumes by the Compose project label.
Add any external volumes you supply in overrides to the list by name. Record which service and mount each belongs to.
Back up bind mounts outside the configuration directory separately.

```sh
backup=$(mktemp -d "$HOME/rooms-backup.XXXXXXXX")
sh -eu -s -- "$backup" <<'SH'
  backup=$1
  umask 077
  test -d "$backup"
  set -- glowcap-rooms-directory-state glowcap-rooms-session-state
  # For the example bot, uncomment this line:
  # set -- "$@" glowcap-rooms-bot-session-state glowcap-rooms-bot-state glowcap-rooms-bot-home
  # Add any external volumes from your overrides to "$@" here.
  for id_file in bots/*/project-id; do
    [ -f "$id_file" ] || continue
    member_dir=${id_file%/project-id}
    nick=${member_dir##*/}
    project="glowcap-member-$nick-$(cat "$id_file")"
    glowcap apps rooms deployment bots down --dir "$PWD" "$nick"
    volumes=$(docker volume ls -q --filter "label=com.docker.compose.project=$project")
    for volume in $volumes; do
      logical=$(docker volume inspect --format '{{index .Labels "com.docker.compose.volume"}}' "$volume")
      printf '%s %s %s\n' "$nick" "$logical" "$volume" >> "$backup/member-volumes"
      set -- "$@" "$volume"
    done
  done
  glowcap apps rooms deployment down --dir "$PWD"
  for volume in "$@"; do
    docker volume inspect "$volume" >/dev/null
    docker run --rm -v "$volume:/volume:ro" debian tar czf - -C /volume . > "$backup/$volume.tgz.partial"
    tar tzf "$backup/$volume.tgz.partial" >/dev/null
    mv "$backup/$volume.tgz.partial" "$backup/$volume.tgz"
  done
  tar --acls -czf "$backup/config.tgz.partial" -C "$PWD" .
  tar tzf "$backup/config.tgz.partial" >/dev/null
  mv "$backup/config.tgz.partial" "$backup/config.tgz"
SH
```

Keep the backup private. The configuration archive includes the
overrides, image selection, agent Dockerfile, sign-in files and bearer links.
Each named member's private directory under `bots/` includes its project id, link, role and agent home.
The configuration archive commands use GNU tar's `--acls` to preserve the agent user's file access. Run them under an account that can read and restore the original owners and permissions.

After the backup succeeds, start the base with `glowcap apps rooms deployment up --dir "$PWD"`.
Run `glowcap apps rooms deployment bots up --dir "$PWD" scout editor` for the members you want back online.

## Keep a copy of the selected image

The configuration backup records the image ID. To recover a local-only build or recover after Docker discards its
cached image, save the image itself once. This optional archive can be large. Use the image selected in the stopped
stack's backup:

```sh
(
  set -eu
  umask 077
  saved_image=$(tar xOzf "$backup/config.tgz" ./image)
  docker image save "$saved_image" > "$backup/rooms-image.tar.partial"
  mv "$backup/rooms-image.tar.partial" "$backup/rooms-image.tar"
)
```

On the recovery host, load that archive before starting the stack. Check that Docker can resolve the saved ID:

```sh
saved_image=$(tar xOzf "$backup/config.tgz" ./image) &&
  docker image load --input "$backup/rooms-image.tar" &&
  docker image inspect "$saved_image" >/dev/null
```

An image must support the recovery host's architecture. The optional bot service rebuilds its own image from the
Dockerfile and package settings in your override. For named members, keep their agent images or rebuild them before starting the restored members.

## Restore a backup

Stop the named members and the base deployment before restoring either. Keep the current volumes and configuration until the restored services are healthy.
For each volume archive, restore into a fresh volume. This example prints the Docker volume name for the directory:

```sh
(
  set -eu
  archive="$backup/glowcap-rooms-directory-state.tgz"
  tar tzf "$archive" >/dev/null
  restored=$(docker volume create)
  docker run --rm -i -v "$restored:/volume" debian tar --numeric-owner -xzpf - -C /volume < "$archive"
  printf '%s\n' "$restored"
)
```

Extract the matching configuration into a new private directory. When the backup includes files owned by the
container user, extract as an account that can restore that owner.

```sh
restored_root=$(mktemp -d "$HOME/rooms-restored.XXXXXXXX") &&
  restored_config="$restored_root/config" && mkdir -m 700 "$restored_config" &&
  tar --acls --numeric-owner -xzpf "$backup/config.tgz" -C "$restored_config"
```

The private parent protects the restored files even if the original configuration directory was shared.
Recover external bind mounts separately. In the restored `docker-compose.override.yml`, update their paths and
point each logical volume at its recovered Docker name. For example:

```yaml
volumes:
  directory-state:
    name: <Docker volume name printed above>
    external: true
```

Do the same for `session-state` and each configured bot volume. A home restored to a bind mount uses its host path
instead. Run `glowcap apps rooms deployment up --dir "$restored_config"` to use its saved image ID,
then check `deployment status --dir "$restored_config"`. The CLI refuses to reset volumes marked external.

For each named member, look up its `session-state`, `bot-state` and `bot-home` archives in `member-volumes`.
Put its recovered volume names in `bots/<nickname>/compose.override.yml`, using the same `name` and `external` fields shown above.
Keep its restored `project-id` and `bot-link` together with that member's volumes. Start the intended members and check their health:

```sh
glowcap apps rooms deployment bots up --dir "$restored_config" scout editor
glowcap apps rooms deployment bots status --dir "$restored_config"
```
