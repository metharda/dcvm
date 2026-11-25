"""dcvm socket server: policy for one connection; the Bash modules do the work."""

import fcntl
import grp
import json
import os
import pwd
import re
import select
import signal
import socket
import stat
import struct
import subprocess
import sys
import termios
import time

PROTOCOL = 1
MAX_REQUEST = 256 * 1024
MAX_FDS = 8
MAX_ISO = 16 * 1024**3
REQUEST_TIMEOUT = 15
MAX_PER_UID = 8
MAX_PENDING = 1024 * 1024
WRITE_TIMEOUT = 5
CANCEL_GRACE = 30

DCVM = "/usr/local/bin/dcvm"
CONFIG = "/etc/dcvm-install.conf"
STATE = "/var/lib/dcvm"
RUN = "/run/dcvm"
AUDIT = "/var/log/dcvm/audit.log"
LIMITS = "/etc/dcvm/limits.conf"
ADMIN_GROUP = "dcvm-admin"
USER_GROUP = "dcvm"
DRY_RUN = False
ROLE_MAP = {}

DEFAULT_LIMITS = {"vms": 5, "vcpus": 8, "memory_mb": 16384, "disk_gb": 200}

NAME = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_-]{2,63}\Z")
RESERVED = {"all", "latest", "help"}
BACKUP_ID = re.compile(r"^([0-9]{8}_[0-9]{6}|[0-9]{2}\.[0-9]{2}\.[0-9]{4}(-[0-9]+)?|latest)\Z")
SIZE = re.compile(r"^[1-9][0-9]{0,4}[GgMmTt]\Z")
USERNAME = re.compile(r"^[a-z_][a-z0-9_-]{2,31}\Z")
PACKAGES = re.compile(r"^[A-Za-z0-9][A-Za-z0-9@._+-]*(,[A-Za-z0-9][A-Za-z0-9@._+-]*)*\Z")
# No leading zeros: iptables reads 050 as octal.
OCTET = r"(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])"
IPV4 = re.compile(r"^(%s\.){3}%s\Z" % (OCTET, OCTET))
TTL = re.compile(r"^([1-9][0-9]{0,4})([mhd])\Z")
MAX_TTL_DAYS = 3650
OS_VARIANT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}\Z")
TERM = re.compile(r"^[A-Za-z0-9._+-]{1,64}\Z")


class Denied(Exception):
    pass


SECRET_FLAGS = ("-p", "--password", "-r", "--root-password", "--tailscale-authkey")


def redact(argv):
    out, hide = [], False
    for a in argv:
        if not isinstance(a, str):
            out.append("***" if hide else "<not text>")
            hide = False
        elif hide:
            out.append("***")
            hide = False
        elif a in SECRET_FLAGS:
            out.append(a)
            hide = True
        elif a[:2] in ("-p", "-r") and len(a) > 2 and not a.startswith("--"):
            out.append(a[:2] + "***")
        elif any(a.startswith(f) and a != f for f in SECRET_FLAGS if f.startswith("--")):
            out.append(a.partition("=")[0] + "=***" if "=" in a else a[:2] + "***")
        else:
            out.append(a)
    return out


def redact_text(text, argv):
    # Errors quote what the caller typed; a secret must not reach the log through them.
    for raw, shown in zip(argv, redact(argv)):
        if isinstance(raw, str) and raw and raw != shown:
            text = re.sub(r"(?<![^\s'\"=:(])%s(?![^\s'\",:)])" % re.escape(raw), lambda _m: shown, text)
    return text


def read_config():
    conf = {"DATACENTER_BASE": "/srv/datacenter"}
    try:
        with open(CONFIG) as f:
            for line in f:
                m = re.match(r'^([A-Z_]+)="?([^"\n]*)"?$', line.strip())
                if m:
                    conf[m.group(1)] = m.group(2)
    except OSError:
        pass
    return conf


def role_of(uid):
    if uid in ROLE_MAP:
        return ROLE_MAP[uid]
    if uid == 0:
        return "root"
    try:
        pw = pwd.getpwuid(uid)
    except KeyError:
        return None
    names = {grp.getgrgid(g).gr_name for g in os.getgrouplist(pw.pw_name, pw.pw_gid) if _gid_exists(g)}
    if ADMIN_GROUP in names:
        return "admin"
    if USER_GROUP in names:
        return "user"
    return None


def _gid_exists(g):
    try:
        grp.getgrgid(g)
        return True
    except KeyError:
        return False


def user_name(uid):
    try:
        return pwd.getpwuid(uid).pw_name
    except KeyError:
        return str(uid)


def registry_path(vm):
    return os.path.join(STATE, "vms", vm)


def registry_read(vm):
    entry = {}
    try:
        with open(registry_path(vm)) as f:
            for line in f:
                k, _, v = line.rstrip("\n").partition("=")
                if k:
                    entry[k] = v
    except OSError:
        return None
    return entry


def registry_write(vm, entry):
    os.makedirs(os.path.join(STATE, "vms"), mode=0o700, exist_ok=True)
    tmp = registry_path(vm) + ".tmp"
    with open(tmp, "w") as f:
        for k, v in entry.items():
            f.write("%s=%s\n" % (k, str(v).replace("\n", " ")))
    os.chmod(tmp, 0o600)
    os.replace(tmp, registry_path(vm))


def registry_all():
    d = os.path.join(STATE, "vms")
    try:
        names = sorted(n for n in os.listdir(d) if NAME.match(n))
    except OSError:
        return {}
    return {n: e for n in names if (e := registry_read(n)) is not None}


def owner_of(vm):
    entry = registry_read(vm)
    return int(entry.get("owner_uid", "0")) if entry else 0


def domain_known(vm):
    """True or False when libvirt answers, None when it doesn't."""
    if DRY_RUN:
        return registry_read(vm) is not None
    r = subprocess.run(["virsh", "list", "--all", "--name"], stdout=subprocess.PIPE,
                       stderr=subprocess.DEVNULL, env=module_env_base())
    return vm in r.stdout.decode(errors="replace").split() if r.returncode == 0 else None


def vm_exists(vm):
    # Unknown counts as existing: nothing may be reused or removed while libvirt is down.
    return domain_known(vm) is not False


def lock(name):
    os.makedirs(os.path.join(RUN, "locks"), mode=0o700, exist_ok=True)
    fd = os.open(os.path.join(RUN, "locks", name), os.O_RDWR | os.O_CREAT, 0o600)
    deadline = time.time() + 30
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except BlockingIOError:
            if time.time() > deadline:
                os.close(fd)
                raise Denied("another operation on %s is still running; try again in a moment" % name.split("-", 1)[-1])
            time.sleep(0.2)


