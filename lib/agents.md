# dcvm for agents

dcvm runs KVM virtual machines on this host. You can create a VM, use it over
SSH and delete it, without root. Your account must be in the `dcvm` group
(`dcvm whoami` shows your role).

## Test something in a fresh VM

    dcvm create t1 -o 4 --ttl 2h --wait --json     # stdout: {"name":..,"ip":..,"user":..}
    dcvm cp ./project t1:/home/ubuntu/project
    dcvm exec t1 -- 'cd project && make test'      # exits with the command's status
    dcvm delete t1 --yes

- The password comes from `DCVM_PASSWORD` (or `-p`); without a terminal, dcvm
  never asks questions: a missing value is an error that names the option.
- `--wait` returns once SSH answers. `--ttl` deletes the VM by itself
  (`90m`, `2h`, `3d`), so a crashed run leaves nothing behind.
- `dcvm exec`, `dcvm ssh` and `dcvm cp` use your own SSH key (`~/.ssh`); dcvm
  creates one if you have none.

## Operating systems (`-o`)

1 Debian 13, 2 Debian 12, 3 Debian 11, 4 Ubuntu 24.04 (default),
5 Ubuntu 22.04, 6 Ubuntu 20.04, 7 Arch Linux, 8 Kali Linux, 9 Fedora 44.
The login user is the OS name (`ubuntu`, `debian`, `arch`, `kali`, `fedora`),
or `-u`. Packages on first boot: `-k nginx,docker.io`.

## Read state as JSON

    dcvm list --json          # [{"name","state","ip","vcpus","memory_mb"}]
    dcvm info t1 --json       # adds "user", "owner", "protected", "expires"
    dcvm whoami --json

## Other commands you may use on your own VMs

start, stop, restart, console, backup create|list|restore|delete|export,
protect / unprotect (refuses delete and restore), network ports add|remove|show
(forward SSH and HTTP from the host), network vnc enable|status (VNC with a
password), fix-lock.

## Exit codes

0 success, 77 not allowed (the message says why: not your VM, quota, an option
users may not pass, --yes missing), 70 dcvm itself failed, anything else is the
failing command's own status.

## Limits

Each user has quotas (VMs, vCPUs, memory, disk; `/etc/dcvm/limits.conf`). You
see and change only your own VMs and backups. `delete` without a terminal needs
`--yes`. Admins (`dcvm-admin`) can do everything.
