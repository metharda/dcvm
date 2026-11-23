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
import time

PROTOCOL = 1
MAX_REQUEST = 256 * 1024
MAX_FDS = 8
MAX_ISO = 16 * 1024**3
REQUEST_TIMEOUT = 15

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
SIZE = re.compile(r"^[1-9][0-9]{0,4}[GgMm]\Z")
USERNAME = re.compile(r"^[a-z_][a-z0-9_-]{2,31}\Z")
PACKAGES = re.compile(r"^[A-Za-z0-9][A-Za-z0-9@._+-]*(,[A-Za-z0-9][A-Za-z0-9@._+-]*)*\Z")
IPV4 = re.compile(r"^[0-9]{1,3}(\.[0-9]{1,3}){3}\Z")
TTL = re.compile(r"^[1-9][0-9]{0,4}[mhd]\Z")
OS_VARIANT = re.compile(r"^[A-Za-z0-9._-]{1,64}\Z")
TERM = re.compile(r"^[A-Za-z0-9._+-]{1,64}\Z")


class Denied(Exception):
    pass


SECRET_FLAGS = ("-p", "--password", "-r", "--root-password", "--tailscale-authkey")


def redact(argv):
    out, hide = [], False
    for a in argv:
        if hide:
            out.append("***")
            hide = False
        elif a in SECRET_FLAGS:
            out.append(a)
            hide = True
        elif any(a.startswith(f + "=") for f in SECRET_FLAGS) or re.match(r"^-[pr].", a):
            out.append(a[:2] + "***")
        else:
            out.append(a)
    return out


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


def vm_exists(vm):
    if DRY_RUN:
        return registry_read(vm) is not None
    return subprocess.run(["virsh", "dominfo", "--", vm], stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL, env=module_env_base()).returncode == 0


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
    limits = dict(DEFAULT_LIMITS)
    try:
        with open(LIMITS) as f:
            for line in f:
                line = line.split("#", 1)[0].strip()
                k, _, v = line.partition("=")
                k, v = k.strip(), v.strip()
                if not v.isdigit():
                    continue
                if k in limits:
                    limits[k] = int(v)
                elif k.startswith("user.%s." % user) and k.rsplit(".", 1)[-1] in limits:
                    limits[k.rsplit(".", 1)[-1]] = int(v)
    except OSError:
        pass
    return limits


