# Users and agents without root

Since 0.9.10 people and agents can use dcvm from their own accounts, without
`sudo`. Root installs dcvm once; after that, members of the `dcvm` group run
`dcvm` as themselves and manage their own VMs. Root keeps working exactly as
before.

- [Roles](#roles)
- [Adding users](#adding-users)
- [What a user can do](#what-a-user-can-do)
- [Ownership](#ownership)
- [Quotas](#quotas)
- [Agents](#agents)
- [How it works](#how-it-works)
- [Audit log](#audit-log)
- [Upgrading from 0.9.9](#upgrading-from-099)

See also: [Security](security.md#users-without-root) ·
[Usage](usage.md) · [Architecture](architecture.md)

## Roles

| Role | Who | Can do |
| :--- | :-- | :----- |
| root | `root`, `sudo -i`, dcvm's own services | Everything, as before 0.9.10 |
| admin | members of `dcvm-admin` | Everything root can, from their own account. This role is equivalent to root on the host |
| user | members of `dcvm` | Their own VMs and backups, within quotas. Not root-equivalent |

Members of both groups are admins. `dcvm whoami` prints your role.

## Adding users

```bash
sudo dcvm user add alice            # a user
sudo dcvm user add carol --admin    # an admin
sudo dcvm user list                 # members, roles and how many VMs each owns
sudo dcvm user remove alice         # their VMs stay; hand them over with dcvm owner
```

Group membership takes effect at the user's next login (or `newgrp dcvm`).
The installer offers to make the user who ran `sudo` an admin.

Don't also put users in the `libvirt`, `disk` or `docker` groups: each is
root on the host and bypasses dcvm's limits. `dcvm doctor` warns about it.

## What a user can do

On their own VMs:

| Command | Notes |
| :------ | :---- |
| `create`, `create-iso` | Options are checked against an allowlist (`--graphics` only `none`, `vnc` or `spice`; `--boot` only `cdrom,hd` or `hd,cdrom`). An ISO must be a file the user can read: `-o ./debian.iso`. One VM per command |
| `list`, `status`, `info` | Only their VMs; `--json` for scripts |
| `start`, `stop`, `restart` | One VM, or `all` of theirs |
| `console`, `ssh`, `exec`, `cp` | `ssh`, `exec` and `cp` use the user's own SSH key |
| `delete` | Without a terminal it needs `--yes` |
| `protect`, `unprotect` | A protected VM refuses `delete` and `restore` |
| `backup create`, `list`, `delete`, `restore`, `export` | Only their own backups. `export` writes to a file in the user's own folder |
| `network ports add`, `remove`, `show` | Forwards SSH and HTTP for one VM from dcvm's port ranges |
| `network vnc enable`, `status` | VNC gets a random password, shown only to the VM's owner |
| `fix-lock` | Without restarting libvirt, which serves every user |
| `template list` | A missing image is downloaded when `create` needs it |

Admin only: `network` (start, stop, config, DHCP), `ports setup`/`apply`/`clear`,
`template download`, `backup import`, `restore --base`, `storage`, `doctor`,
`self-update`, `uninstall`, `user`, `owner`, `reap`, and `delete --all`.

A user who tries anything else gets exit status 77 and a message that says why.

## Ownership

Every VM has an owner, kept in `/var/lib/dcvm/vms/<vm>` (owner, resources,
login user, `--ttl` expiry, protection). Users see only the VMs and backups
they own. VMs from before 0.9.10 belong to root, so only admins see them;
`sudo dcvm owner <vm> <user>` hands one over. VM names stay global: two users
can't both have a VM called `web`.

Backups record the owner of the VM they were taken from, in an `owner` file
next to the backup. A later VM with the same name never sees, restores or
rotates away the previous owner's backups.

## Quotas

Users are limited by `/etc/dcvm/limits.conf` (admins and root are not):

```ini
# defaults for every user
vms=5
vcpus=8
memory_mb=16384
disk_gb=200

# one user
user.alice.vms=10
user.alice.memory_mb=32768
```

The values above are the defaults when the file doesn't exist. A request that
would go over a limit is refused before anything is created.

## Agents

`dcvm help agents` prints a short guide written for agents. The usual flow:

```bash
dcvm create t1 --ttl 2h --wait --json        # returns once SSH answers
dcvm cp ./project t1:/home/ubuntu/project
dcvm exec t1 -- 'cd project && make test'    # exits with the test's status
dcvm delete t1 --yes
```

- Without a terminal dcvm never asks: a missing value is an error that names
  the option. The password comes from `DCVM_PASSWORD`.
- `--ttl` (`90m`, `2h`, `3d`) deletes the VM by itself; `dcvm-reaper.timer`
  checks every 5 minutes, so a crashed agent leaves nothing behind.
- `dcvm list --json`, `dcvm info <vm> --json` and `dcvm whoami --json` give
  state for scripts.
- An agent in a sandbox that blocks `sudo` (the "no new privileges" flag)
  still works: dcvm talks to a socket, not to sudo.
- An agent on another machine can log in to the host over SSH with an
  account in the `dcvm` group and run the same commands.

## How it works

`dcvm` run by a user doesn't run the VM scripts itself. A small client
(`lib/server/dcvm-client.py`) sends the command to `/run/dcvm/dcvm.sock`
(group `dcvm`, mode 0660). For each connection systemd starts one root
process (`dcvm@.service`, `lib/server/dcvm-server.py`) that:

1. learns who is calling from the kernel (`SO_PEERCRED`), not from anything
   the client says;
2. checks every argument against what that role may do, the VM's owner,
   protection and quotas;
3. takes a lock on the VM;
4. runs the usual Bash scripts with a clean environment; they know the
   caller and show and change only that user's VMs;
5. writes one line to the audit log.

Files cross as open file descriptors, opened by the client with the user's
own permissions: an ISO or an export target is something the user could
read or write anyway, never a path root opens. Passwords and Tailscale keys
travel inside the request and reach the script through a pipe, never as
command-line arguments. The user's terminal is passed through, so prompts
and progress look the same as for root; Ctrl-C asks the server to stop, and
a command that changes a VM finishes safely first.

Root doesn't use the socket: `sudo -i` then `dcvm …` runs the scripts
directly, as before.

## Audit log

Every request through the socket adds one JSON line to
`/var/log/dcvm/audit.log` (and the journal of `dcvm@*`): time, user, role,
whether it came from a terminal or a script, the command, allowed or denied
and why, the exit status and how long it took. Secrets are never in it.

```bash
sudo tail -f /var/log/dcvm/audit.log
journalctl -u 'dcvm@*' --since today
```

## Upgrading from 0.9.9

`sudo dcvm self-update` installs 0.9.10 and runs its setup: the `dcvm` and
`dcvm-admin` groups, the socket and the `--ttl` timer. Existing VMs belong to
root. Then add users with `sudo dcvm user add`. `dcvm self-update --revert`
removes the socket before going back, so an older version never runs behind
it.
