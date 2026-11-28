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

Keep the deployment configuration fixed and suspend other deployment commands and volume cleanup until the backup finishes. Stop any outside writers to shared volumes or bind mounts before archiving them.
Use the configuration and overrides that started it. Run these commands on the Docker daemon’s host, using its local context. Bind paths and the configuration directory must be readable there, including the original owners’ files and ACLs.

## Check what will be saved

```sh
backup=$(mktemp -d "$HOME/rooms-backup.XXXXXXXX")
glowcap apps rooms deployment backup-plan --dir "$PWD" > "$backup/mounts" &&
  cat "$backup/mounts"
```

Each row gives the mount type, the owner (`@base` or a nickname), the service and container path, the Compose volume key and the Docker volume name or host path.
A stopped member keeps its volumes. If a member lost its `project-id`, restore that file before continuing.

A member prepared with `bots init` can have a session and link before its agent first starts. File-only setup has no volumes yet.

If the plan reports a missing volume, check the member’s history. Use `--unstarted <nickname>` when its session started but its agent never did. This still requires the session store, including after a failed enrollment.
Use `--files-only <nickname>` only if neither its session nor its agent ever started. Missing volumes then appear as `uncreated`. Recover any unexpectedly missing store before backing up.

For `bind` and `file` rows, the last column names a host path, including files supplied as Compose configs or secrets. The configuration archive covers files inside the configuration tree.
Copy every path outside it, including targets reached by symlinks, while the stack is stopped.

For `environment` and `external` rows, recover the named variable or resource separately. The plan can check the source of a mounted file. Only the supplier can confirm the value of a variable or external resource.
An `inline` config lives in the Compose file. Keep any variables used to fill it.

## Stop and archive

Continue after `backup-plan` succeeds. This uses GNU tar to keep ACLs and numeric ownership and the Debian image to read Docker volumes.

```sh
sh -eu -s -- "$backup" <<'SH'
  backup=$1
  umask 077
  test -s "$backup/mounts"
  tab=$(printf '\t')
  while IFS="$tab" read -r kind owner mount key location; do
    if [ "$kind" = member ]; then
      glowcap apps rooms deployment bots down --dir "$PWD" "$owner"
    fi
  done < "$backup/mounts"
  glowcap apps rooms deployment down --dir "$PWD"
  mkdir -m 700 "$backup/volumes"
  while IFS="$tab" read -r kind owner mount key location; do
    [ "$kind" = volume ] || continue
    archive="$backup/volumes/$location.tgz"
    [ ! -f "$archive" ] || continue
    docker volume inspect "$location" >/dev/null
    docker run --rm --network none -v "$location:/volume:ro" debian \
      tar --acls --numeric-owner -czf - -C /volume . > "$archive.partial"
    tar tzf "$archive.partial" >/dev/null
    mv "$archive.partial" "$archive"
  done < "$backup/mounts"
  tar --acls -czf "$backup/config.tgz.partial" -C "$PWD" .
  tar tzf "$backup/config.tgz.partial" >/dev/null
  mv "$backup/config.tgz.partial" "$backup/config.tgz"
SH
```

Copy the external bind mounts you identified before restarting. If a command fails, keep the services stopped while you check the failure.

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

A backup contains the grants that were active when it was taken. During recovery, keep the session off the public network until you have reapplied any later revocations or rotations. Restore current provider credentials before starting the agents.

Stop the named members and the base deployment before restoring either. Keep the current volumes and configuration until the restored services are healthy.
Restore each distinct Docker volume in the last column of `mounts` into one fresh volume. Record the new Docker name beside the original and use it for every mount that shared that volume. This example prints the new name for a directory backed by a volume.

```sh
restore_volume() (
  set -eu
  archive="$backup/volumes/$1.tgz"
  tar tzf "$archive" >/dev/null
  restored=$(docker volume create)
  docker run --rm --network none -i -v "$restored:/volume" debian tar --acls --numeric-owner -xzpf - -C /volume < "$archive"
  printf '%s\n' "$restored"
)

directory_volume=$(awk -F '\t' '$1 == "volume" && $2 == "@base" && $3 == "directory:/state" {print $5}' "$backup/mounts") &&
  restore_volume "$directory_volume"
```

Extract the matching configuration into a new private directory. When the backup includes files owned by the
container user, extract as an account that can restore that owner.

```sh
restored_root=$(mktemp -d "$HOME/rooms-restored.XXXXXXXX") &&
  restored_config="$restored_root/config" && mkdir -m 700 "$restored_config" &&
  tar --acls --numeric-owner -xzpf "$backup/config.tgz" -C "$restored_config"
```

The private parent protects the restored files even if the original configuration directory was shared.
Restore external bind mounts and file-backed configs and secrets to their recorded paths, or update those paths in the overrides. Supply the saved environment variables and external resources.
In the restored `docker-compose.override.yml`, point each logical volume at its recovered Docker name. For example:

```yaml
volumes:
  directory-state:
    name: <Docker volume name printed above>
    external: true
```

Do the same for `session-state` and each configured bot volume. A home restored to a bind mount uses its host path
instead. Run `glowcap apps rooms deployment up --dir "$restored_config"` to use its saved image ID,
then check `deployment status --dir "$restored_config"`. The CLI refuses to reset volumes marked external.

For each named member, find its rows in `mounts`. Put each recovered volume in `bots/<nickname>/compose.override.yml` under the Compose key in column four, using the same `name` and `external` fields shown above.
An `uncreated` row has no archive. Leave it uncreated until you start that member.
Keep each restored `project-id` and any saved `bot-link` with its member’s volumes. Start the intended members and check their health:

```sh
glowcap apps rooms deployment bots up --dir "$restored_config" scout editor
glowcap apps rooms deployment bots status --dir "$restored_config"
```