def size_gb(value, default):
    if not value:
        return default
    v = value.upper()
    if v.endswith("M"):
        return max(1, int(v[:-1]) // 1024)
    return int(v.rstrip("G"))


def check_quota(uid, user, cpus, memory_mb, disk_gb):
    limits = limits_for(user)
    mine = [e for e in registry_all().values() if e.get("owner_uid") == str(uid)]
    used = {
        "vms": len(mine),
        "vcpus": sum(int(e.get("cpus", "0") or 0) for e in mine),
        "memory_mb": sum(int(e.get("memory_mb", "0") or 0) for e in mine),
        "disk_gb": sum(int(e.get("disk_gb", "0") or 0) for e in mine),
    }
    want = {"vms": 1, "vcpus": cpus, "memory_mb": memory_mb, "disk_gb": disk_gb}
    names = {"vms": "VM", "vcpus": "vCPU", "memory_mb": "memory (MB)", "disk_gb": "disk (GB)"}
    for k, n in want.items():
        if used[k] + n > limits[k]:
            raise Denied("over your %s quota: %d used + %d requested > %d (ask an admin to raise it in %s)"
                         % (names[k], used[k], n, limits[k], LIMITS))
    return "%d %d %d" % tuple(limits[k] - used[k] for k in ("vcpus", "memory_mb", "disk_gb"))


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


def parse_create(ctx, args, iso_mode):
    out, vm, i = [], None, 0
    cpus, memory, disk = 2, 2048, 20 if iso_mode else 30
    while i < len(args):
        a = args[i]
        opt = a.split("=", 1)[0]
        if a in CREATE_FLAGS:
            out.append(a)
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
                raise Denied("--disk must look like 30G")
            disk = size_gb(v, disk)
            out += ["-d", v.upper()]
        elif opt in ("-u", "--username"):
            v, i = take_value(args, i, opt)
            if not USERNAME.match(v):
                raise Denied("invalid --username")
            out += ["-u", v]
        elif opt in ("-k", "--packages") and not iso_mode:
            v, i = take_value(args, i, opt)
            if not PACKAGES.match(v.replace(" ", "")):
                raise Denied("invalid package list")
            out += ["-k", v.replace(" ", "")]
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
            if not TTL.match(v):
                raise Denied("--ttl must look like 90m, 2h or 3d")
            out += ["--ttl", v]
        elif opt in ("-o", "--os") and not iso_mode:
            v, i = take_value(args, i, opt)
            if v.startswith("fd:"):
                ctx["iso_fd"] = fd_ref(ctx, v)
            elif not re.match(r"^[1-9]\Z", v):
                raise Denied("--os must be 1-9, or an ISO file")
            else:
                out += ["-o", v]
        elif opt == "--iso" and iso_mode:
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
    if cmd == "status" and len(plain) <= 1:
        if plain:
            own_vm(ctx, plain[0])
        return argv
    if cmd == "info" and len(plain) == 1:
        own_vm(ctx, plain[0])
        return [cmd] + plain + json_flag
    if cmd in ("start", "stop", "restart"):
        if len(plain) > 1:
            raise Denied("%s takes one VM" % cmd)
        if plain and plain[0] != "all":
            own_vm(ctx, plain[0])
            ctx["vm"] = plain[0]
        ctx["mutating"] = True
        return [cmd] + plain
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
        ctx.update(vm=plain[2], mutating=plain[1] != "status")
        return argv
    if cmd == "restore":
        return decide_backup(ctx, ["restore"] + args)
    if cmd == "backup":
        return decide_backup(ctx, args)
    if cmd == "whoami":
        return argv
    raise Denied("'%s' needs a dcvm admin" % " ".join(argv[:2]))


def decide_backup(ctx, args):
    if not args:
        raise Denied("backup needs a command")
    sub, rest = args[0], args[1:]
    if sub == "create" and len(rest) == 1:
        own_vm(ctx, rest[0])
        ctx.update(vm=rest[0], mutating=True, interactive=True)
        return ["backup", "create", rest[0]]
    if sub == "list" and len(rest) <= 1:
        if rest:
            check_backup_vm(ctx, rest[0])
        return ["backup", "list"] + rest
    if sub == "delete" and len(rest) in (1, 2):
        day = r"[0-9]{2}\.[0-9]{2}\.[0-9]{4}(-([0-9]+|[0-9]{2}:[0-9]{2}:[0-9]{2}))?"
        if len(rest) == 1:
            # The module takes one <vm>-<id> argument and splits it with the same greedy regex.
            m = re.match(r"^(.+)-(%s)\Z" % day, rest[0])
            if not m:
                raise Denied("delete takes a backup id: dcvm backup delete <vm> <dd.mm.yyyy[-N]>")
            vm, bid = m.group(1), m.group(2)
        else:
            vm, bid = rest[0], strip_vm(rest[0], rest[1])
            t = re.match(r"^([0-9]{4})([0-9]{2})([0-9]{2})_([0-9]{2})([0-9]{2})([0-9]{2})\Z", bid)
            if t:
                bid = "%s.%s.%s-%s:%s:%s" % (t.group(3), t.group(2), t.group(1), t.group(4), t.group(5), t.group(6))
            if not re.match(r"^%s\Z" % day, bid):
                raise Denied("delete takes a backup id: dcvm backup delete <vm> <dd.mm.yyyy[-N]>")
        check_backup_vm(ctx, vm)
        ctx.update(vm=vm, mutating=True)
        return ["backup", "delete", "%s-%s" % (vm, bid)]
    if sub == "restore" and 1 <= len(rest) <= 3:
        check_backup_vm(ctx, rest[0])
        rest = rest[:1] + [strip_vm(rest[0], a) for a in rest[1:2]] + rest[2:]
        if len(rest) >= 2 and not BACKUP_ID.match(rest[1]):
            raise Denied("invalid backup id")
        if len(rest) == 3:
            target = new_vm_name(rest[2])
            check_quota(ctx["uid"], ctx["user"], 2, 2048, 30)
            ctx.update(vm=target, new_vm=True, quota=(2, 2048, 30))
        else:
            own_vm(ctx, rest[0])
            protected(rest[0])
            ctx["vm"] = rest[0]
        ctx.update(mutating=True, interactive=True)
        return ["backup", "restore"] + rest
    if sub == "export" and 1 <= len(rest) <= 3:
        check_backup_vm(ctx, rest[0])
        rest = rest[:1] + [strip_vm(rest[0], a) for a in rest[1:2]] + rest[2:]
        if len(rest) >= 2 and not rest[1].startswith("fd:") and not BACKUP_ID.match(rest[1]):
            raise Denied("invalid backup id")
        if not rest[-1].startswith("fd:"):
            raise Denied("export writes to a file you pass")
        ctx["export_fd"] = fd_ref(ctx, rest[-1])
        return ["backup", "export"] + [a for a in rest if not a.startswith("fd:")]
    raise Denied("'backup %s' needs a dcvm admin" % sub)


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
    if ctx.get("quota_left"):
        env["DCVM_QUOTA_LEFT"] = ctx["quota_left"]
    return env


def stage_iso(ctx, fd, vm):
    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode):
        raise Denied("the ISO must be a regular file")
    if st.st_size > MAX_ISO:
        raise Denied("the ISO is larger than 16 GB")
    if not ctx.get("reserved") and vm_exists(vm):
        raise Denied("VM %s already exists" % vm)
    base = read_config()["DATACENTER_BASE"]
    fs = os.statvfs(base)
    if fs.f_bavail * fs.f_frsize < st.st_size + 2 * 1024 ** 3:
        raise Denied("not enough free space in %s for the ISO and a disk; ask an admin" % base)
    vm_dir = os.path.join(base, "vms", vm)
    os.makedirs(vm_dir, mode=0o711, exist_ok=True)
    os.chmod(vm_dir, 0o711)
    dest = os.path.join(vm_dir, "installer.iso")
    out = os.open(dest + ".part", os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    try:
        os.lseek(fd, 0, os.SEEK_SET)
        while True:
            chunk = os.read(fd, 4 * 1024 * 1024)
            if not chunk:
                break
            os.write(out, chunk)
    finally:
        os.close(out)
    os.replace(dest + ".part", dest)
    ctx["staged_dir"] = vm_dir
    return dest


def audit(ctx, argv, decision, rc=None, reason=None, started=None):
    rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "uid": ctx.get("uid"), "user": ctx.get("user"),
           "role": ctx.get("role"), "origin": ctx.get("origin"), "pid": ctx.get("pid"),
           "argv": redact(argv) if isinstance(argv, list) else argv, "decision": decision}
    if rc is not None:
        rec["exit"] = rc
    if reason:
        rec["reason"] = reason
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