def limits_for(user):
    limits, mine = dict(DEFAULT_LIMITS), {}
    try:
        with open(LIMITS) as f:
            for line in f:
                line = line.split("#", 1)[0].strip()
                k, _, v = line.partition("=")
                k, v = k.strip(), v.strip()
                if not v.isdigit():
                    continue
                prefix, _, name = k.rpartition(".")
                if k in limits:
                    limits[k] = int(v)
                elif prefix == "user." + user and name in limits:
                    mine[name] = int(v)
    except OSError:
        pass
    # A user's own line wins over a global one wherever either stands in the file.
    limits.update(mine)
    return limits


def size_gb(value, default):
    if not value:
        return default
    v = value.upper()
    if v.endswith("M"):
        return max(1, -(-int(v[:-1]) // 1024))
    if v.endswith("T"):
        return int(v[:-1]) * 1024
    return int(v.rstrip("G"))


def gib(n):
    return -(-n // 1024**3)


def backup_bytes(uid):
    """What uid's backups take on disk, plus what backups still being written have reserved."""
    total = 0
    d = os.path.join(read_config()["DATACENTER_BASE"], "backups")
    for f in os.scandir(d) if os.path.isdir(d) else []:
        if not re.search(r"-[0-9]{8}_[0-9]{6}\Z", f.name) or not f.is_dir(follow_symlinks=False):
            continue
        try:
            with open(os.path.join(f.path, "owner")) as fh:
                if fh.read().strip() != str(uid):
                    continue
            total += sum(e.stat(follow_symlinks=False).st_blocks * 512 for e in os.scandir(f.path))
        except OSError:
            continue
    r = os.path.join(RUN, "reserve")
    for n in os.listdir(r) if os.path.isdir(r) else []:
        owner, _, pid = n.partition("-")
        if owner != str(uid):
            continue
        try:
            os.kill(int(pid), 0)
            with open(os.path.join(r, n)) as fh:
                total += int(fh.read().strip() or 0)
        except (ValueError, ProcessLookupError):
            # Its server process is gone, so nothing is being written for it.
            os.unlink(os.path.join(r, n))
        except OSError:
            continue
    return total


def check_quota(uid, user, cpus, memory_mb, disk_gb, exclude=None, vms=1):
    limits = limits_for(user)
    mine = [e for n, e in registry_all().items() if e.get("owner_uid") == str(uid) and n != exclude]
    backups = gib(backup_bytes(uid))
    used = {
        "vms": len(mine),
        "vcpus": sum(int(e.get("cpus", "0") or 0) for e in mine),
        "memory_mb": sum(int(e.get("memory_mb", "0") or 0) for e in mine),
        "disk_gb": sum(int(e.get("disk_gb", "0") or 0) for e in mine) + backups,
    }
    want = {"vms": vms, "vcpus": cpus, "memory_mb": memory_mb, "disk_gb": disk_gb}
    names = {"vms": "VM", "vcpus": "vCPU", "memory_mb": "memory (MB)", "disk_gb": "disk (GB)"}
    for k, n in want.items():
        if used[k] + n > limits[k]:
            of = " (%d of it backups: dcvm backup delete <vm>)" % backups if k == "disk_gb" and backups else ""
            raise Denied("over your %s quota: %d used%s + %d requested > %d (ask an admin to raise it in %s)"
                         % (names[k], used[k], of, n, limits[k], LIMITS))
    # Backups hold part of the disk quota, so the module's own checks see only what is left for VMs.
    return "%d %d %d" % (limits["vcpus"], limits["memory_mb"], max(0, limits["disk_gb"] - backups))


def take_value(args, i, opt):
    a = args[i]
    if a.startswith(opt + "="):
        return a.split("=", 1)[1], i
    if i + 1 >= len(args):
        raise Denied("%s needs a value" % opt)
    return args[i + 1], i + 1


def own_vm(ctx, vm):
    if not NAME.match(vm) or vm in RESERVED:
        raise Denied("invalid VM name: %s" % vm)
    if (not vm_exists(vm) and registry_read(vm) is None) or owner_of(vm) != ctx["uid"]:
        raise Denied("you have no VM named %s" % vm)
    return vm


def new_vm_name(vm):
    if "," in vm:
        raise Denied("create one VM per command")
    if not NAME.match(vm) or vm in RESERVED:
        raise Denied("invalid VM name: %s (3-64 letters, digits, - or _, not starting with -)" % vm)
    return vm


CREATE_FLAGS = {"-f", "--force", "--enable-root", "--disable-root", "--with-ssh-key", "--without-ssh-key",
                "--json", "--wait", "--uefi"}
ISO_FLAGS = {"-f", "--force", "--json", "--wait", "--uefi"}
CLOUD_INIT_ONLY = {"-k", "--packages", "--enable-root", "--disable-root", "--with-ssh-key", "--without-ssh-key"}


def parse_create(ctx, args, iso_mode):
    out, vm, i = [], None, 0
    cpus, memory, disk = 2, 2048, 20 if iso_mode else 30
    disk_given = os_given = False
    while i < len(args):
        a = args[i]
        opt = a.split("=", 1)[0]
        if a in CREATE_FLAGS and (not iso_mode or a in ISO_FLAGS):
            out.append(a)
        elif iso_mode and opt in CLOUD_INIT_ONLY:
            raise Denied("%s does nothing with an ISO: the installer sets up the OS" % opt)
        elif opt in ("-m", "--memory"):
            v, i = take_value(args, i, opt)
            if not v.isdigit() or not 512 <= int(v) <= 1048576:
                raise Denied("--memory must be MB between 512 and 1048576")
            memory = int(v)
            out += ["-m", v]
        elif opt in ("-c", "--cpus"):
            v, i = take_value(args, i, opt)
            if not v.isdigit() or not 1 <= int(v) <= 256:
                raise Denied("--cpus must be a number between 1 and 256")
            cpus = int(v)
            out += ["-c", v]
        elif opt in ("-d", "--disk"):
            v, i = take_value(args, i, opt)
            if not SIZE.match(v):
                raise Denied("--disk must look like %s" % ("20G" if iso_mode else "30G"))
            if v.upper().endswith("T") and int(v[:-1]) > 10:
                raise Denied("--disk is at most 10T")
            disk, disk_given = size_gb(v, disk), True
            out += ["-d", v.upper()]
        elif opt in ("-u", "--username"):
            v, i = take_value(args, i, opt)
            if not USERNAME.match(v):
                raise Denied("invalid --username")
            out += ["-u", v]
        elif opt in ("-k", "--packages") and not iso_mode:
            v, i = take_value(args, i, opt)
            pkgs = ",".join(p.strip() for p in v.split(",") if p.strip())
            if not PACKAGES.match(pkgs):
                raise Denied("invalid package list: separate packages with commas, e.g. -k nginx,curl")
            out += ["-k", pkgs]
        elif opt == "--ip":
            v, i = take_value(args, i, opt)
            if not IPV4.match(v):
                raise Denied("invalid --ip")
            out += ["--ip", v]
        elif opt == "--graphics":
            v, i = take_value(args, i, opt)
            if v not in ("none", "vnc", "spice"):
                raise Denied("--graphics must be none, vnc or spice")
            out += ["--graphics", v]
        elif opt == "--ttl":
            v, i = take_value(args, i, opt)
            m = TTL.match(v)
            if not m:
                raise Denied("--ttl must look like 90m, 2h or 3d")
            if int(m.group(1)) * {"m": 60, "h": 3600, "d": 86400}[m.group(2)] > MAX_TTL_DAYS * 86400:
                raise Denied("--ttl is at most %dd" % MAX_TTL_DAYS)
            out += ["--ttl", v]
        elif opt in ("-o", "--os") and not iso_mode:
            if os_given:
                raise Denied("give -o once")
            os_given = True
            v, i = take_value(args, i, opt)
            if v.startswith("fd:"):
                ctx["iso_fd"] = fd_ref(ctx, v)
            elif not re.match(r"^[1-9]\Z", v):
                raise Denied("--os must be 1-9, or an ISO file")
            else:
                out += ["-o", v]
        elif opt in ("--iso", "-o") and iso_mode:
            v, i = take_value(args, i, opt)
            if not v.startswith("fd:"):
                raise Denied("pass the ISO as a file")
            ctx["iso_fd"] = fd_ref(ctx, v)
        elif opt == "--boot" and iso_mode:
            v, i = take_value(args, i, opt)
            if v not in ("cdrom,hd", "hd,cdrom", "cdrom", "hd"):
                raise Denied("--boot must be cdrom,hd or hd,cdrom")
            out += ["--boot", v]
        elif opt == "--os-variant" and iso_mode:
            v, i = take_value(args, i, opt)
            if not OS_VARIANT.match(v):
                raise Denied("invalid --os-variant")
            out += ["--os-variant", v]
        elif a.startswith("-"):
            raise Denied("option not allowed: %s" % redact([opt])[0])
        elif vm is None:
            vm = new_vm_name(a)
        else:
            raise Denied("unexpected argument: %s" % a)
        i += 1
    if vm is None:
        raise Denied("VM name required")
    if ctx.get("iso_fd") is not None:
        out = (["--iso"] if iso_mode else ["-o"]) + ["@ISO@"] + out
        if not disk_given:
            disk = 20
        # The staged copy stays in the VM's folder, so it counts against the disk quota too.
        ctx["iso_bytes"] = os.fstat(ctx["iso_fd"]).st_size
        ctx["iso_gb"] = -(-ctx["iso_bytes"] // 1024 ** 3)
        disk += ctx["iso_gb"]
    check_quota(ctx["uid"], ctx["user"], cpus, memory, disk)
    ctx.update(vm=vm, new_vm=True, mutating=True, quota=(cpus, memory, disk))
    return [vm] + out


def fd_ref(ctx, value):
    try:
        n = int(value[3:])
        return ctx["files"][n]
    except (ValueError, IndexError, KeyError):
        raise Denied("bad file reference")


def decide_user(ctx, argv):
    if not argv:
        raise Denied("no command")
    for a in argv:
        if a == "--":
            break
        if a in ("-h", "--help"):
            raise Denied("help is shown by your dcvm command itself: dcvm %s --help" % argv[0])
    cmd, args = argv[0], argv[1:]
    json_flag = [a for a in args if a == "--json"]
    plain = [a for a in args if a != "--json"]

    if cmd in ("list",) and not plain:
        return argv
    if cmd == "status" and not plain:
        return argv
    if cmd == "info" and len(plain) == 1:
        own_vm(ctx, plain[0])
        return [cmd] + plain + json_flag
    if cmd in ("start", "stop", "restart"):
        force = ["--force"] if cmd == "stop" and "--force" in plain else []
        every = "--all" in plain
        plain = [a for a in plain if a not in force and a != "--all"]
        if len(plain) + every != 1:
            raise Denied("%s takes one VM, or --all for every VM of yours" % cmd)
        if force and every:
            raise Denied("stop --force takes one VM")
        if plain:
            own_vm(ctx, plain[0])
            ctx["vm"] = plain[0]
        ctx["mutating"] = True
        return [cmd] + (plain or ["--all"]) + force
    if cmd == "console":
        if len(plain) == 1:
            own_vm(ctx, plain[0])
            ctx["interactive"] = True
        elif plain:
            raise Denied("console takes one VM")
        return argv
    if cmd == "create":
        ctx["interactive"] = True
        return ["create"] + parse_create(ctx, args, iso_mode=False)
    if cmd == "create-iso":
        ctx["interactive"] = True
        return ["create-iso"] + parse_create(ctx, args, iso_mode=True)
    if cmd == "delete":
        rest = [a for a in plain if a not in ("-y", "--yes")]
        if len(rest) != 1 or rest[0].startswith("-"):
            raise Denied("delete takes one VM")
        if ctx["origin"] != "terminal" and len(rest) == len(plain):
            raise Denied("deleting without a terminal needs --yes")
        own_vm(ctx, rest[0])
        protected(rest[0])
        ctx.update(vm=rest[0], mutating=True)
        return ["delete", rest[0]]
    if cmd in ("protect", "unprotect") and len(plain) == 1:
        own_vm(ctx, plain[0])
        ctx.update(vm=plain[0], mutating=True)
        return [cmd] + plain
    if cmd == "fix-lock":
        rest = [a for a in plain if a != "--verbose"]
        if len(rest) == 1 and not rest[0].startswith("-"):
            own_vm(ctx, rest[0])
            ctx.update(vm=rest[0], mutating=True)
            return [cmd] + rest + (["--verbose"] if len(rest) < len(plain) else [])
    if cmd == "template" and plain[:1] in (["list"], ["status"], []):
        return argv
    if cmd == "network" and plain[:2] == ["ports", "show"] and len(plain) == 2:
        return argv
    if cmd == "network" and plain[:1] == ["ports"] and len(plain) == 3 and plain[1] in ("add", "remove"):
        own_vm(ctx, plain[2])
        ctx.update(vm=plain[2], mutating=True)
        return argv
    if cmd == "network" and plain[:1] == ["vnc"] and len(plain) == 3 and plain[1] in ("enable", "disable", "status"):
        own_vm(ctx, plain[2])
        # enable/disable offer to stop a running VM, which needs the user's terminal.
        ctx.update(vm=plain[2], mutating=plain[1] != "status", interactive=plain[1] != "status")
        return argv
    if cmd == "restore":
        return decide_backup(ctx, ["restore"] + args)
    if cmd == "backup":
        return decide_backup(ctx, args)
    if cmd == "whoami":
        return argv
    refuse(argv)


# Every command the dcvm script routes, so a typo is told apart from an admin's command.
COMMANDS = {"create", "create-iso", "delete", "list", "status", "start", "stop", "restart", "console", "network",
            "backup", "restore", "storage", "storage-cleanup", "template", "mirror", "fix-lock", "info", "whoami",
            "protect", "unprotect", "reap", "user", "owner", "doctor", "self-update", "update", "uninstall"}
TEMPLATE_SUBS = {"list", "check", "best", "download", "status", "verify"}
SUBCOMMANDS = {
    "network": {"show", "info", "status", "start", "stop", "restart", "leases", "bridge", "ip-forwarding", "ipfwd",
                "config", "ports", "dhcp", "vnc"},
    "network ports": {"setup", "show", "add", "remove", "rules", "apply", "clear", "test"},
    "network dhcp": {"show", "clear", "cleanup", "renew", "files"},
    "template": TEMPLATE_SUBS,
    "mirror": TEMPLATE_SUBS,
    "backup": {"create", "list", "delete", "restore", "export", "import", "ssh-setup", "troubleshoot"},
}
USAGE = {
    "list": "dcvm list [--json]",
    "status": "dcvm status (one VM: dcvm info <vm>)",
    "info": "dcvm info <vm> [--json]",
    "protect": "dcvm protect <vm>",
    "unprotect": "dcvm unprotect <vm>",
    "fix-lock": "dcvm fix-lock <vm> [--verbose]",
    "network ports add": "dcvm network ports add <vm>",
    "network ports remove": "dcvm network ports remove <vm>",
    "network ports show": "dcvm network ports show",
    "network vnc": "dcvm network vnc enable|disable|status <vm>",
    "backup create": "dcvm backup create <vm>",
    "backup list": "dcvm backup list [vm]",
    "backup delete": "dcvm backup delete <vm> [dd.mm.yyyy[-N|-HH:MM:SS]|latest]",
    "backup restore": "dcvm backup restore <vm> [id] [new-name]",
    "backup export": "dcvm backup export <vm> [id|latest] [folder] [--full]",
}


def refuse(argv):
    key, rest = argv[0], argv[1:]
    if key not in COMMANDS:
        raise Denied("unknown command: %s (see dcvm help)" % key)
    while key in SUBCOMMANDS and rest and not rest[0].startswith("-"):
        if rest[0] not in SUBCOMMANDS[key]:
            raise Denied("unknown command: dcvm %s %s (see dcvm %s --help)" % (key, rest[0], key))
        key, rest = key + " " + rest[0], rest[1:]
    if key in USAGE:
        raise Denied("usage: %s" % USAGE[key])
    raise Denied("'%s' needs a dcvm admin" % key)


def decide_backup(ctx, args):
    if not args:
        raise Denied("backup needs a command")
    sub, rest = args[0], args[1:]
    yes = []
    if sub in ("delete", "restore") and {"-y", "--yes"} & set(rest):
        yes, rest = ["--yes"], [a for a in rest if a not in ("-y", "--yes")]
    if sub == "create" and len(rest) == 1:
        own_vm(ctx, rest[0])
        # A backup is never larger than the disk's allocated blocks; that much is charged before it is written.
        try:
            need = os.stat(os.path.join(read_config()["DATACENTER_BASE"], "vms", rest[0], rest[0] + "-disk.qcow2")).st_blocks * 512
        except OSError:
            need = 0
        check_quota(ctx["uid"], ctx["user"], 0, 0, gib(need), vms=0)
        ctx.update(vm=rest[0], mutating=True, interactive=True, backup_need=need)
        return ["backup", "create", rest[0]]
    if sub == "list" and len(rest) <= 1:
        if rest:
            check_backup_vm(ctx, rest[0])
        return ["backup", "list"] + rest
    if sub == "delete" and len(rest) in (1, 2):
        day = r"[0-9]{2}\.[0-9]{2}\.[0-9]{4}(-([0-9]+|[0-9]{2}:[0-9]{2}:[0-9]{2}))?"
        if len(rest) == 1:
            # Split with the module's own greedy regex for <vm>-<id>, so both name the same backup.
            m = re.match(r"^(.+)-([0-9]{8}_[0-9]{6}|latest|%s)\Z" % day, rest[0])
            if m:
                vm, bid = m.group(1), m.group(2)
            elif NAME.match(rest[0]):
                # A VM name alone: the module lists its backups and asks which to delete.
                vm, bid = rest[0], None
                ctx["interactive"] = True
            else:
                raise Denied("usage: %s" % USAGE["backup delete"])
        else:
            vm, bid = rest[0], strip_vm(rest[0], rest[1])
        if bid is not None:
            t = re.match(r"^([0-9]{4})([0-9]{2})([0-9]{2})_([0-9]{2})([0-9]{2})([0-9]{2})\Z", bid)
            if t:
                bid = "%s.%s.%s-%s:%s:%s" % (t.group(3), t.group(2), t.group(1), t.group(4), t.group(5), t.group(6))
            if bid != "latest" and not re.match(r"^%s\Z" % day, bid):
                raise Denied("usage: %s" % USAGE["backup delete"])
        check_backup_vm(ctx, vm)
        backup_lock(ctx, vm)
        ctx["mutating"] = True
        return ["backup", "delete", vm] + ([] if bid is None else [bid])
    if sub == "restore" and 1 <= len(rest) <= 3:
        check_backup_vm(ctx, rest[0])
        rest = rest[:1] + [strip_vm(rest[0], a) for a in rest[1:2]] + rest[2:]
        if len(rest) >= 2 and not BACKUP_ID.match(rest[1]):
            raise Denied("invalid backup id")
        if len(rest) == 3:
            target = new_vm_name(rest[2])
            # Only the backup knows its size: the module checks and records it under the global lock.
            check_quota(ctx["uid"], ctx["user"], 0, 0, 0)
            ctx.update(vm=target, new_vm=True, quota=(0, 0, 0))
        else:
            own_vm(ctx, rest[0])
            protected(rest[0])
            # The restore replaces the VM's own charge, so a backup of the same size always fits.
            ctx.update(vm=rest[0], quota_limits=check_quota(ctx["uid"], ctx["user"], 0, 0, 0, exclude=rest[0]))
        ctx.update(mutating=True, interactive=True)
        return ["backup", "restore"] + rest + yes
    if sub == "export" and 1 <= len(rest) - rest.count("--full") <= 3:
        full = ["--full"] if "--full" in rest else []
        rest = [a for a in rest if a != "--full"]
        check_backup_vm(ctx, rest[0])
        rest = rest[:1] + [strip_vm(rest[0], a) for a in rest[1:2]] + rest[2:]
        if len(rest) >= 2 and not rest[1].startswith("fd:") and not BACKUP_ID.match(rest[1]):
            raise Denied("invalid backup id")
        if not rest[-1].startswith("fd:") or any(a.startswith("fd:") for a in rest[:-1]):
            raise Denied("export writes to a file you pass")
        ctx["export_fd"] = export_fd(ctx, fd_ref(ctx, rest[-1]))
        # Not mutating: a client that goes away cancels the export.
        backup_lock(ctx, rest[0])
        return ["backup", "export"] + [a for a in rest if not a.startswith("fd:")] + full
    refuse(["backup"] + args)


def backup_lock(ctx, vm):
    # A stale backup of a name now owned by someone else must not take that VM's lock.
    owns = registry_read(vm) is not None and owner_of(vm) == ctx["uid"]
    ctx.update(vm=vm, lock=None if owns else "backup-%d-%s" % (ctx["uid"], vm))


def export_fd(ctx, fd):
    # Root writes the package through this descriptor, so only the caller's own write access may count.
    flags = fcntl.fcntl(fd, fcntl.F_GETFL)
    if not stat.S_ISREG(os.fstat(fd).st_mode) or flags & getattr(os, "O_PATH", 0) or (flags & os.O_ACCMODE) not in (os.O_WRONLY, os.O_RDWR):
        raise Denied("export writes to a regular file you opened for writing")
    # dcvm's own messages would be written into the archive.
    if any(os.path.samestat(os.fstat(fd), os.fstat(o)) for o in ctx.get("output_fds", ())):
        raise Denied("export cannot write to the file your output goes to")
    return fd


def strip_vm(vm, bid):
    return bid[len(vm) + 1:] if bid.startswith(vm + "-") else bid


def check_backup_vm(ctx, vm):
    if not NAME.match(vm) or vm in RESERVED:
        raise Denied("invalid VM name: %s" % vm)
    base = read_config()["DATACENTER_BASE"]
    own = re.compile(re.escape(vm) + r"-[0-9]{8}_[0-9]{6}\Z")
    folders = [f for f in os.listdir(os.path.join(base, "backups")) if own.match(f)] if os.path.isdir(os.path.join(base, "backups")) else []
    for f in folders:
        try:
            with open(os.path.join(base, "backups", f, "owner")) as fh:
                if fh.read().strip() != str(ctx["uid"]):
                    continue
        except OSError:
            continue
        return
    if registry_read(vm) and owner_of(vm) == ctx["uid"]:
        return
    raise Denied("no backups of %s that are yours" % vm)


def protected(vm):
    entry = registry_read(vm) or {}
    if entry.get("protected") == "1":
        raise Denied("%s is protected: dcvm unprotect %s first" % (vm, vm))


def module_env_base():
    return {"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "HOME": "/root", "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8",
            "LIBVIRT_DEFAULT_URI": "qemu:///system"}


def module_env(ctx, req):
    env = module_env_base()
    term = req.get("term") or "dumb"
    env["TERM"] = term if TERM.match(term) else "dumb"
    cols = req.get("cols")
    if isinstance(cols, int) and 20 <= cols <= 1000:
        env["UI_COLS"] = str(cols)
    env["DCVM_CALLER_UID"] = str(ctx["uid"])
    env["DCVM_CALLER_USER"] = ctx["user"]
    env["DCVM_CALLER_ROLE"] = ctx["role"]
    env["DCVM_ORIGIN"] = ctx["origin"]
    if ctx.get("quota_limits"):
        env["DCVM_QUOTA_LIMITS"] = ctx["quota_limits"]
    return env


def stage_iso(ctx, fd, vm):
    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode):
        raise Denied("the ISO must be a regular file")
    if st.st_size > MAX_ISO:
        raise Denied("the ISO is larger than 16 GB")
    if st.st_size > ctx.get("iso_bytes", st.st_size):
        raise Denied("the ISO changed while it was being copied")
    base = read_config()["DATACENTER_BASE"]
    vm_dir = os.path.join(base, "vms", vm)
    # Users' names were checked when reserved; anyone else must not stage into (or later remove) a folder in use.
    if not ctx.get("reserved") and (vm_exists(vm) or os.path.lexists(vm_dir)):
        raise Denied("VM %s already exists (or %s is left over)" % (vm, vm_dir))
    fs = os.statvfs(base)
    if fs.f_bavail * fs.f_frsize < st.st_size + 2 * 1024 ** 3:
        raise Denied("not enough free space in %s for the ISO (and 2 GB to spare); ask an admin" % base)
    vm_dir = os.path.join(base, "vms", vm)
    os.makedirs(vm_dir, mode=0o711, exist_ok=True)
    os.chmod(vm_dir, 0o711)
    dest = os.path.join(vm_dir, "installer.iso")
    out = os.open(dest + ".part", os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    try:
        os.lseek(fd, 0, os.SEEK_SET)
        copied = 0
        while True:
            chunk = os.read(fd, 4 * 1024 * 1024)
            if not chunk:
                break
            copied += len(chunk)
            # The caller's file may grow after the size check.
            if copied > st.st_size:
                raise Denied("the ISO changed while it was being copied")
            view = memoryview(chunk)
            while view:
                view = view[os.write(out, view):]
        if copied != st.st_size:
            raise Denied("the ISO changed while it was being copied")
    except BaseException:
        os.unlink(dest + ".part")
        raise
    finally:
        os.close(out)
    os.replace(dest + ".part", dest)
    ctx["staged_dir"] = vm_dir
    return dest


def clip(text, n=200):
    return text if len(text) <= n else "%s…(%d bytes)" % (text[:n], len(text.encode(errors="replace")))


def audit(ctx, argv, decision, rc=None, reason=None, started=None):
    shown = "<malformed>"
    if isinstance(argv, list):
        shown = [clip(a) for a in redact(argv[:64])] + (["…(%d more)" % (len(argv) - 64)] if len(argv) > 64 else [])
    rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "uid": ctx.get("uid"), "user": ctx.get("user"),
           "role": ctx.get("role"), "origin": ctx.get("origin"), "pid": ctx.get("pid"),
           "argv": shown, "decision": decision}
    if rc is not None:
        rec["exit"] = rc
    if reason:
        rec["reason"] = clip(redact_text(reason, argv) if isinstance(argv, list) else reason)
    if started:
        rec["seconds"] = round(time.time() - started, 1)
    line = json.dumps(rec, ensure_ascii=True)
    try:
        os.makedirs(os.path.dirname(AUDIT), mode=0o750, exist_ok=True)
        fd = os.open(AUDIT, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o640)
        os.write(fd, (line + "\n").encode())
        os.close(fd)
    except OSError:
        pass
    print(line, file=sys.stderr, flush=True)


def take_slot(uid):
    d = os.path.join(RUN, "conn")
    os.makedirs(d, mode=0o700, exist_ok=True)
    for n in range(MAX_PER_UID):
        fd = os.open(os.path.join(d, "%d-%d" % (uid, n)), os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except BlockingIOError:
            os.close(fd)
    raise Denied("you already have %d dcvm commands running; wait for one to finish" % MAX_PER_UID)


def recv_request(conn):
    # One deadline for the whole request: a client trickling bytes must not hold its slot.
    deadline = time.monotonic() + REQUEST_TIMEOUT
    data, fds = b"", []
    while len(data) < 4 or len(data) < 4 + struct.unpack(">I", data[:4])[0]:
        left = deadline - time.monotonic()
        if left <= 0:
            raise Denied("the request took too long to arrive")
        conn.settimeout(left)
        try:
            msg, anc, flags, _ = conn.recvmsg(65536, socket.CMSG_SPACE(MAX_FDS * 4))
        except socket.timeout:
            raise Denied("the request took too long to arrive")
        for level, kind, payload in anc:
            if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                fds += list(struct.unpack("%di" % (len(payload) // 4), payload[: len(payload) - len(payload) % 4]))
        if flags & socket.MSG_CTRUNC:
            raise Denied("too many files passed")
        if not msg:
            raise Denied("connection closed")
        data += msg
        if len(data) >= 4 and struct.unpack(">I", data[:4])[0] > MAX_REQUEST:
            raise Denied("request too large")
    length = struct.unpack(">I", data[:4])[0]
    if len(data) != 4 + length:
        raise Denied("malformed request")
    try:
        req = json.loads(data[4:].decode())
    except (ValueError, RecursionError):
        raise Denied("malformed request")
    # True == 1 in Python, so the type is checked too.
    if not isinstance(req, dict) or type(req.get("v")) is not int or req["v"] != PROTOCOL:
        raise Denied("this dcvm client and server don't match; update dcvm")
    return req, fds


def send(conn, obj):
    data = json.dumps(obj).encode()
    try:
        conn.settimeout(10)
        conn.sendall(struct.pack(">I", len(data)) + data)
    except OSError:
        pass


def say(fd, text):
    """True once the caller's descriptor took the message."""
    if fd is None:
        return False
    return write_some(fd, ("\033[0;31m✗\033[0m %s\n" % text if os.isatty(fd) else "error: %s\n" % text).encode()) is not None


WRITING = False


def _alarm(_sig, _frame):
    # A late alarm must not raise in whatever code runs after the write.
    if WRITING:
        raise TimeoutError


def write_some(fd, data):
    # The caller's descriptor stays blocking (its flags are shared with the caller), so an alarm bounds a stuck write.
    global WRITING
    signal.signal(signal.SIGALRM, _alarm)
    signal.setitimer(signal.ITIMER_REAL, WRITE_TIMEOUT)
    try:
        try:
            WRITING = True
            return os.write(fd, data[:4096])
        finally:
            WRITING = False
    except OSError:
        return None
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)


def run_module(ctx, conn, argv, req, fds):
    env = module_env(ctx, req)
    stdin = subprocess.DEVNULL
    if ctx.get("interactive") and fds.get("stdin") is not None and os.isatty(fds["stdin"]):
        stdin = fds["stdin"]
    pass_fds = []
    secrets = req.get("secrets") or {}
    if secrets:
        r, w = os.pipe()
        for k in ("password", "root_password", "tailscale_authkey"):
            v = secrets.get(k)
            if isinstance(v, str) and v and "\n" not in v and len(v) <= 4096:
                os.write(w, ("%s=%s\n" % (k, v)).encode())
        os.close(w)
        env["DCVM_SECRETS_FD"] = str(r)
        pass_fds.append(r)
    if ctx.get("pubkey_file"):
        env["DCVM_SSH_PUBKEY_FILE"] = ctx["pubkey_file"]
    if ctx.get("export_fd") is not None:
        env["DCVM_EXPORT_FD"] = str(ctx["export_fd"])
        pass_fds.append(ctx["export_fd"])
    pass_fds += ctx.get("keep_fds", [])
    if DRY_RUN:
        shown = {k: v for k, v in env.items() if k.startswith("DCVM_") and k != "DCVM_SECRETS_FD"}
        out = json.dumps({"argv": argv, "env": shown, "stdin_tty": stdin is not subprocess.DEVNULL,
                          "secrets": sorted(k for k in secrets if secrets.get(k))})
        os.write(fds.get("stdout", 1), (out + "\n").encode())
        return 0
    # The module writes to us, never to a caller's descriptor that could stall it while it holds locks;
    # only an interactive terminal is handed over as it is.
    child, outs = {}, []
    for name in ("stdout", "stderr"):
        fd = fds.get(name)
        if fd is None or (stdin is not subprocess.DEVNULL and os.isatty(fd)):
            child[name] = fd
            continue
        if os.isatty(fd):
            # A pty of our own keeps colours and progress lines for a terminal.
            r, w = os.openpty()
            attrs = termios.tcgetattr(w)
            attrs[1] &= ~termios.OPOST
            termios.tcsetattr(w, termios.TCSANOW, attrs)
        else:
            r, w = os.pipe()
        child[name] = w
        outs.append([r, fd, bytearray()])
    proc = subprocess.Popen([DCVM] + argv, env=env, stdin=stdin, stdout=child["stdout"],
                            stderr=child["stderr"], pass_fds=pass_fds, start_new_session=True, close_fds=True)
    ctx["proc"] = proc
    for fd in pass_fds:
        if fd != ctx.get("export_fd") and fd not in ctx.get("keep_fds", []):
            os.close(fd)
    for name, fd in child.items():
        if fd is not None and fd != fds.get(name):
            os.close(fd)
    cancelled, ended, wrote, escalate = False, None, 0, []
    while True:
        if ended is None and proc.poll() is not None:
            ended = time.monotonic()
        while ended is None and escalate and time.monotonic() >= escalate[0][0]:
            signal_group(proc, escalate.pop(0)[1])
        if ended is not None:
            now = time.monotonic()
            for o in outs:
                # Background children may keep the pipes open; what they write after the module ends is dropped.
                if o[0] is not None and now > ended + 2:
                    os.close(o[0])
                    o[0] = None
            # What is left goes to a caller that keeps reading (a pager may pause); with a VM's lock held, briefly.
            if not any(o[0] is not None or o[2] for o in outs) or now > max(ended, wrote) + (2 if ctx.get("vm") else 60):
                break
        reads = [o[0] for o in outs if o[0] is not None] + ([] if cancelled else [conn])
        try:
            ready, writable, _ = select.select(reads, [o[1] for o in outs if o[2]], [], 0.5)
        except (OSError, ValueError):
            ready, writable = [], []
            time.sleep(0.5)
        for o in outs:
            if o[0] in ready:
                try:
                    data = os.read(o[0], 65536)
                except OSError:
                    data = b""
                if not data:
                    os.close(o[0])
                    o[0] = None
                elif o[1] is not None and len(o[2]) < MAX_PENDING:
                    o[2] += data
            if o[2] and o[1] in writable:
                n = write_some(o[1], o[2])
                if n is None:
                    o[1] = None
                    o[2].clear()
                else:
                    del o[2][:n]
                    wrote = time.monotonic()
        if conn in ready:
            try:
                data = conn.recv(64)
            except OSError:
                data = b""
            if not data:
                cancelled = True
                if not ctx.get("mutating"):
                    signal_group(proc, signal.SIGTERM)
                    try:
                        proc.wait(5)
                    except subprocess.TimeoutExpired:
                        signal_group(proc, signal.SIGKILL)
                elif stdin is not subprocess.DEVNULL:
                    # It reads the caller's terminal, which is the shell's again: pass on the Ctrl-C it never got.
                    signal_group(proc, signal.SIGINT)
                    now = time.monotonic()
                    escalate = [(now + CANCEL_GRACE, signal.SIGTERM), (now + CANCEL_GRACE + 5, signal.SIGKILL)]
    for o in outs:
        if o[0] is not None:
            os.close(o[0])
    rc = proc.wait()
    # A signal death is -N here; callers expect the shell's 128+N.
    return 128 - rc if rc < 0 else rc


def signal_group(proc, sig):
    try:
        os.killpg(proc.pid, sig)
    except ProcessLookupError:
        pass


def handle(conn):
    ctx = {"origin": "unknown"}
    started = time.time()
    req, files, argv = {}, [], []
    try:
        pid, uid, _gid = struct.unpack("3i", conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))
        ctx.update(uid=uid, pid=pid, user=user_name(uid), role=role_of(uid))
        if ctx["role"] is None:
            raise Denied("you are not in the %s group; ask an admin: sudo dcvm user add %s" % (USER_GROUP, ctx["user"]))
        if ctx["role"] == "user":
            ctx["slot"] = take_slot(uid)
        req, files = recv_request(conn)
        if len(files) > MAX_FDS:
            raise Denied("too many files passed")
        fdmap = {}
        for name in ("stdin", "stdout", "stderr"):
            i = req.get(name)
            if isinstance(i, int) and 0 <= i < len(files):
                fdmap[name] = files[i]
        ctx["files"] = {i: fd for i, fd in enumerate(files)}
        ctx["output_fds"] = [fdmap[n] for n in ("stdout", "stderr") if n in fdmap]
        # A client may say "agent" on a terminal, never "terminal" without one.
        ttys = all(fdmap.get(n) is not None and os.isatty(fdmap[n]) for n in ("stdin", "stdout"))
        ctx["origin"] = "terminal" if req.get("origin") == "terminal" and ttys else "agent"
        argv = req.get("argv")
        if not isinstance(argv, list) or not all(isinstance(a, str) and len(a) <= 4096 for a in argv) or len(argv) > 64:
            raise Denied("malformed request")
        if ctx["role"] == "user":
            final = decide_user(ctx, argv)
        else:
            final = admin_argv(ctx, argv)
        # Logged before the module runs, so a request killed midway still leaves a trace.
        audit(ctx, argv, "start")
        rc = execute(ctx, conn, final, req, fdmap)
        audit(ctx, argv, "allow", rc=rc, started=started)
        send(conn, {"exit": rc})
    except Denied as e:
        err = fdmap_get(req, files, "stderr")
        shown = say(err, redact_text(str(e), argv) if isinstance(argv, list) else str(e))
        audit(ctx, argv, "deny", reason=str(e), started=started)
        # Refused before the request was read, or its stderr can't be written: only the client can show the reason.
        send(conn, {"exit": 77, "error": str(e), "show": not shown})
    except Exception as e:
        audit(ctx, argv, "error", reason=str(e), started=started)
        send(conn, {"exit": 70, "error": "dcvm server: %s" % e})


def fdmap_get(req, files, name):
    i = req.get(name) if isinstance(req, dict) else None
    return files[i] if isinstance(i, int) and 0 <= i < len(files) else None


def admin_argv(ctx, argv):
    final = list(argv)
    for i, a in enumerate(final):
        if a.startswith("fd:"):
            fd = fd_ref(ctx, a)
            st = os.fstat(fd)
            if stat.S_ISREG(st.st_mode) and final[0] in ("create", "create-iso") and i > 0 and final[i - 1] in ("-o", "--os", "--iso"):
                ctx["iso_fd"] = fd
                final[i] = "@ISO@"
            elif final[:2] == ["backup", "export"]:
                ctx["export_fd"] = export_fd(ctx, fd)
                final[i] = None
            elif final[:2] == ["backup", "import"] or final[0] == "import":
                # Root reopens it by path, so only a file the caller opened for reading may count.
                flags = fcntl.fcntl(fd, fcntl.F_GETFL)
                if not stat.S_ISREG(st.st_mode) or flags & getattr(os, "O_PATH", 0) or (flags & os.O_ACCMODE) == os.O_WRONLY:
                    raise Denied("import reads a regular file you opened for reading")
                final[i] = "/proc/self/fd/%d" % fd
                ctx.setdefault("keep_fds", []).append(fd)
            else:
                raise Denied("unexpected file argument")
    final = [a for a in final if a is not None]
    vms = admin_vms(final)
    if vms:
        ctx.update(vm=vms[0], vms=vms, new_vm=final[0] in ("create", "create-iso"))
    ctx["mutating"] = True
    ctx["interactive"] = True
    return final


def admin_vms(argv):
    """The VMs an admin's command changes, so it waits for the same per-VM locks as a user's."""
    pos = [a for i, a in enumerate(argv) if not a.startswith("-") and (i == 0 or argv[i - 1] != "--base")]
    names = []
    if argv[:1] in (["create"], ["create-iso"]) and len(argv) > 1 and not argv[1].startswith("-"):
        names = argv[1].split(",")
    elif pos[:1] in (["delete"], ["owner"], ["protect"], ["unprotect"], ["start"], ["stop"], ["restart"], ["fix-lock"]):
        names = pos[1:2]
    elif pos[:2] == ["backup", "create"]:
        names = pos[2:3]
    elif pos[:1] == ["restore"] or pos[:2] == ["backup", "restore"]:
        rest = pos[1:] if pos[0] == "restore" else pos[2:]
        names = rest[2:3] or rest[:1]
    elif pos[:2] == ["backup", "import"]:
        # ponytail: without a new name the target is named inside the archive; only the restore's staging is then per-process.
        names = pos[3:4]
    elif pos[:2] == ["network", "ports"] and pos[2:3] in (["add"], ["remove"]) or pos[:2] == ["network", "vnc"] and pos[2:3] in (["enable"], ["disable"]):
        names = pos[3:4]
    return [n for n in dict.fromkeys(n.strip() for n in names) if NAME.match(n) and n not in RESERVED]


def name_taken(vm):
    vm_dir = os.path.join(read_config()["DATACENTER_BASE"], "vms", vm)
    if vm_exists(vm) or registry_read(vm) is not None or os.path.lexists(vm_dir):
        raise Denied("the name %s is taken" % vm)
    return vm_dir


def execute(ctx, conn, argv, req, fds):
    vm = ctx.get("vm")
    held = []
    reserve = ctx.get("new_vm") and vm and ctx["role"] == "user"
    try:
        if reserve:
            # Before the VM's lock too, so asking for a taken name never holds up its owner.
            name_taken(vm)
        if vm:
            # Sorted, so two commands naming the same VMs can't each hold one the other waits for.
            for name in [ctx["lock"]] if ctx.get("lock") else ["vm-" + n for n in sorted(ctx.get("vms") or [vm])]:
                held.append(lock(name))
        if ctx["role"] == "user" and vm and not ctx.get("new_vm"):
            # The policy ran before the lock; a request that waited must not act on a VM that changed hands meanwhile.
            again = {k: ctx[k] for k in ("uid", "user", "role", "origin", "files")}
            decide_user(again, req["argv"])
            if again.get("lock") != ctx.get("lock"):
                raise Denied("%s changed while this command waited; run it again" % vm)
        if ctx.get("backup_need") is not None:
            # Checked and reserved under the global lock: two backups can't both fit in the same free quota.
            held.append(lock("global"))
            check_quota(ctx["uid"], ctx["user"], 0, 0, gib(ctx["backup_need"]), vms=0)
            os.makedirs(os.path.join(RUN, "reserve"), mode=0o700, exist_ok=True)
            ctx["reservation"] = os.path.join(RUN, "reserve", "%d-%d" % (ctx["uid"], os.getpid()))
            with open(ctx["reservation"], "w") as f:
                f.write("%d\n" % ctx["backup_need"])
            os.close(held.pop())
        if reserve:
            held.append(lock("global"))
            # Nothing was there, so whatever a failed run leaves in it is ours to remove.
            ctx["staged_dir"] = name_taken(vm)
            cpus, memory, disk = ctx["quota"]
            ctx["quota_limits"] = check_quota(ctx["uid"], ctx["user"], cpus, memory, disk)
            registry_write(vm, {"owner_uid": ctx["uid"], "owner": ctx["user"], "state": "creating",
                                "cpus": cpus, "memory_mb": memory, "disk_gb": disk, "created": int(time.time())})
            os.close(held.pop())
            ctx["reserved"] = vm
        try:
            if ctx.get("iso_fd") is not None:
                if not vm:
                    raise Denied("VM name required")
                path = stage_iso(ctx, ctx["iso_fd"], vm)
                argv = [path if a == "@ISO@" else a for a in argv]
            if ctx["role"] != "root" and argv[0] in ("create", "create-iso"):
                write_pubkey(ctx, req)
            rc = run_module(ctx, conn, argv, req, fds)
        except BaseException:
            rc = None
            raise
        finally:
            # Never remove the folder under a module that still runs.
            if rc is None and ctx.get("reserved") and (ctx.get("proc") is None or ctx["proc"].poll() is not None) \
                    and domain_known(vm) is False:
                release_reservation(ctx, vm)
        # A declined or failed create may exit 0 too; only a defined domain makes the VM real.
        known = domain_known(vm) if ctx.get("staged_dir") or ctx.get("reserved") else True
        if known is None:
            say(fds.get("stderr"), "libvirt did not answer, so dcvm kept the record and folder of %s; check it with: dcvm info %s" % (vm, vm))
            return rc or 70
        if ctx.get("staged_dir") and not ctx.get("reserved") and not known and not DRY_RUN:
            subprocess.run(["rm", "-rf", "--", ctx["staged_dir"]])
        if ctx.get("reserved"):
            entry = registry_read(vm) or {}
            if not known:
                release_reservation(ctx, vm)
            elif entry.get("state") == "creating":
                entry["state"] = "ready"
                registry_write(vm, entry)
            elif ctx.get("iso_gb"):
                # The module recorded only the disk; the reservation already held both.
                entry["disk_gb"] = int(entry.get("disk_gb") or 0) + ctx["iso_gb"]
                registry_write(vm, entry)
        return rc
    finally:
        for fd in held:
            os.close(fd)
        for f in (ctx.get("pubkey_file"), ctx.get("reservation")):
            try:
                if f:
                    os.unlink(f)
            except OSError:
                pass


def release_reservation(ctx, vm):
    try:
        os.unlink(registry_path(vm))
    except OSError:
        pass
    if ctx.get("staged_dir") and not DRY_RUN:
        subprocess.run(["rm", "-rf", "--", ctx["staged_dir"]])


def write_pubkey(ctx, req):
    key = req.get("pubkey")
    if not isinstance(key, str) or not key.strip():
        return
    key = key.strip().splitlines()[0]
    if len(key) > 16384 or not re.match(r"^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521)|sk-[a-z0-9@.-]+) [A-Za-z0-9+/=]+( [^\x00-\x1f]*)?\Z", key):
        raise Denied("your SSH public key is not in a format dcvm accepts")
    os.makedirs(os.path.join(RUN, "keys"), mode=0o700, exist_ok=True)
    path = os.path.join(RUN, "keys", "%d-%d.pub" % (ctx["uid"], os.getpid()))
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    os.write(fd, (key + "\n").encode())
    os.close(fd)
    ctx["pubkey_file"] = path


def main(args):
    global DRY_RUN, STATE, RUN, AUDIT, LIMITS, CONFIG, DCVM
    if args[:1] == ["--listen"]:
        path, opts = args[1], args[2:]
        while opts:
            o = opts.pop(0)
            if o == "--dry-run":
                DRY_RUN = True
            elif o == "--role":
                uid, role = opts.pop(0).split("=")
                ROLE_MAP[int(uid)] = role if role != "none" else None
            elif o == "--state":
                STATE = opts.pop(0)
                RUN = os.path.join(STATE, "run")
                AUDIT = os.path.join(STATE, "audit.log")
            elif o == "--limits":
                LIMITS = opts.pop(0)
            elif o == "--config":
                CONFIG = opts.pop(0)
            elif o == "--dcvm":
                DCVM = opts.pop(0)
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        if os.path.exists(path):
            os.unlink(path)
        srv.bind(path)
        srv.listen(8)
        while True:
            conn, _ = srv.accept()
            if os.fork() == 0:
                srv.close()
                handle(conn)
                os._exit(0)
            conn.close()
            while True:
                try:
                    if os.waitpid(-1, os.WNOHANG)[0] == 0:
                        break
                except ChildProcessError:
                    break
    conn = socket.socket(fileno=0)
    handle(conn)


if __name__ == "__main__":
    main(sys.argv[1:])
