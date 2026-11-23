# dcvm for agents

dcvm runs KVM virtual machines on this host. You can create a VM, use it over
SSH and delete it, without root. Your account must be in the `dcvm` group
(`dcvm whoami` shows your role).

## Test something in a fresh VM

    dcvm create t1 -o 4 --ttl 2h --wait --json     # stdout: {"name","state","ip","user","expires","ready"}
    dcvm cp ./project t1:/home/ubuntu/project
    dcvm exec t1 -- 'cd project && make test'      # exits with the command's status
    dcvm delete t1 --yes

- Set the password in `DCVM_PASSWORD`; `-p` works too, but other users can see
  it in `ps`. Without a terminal dcvm never asks questions: a missing value is
  an error that names the option, and defaults are used for the rest.
- `--wait` returns once SSH answers, with `"ready":true`. If SSH doesn't answer
  within 10 minutes it exits 1 with `"ready":false`; the VM still exists.
- `--ttl` deletes the VM by itself (`90m`, `2h`, `3d`), so a crashed run leaves
  nothing behind. The reaper runs every 5 minutes.
- `dcvm exec`, `dcvm ssh` and `dcvm cp` use your own SSH key (`~/.ssh`); dcvm
  creates one if you have none. `exec` joins its arguments into one remote
  command line, so quote it as one string. `cp` of a folder into a folder
  that already exists puts it inside; copy to a new path when you retry.
- stdout carries only results (JSON with `--json`); messages and errors go to
  stderr.

## Operating systems (`-o`)

1 Debian 13, 2 Debian 12, 3 Debian 11, 4 Ubuntu 24.04 (default),
5 Ubuntu 22.04, 6 Ubuntu 20.04, 7 Arch Linux, 8 Kali Linux, 9 Fedora 44.
The login user is the OS name (`ubuntu`, `debian`, `archlinux`, `kali`, `fedora`),
or `-u`. Packages on first boot: `-k nginx,docker.io`.

## Your own image (ISO)

    dcvm create-iso r1 --iso ./runner.iso -u runner --uefi --ttl 4h --wait --json

The ISO must install itself (an unattended or autoinstall ISO) and set up
SSH with your public key for the user you name with `-u`; dcvm doesn't
configure the OS inside. The VM boots its disk, or the ISO while the disk is
empty, so the installer's reboot lands in the installed OS. `--wait` waits up
to 30 minutes for SSH. The JSON adds `"vnc"` and `"vnc_password"` to watch
the installer. Without `-u`, `"user"` is null and `ssh`/`exec`/`cp` refuse.

## Read state as JSON

    dcvm list --json          # [{"name","owner","state","ip","vcpus","memory_mb"}]
    dcvm info t1 --json       # adds "user", "protected", "expires", "created"
    dcvm whoami --json

## Other commands you may use on your own VMs

start, stop, restart, console, backup create|list|restore|delete|export,
protect / unprotect (refuses delete and restore), network ports add|remove|show
(forward SSH and HTTP from the host), network vnc enable|status (VNC with a
password), fix-lock.

## Exit codes

0 success; 77 not allowed (the message says why: no such VM of yours, quota,
an option users may not pass, --yes missing); 70 the dcvm service failed or
isn't running; 130 interrupted. Anything else is the command's own failure
(usually 1): a bad value, a VM that isn't running, `--wait` timing out.
`dcvm exec` exits with the remote command's status, or 255 if SSH failed.

Retrying is safe: deleting a VM that is already gone exits 77 ("you have no VM
named ..."), and a create whose name is taken exits 77 too; check with
`dcvm info <vm> --json` before creating again.

## Limits

Each user has quotas (VMs, vCPUs, memory, disk; `/etc/dcvm/limits.conf`). You
see and change only your own VMs and backups. `delete` without a terminal needs
`--yes`. Admins (`dcvm-admin`) can do everything.