def recv_request(conn):
    conn.settimeout(REQUEST_TIMEOUT)
    data, fds = b"", []
    while len(data) < 4 or len(data) < 4 + struct.unpack(">I", data[:4])[0]:
        msg, anc, flags, _ = conn.recvmsg(65536, socket.CMSG_SPACE(MAX_FDS * 4))
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
    req = json.loads(data[4: 4 + length].decode())
    if not isinstance(req, dict) or req.get("v") != PROTOCOL:
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
    if fd is None:
        return
    try:
        os.write(fd, ("\033[0;31m✗\033[0m %s\n" % text if os.isatty(fd) else "error: %s\n" % text).encode())
    except OSError:
        pass


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
    proc = subprocess.Popen([DCVM] + argv, env=env, stdin=stdin, stdout=fds.get("stdout"),
                            stderr=fds.get("stderr"), pass_fds=pass_fds, start_new_session=True, close_fds=True)
    for fd in pass_fds:
        if fd != ctx.get("export_fd") and fd not in ctx.get("keep_fds", []):
            os.close(fd)
    cancelled = False
    while proc.poll() is None:
        if cancelled:
            try:
                proc.wait(1)
            except subprocess.TimeoutExpired:
                pass
            continue
        try:
            ready, _, _ = select.select([conn], [], [], 0.5)
        except (OSError, ValueError):
            ready = []
        if ready:
            try:
                data = conn.recv(64)
            except OSError:
                data = b""
            if not data:
                cancelled = True
                if not ctx.get("mutating"):
                    try:
                        os.killpg(proc.pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                    try:
                        proc.wait(5)
                    except subprocess.TimeoutExpired:
                        os.killpg(proc.pid, signal.SIGKILL)
    return proc.wait()


def handle(conn):
    ctx = {"origin": "unknown"}
    started = time.time()
    req, files, argv = {}, [], []
    try:
        pid, uid, _gid = struct.unpack("3i", conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))
        ctx.update(uid=uid, pid=pid, user=user_name(uid), role=role_of(uid))
        req, files = recv_request(conn)
        if len(files) > MAX_FDS:
            raise Denied("too many files passed")
        fdmap = {}
        for name in ("stdin", "stdout", "stderr"):
            i = req.get(name)
            if isinstance(i, int) and 0 <= i < len(files):
                fdmap[name] = files[i]
        ctx["files"] = {i: fd for i, fd in enumerate(files)}
        # A client may say "agent" on a terminal, never "terminal" without one.
        ttys = all(fdmap.get(n) is not None and os.isatty(fdmap[n]) for n in ("stdin", "stdout"))
        ctx["origin"] = "terminal" if req.get("origin") == "terminal" and ttys else "agent"
        argv = req.get("argv")
        if not isinstance(argv, list) or not all(isinstance(a, str) and len(a) <= 4096 for a in argv) or len(argv) > 64:
            raise Denied("malformed request")
        if ctx["role"] is None:
            raise Denied("you are not in the %s group; ask an admin: sudo dcvm user add %s" % (USER_GROUP, ctx["user"]))
        if ctx["role"] == "user":
            final = decide_user(ctx, argv)
        else:
            final = admin_argv(ctx, argv)
        rc = execute(ctx, conn, final, req, fdmap)
        audit(ctx, argv, "allow", rc=rc, started=started)
        send(conn, {"exit": rc})
    except Denied as e:
        say(fdmap_get(req, files, "stderr"), str(e))
        audit(ctx, argv, "deny", reason=str(e), started=started)
        send(conn, {"exit": 77, "error": str(e)})
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
                ctx["export_fd"] = fd
                final[i] = None
            elif final[:2] == ["backup", "import"] or final[0] == "import":
                final[i] = "/proc/self/fd/%d" % fd
                ctx.setdefault("keep_fds", []).append(fd)
            else:
                raise Denied("unexpected file argument")
    final = [a for a in final if a is not None]
    if final and final[0] in ("create", "create-iso") and len(final) > 1 and not final[1].startswith("-"):
        ctx.update(vm=final[1].split(",")[0], new_vm=True, mutating=True)
    ctx["mutating"] = True
    ctx["interactive"] = True
    return final


def execute(ctx, conn, argv, req, fds):
    vm = ctx.get("vm")
    held = []
    try:
        if vm:
            held.append(lock("vm-" + vm))
        if ctx.get("new_vm") and vm and ctx["role"] == "user":
            held.append(lock("global"))
            vm_dir = os.path.join(read_config()["DATACENTER_BASE"], "vms", vm)
            if vm_exists(vm) or registry_read(vm) is not None or os.path.exists(vm_dir):
                raise Denied("the name %s is taken" % vm)
            # Nothing was there, so whatever a failed run leaves in it is ours to remove.
            ctx["staged_dir"] = vm_dir
            cpus, memory, disk = ctx["quota"]
            ctx["quota_left"] = check_quota(ctx["uid"], ctx["user"], cpus, memory, disk)
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
            if ctx["role"] == "user" and argv[0] in ("create", "create-iso"):
                write_pubkey(ctx, req)
            rc = run_module(ctx, conn, argv, req, fds)
        except BaseException:
            rc = None
            raise
        finally:
            if rc is None and ctx.get("reserved"):
                release_reservation(ctx, vm)
        if rc != 0 and ctx.get("staged_dir") and not ctx.get("reserved") and not vm_exists(vm) and not DRY_RUN:
            subprocess.run(["rm", "-rf", "--", ctx["staged_dir"]])
        if ctx.get("reserved"):
            entry = registry_read(vm) or {}
            if rc != 0 and not vm_exists(vm):
                release_reservation(ctx, vm)
            elif entry.get("state") == "creating":
                entry["state"] = "ready"
                registry_write(vm, entry)
        return rc
    finally:
        for fd in held:
            os.close(fd)
        if ctx.get("pubkey_file"):
            try:
                os.unlink(ctx["pubkey_file"])
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
