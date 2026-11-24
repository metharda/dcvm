"""dcvm client: runs as the user and hands the command to the dcvm socket."""

import json
import os
import re
import signal
import socket
import stat
import struct
import subprocess
import sys

SOCKET = os.environ.get("DCVM_SOCKET", "/run/dcvm/dcvm.sock")
PROTOCOL = 1
SECRET_OPTS = {"-p": "password", "--password": "password", "-r": "root_password",
               "--root-password": "root_password", "--tailscale-authkey": "tailscale_authkey"}
SECRET_ENV = {"DCVM_PASSWORD": "password", "DCVM_ROOT_PASSWORD": "root_password",
              "DCVM_TAILSCALE_AUTHKEY": "tailscale_authkey"}


def fail(msg, code=1):
    print("error: %s" % msg, file=sys.stderr)
    sys.exit(code)


def pull_secrets(argv):
    out, secrets, i = [], {}, 0
    creating = argv[:1] == ["create"]
    while i < len(argv):
        a = argv[i]
        opt, eq, val = a.partition("=")
        if opt not in SECRET_OPTS and a[:2] in ("-p", "-r") and len(a) > 2 and not a.startswith("--"):
            fail("write %s VALUE or %s=VALUE" % (a[:2], a[:2]))
        if opt in SECRET_OPTS:
            if argv[:1] == ["create-iso"]:
                fail("%s does nothing with an ISO: the installer sets up the OS" % opt)
            if not creating:
                fail("%s only goes with create" % opt)
            if not eq:
                if i + 1 >= len(argv) or argv[i + 1].startswith("-"):
                    fail("%s needs a value (or use %s=VALUE)" % (opt, opt))
                val = argv[i + 1]
                i += 1
            if not val or "\n" in val or len(val) > 4096:
                fail("%s must be 1-4096 characters on one line" % opt)
            secrets[SECRET_OPTS[opt]] = val
        else:
            out.append(a)
        i += 1
    iso = any((a.partition("=")[0] in ("-o", "--os")) and not re.match(r"^[1-9]\Z", a.partition("=")[2] or (argv[n + 1] if n + 1 < len(argv) else "1"))
              for n, a in enumerate(argv))
    for var, key in SECRET_ENV.items():
        # An agent's environment may carry these for cloud images; an ISO create would refuse them.
        if iso:
            continue
        if os.environ.get(var) and key not in secrets and creating:
            if "\n" in os.environ[var] or len(os.environ[var]) > 4096:
                fail("%s must be at most 4096 characters on one line" % var)
            secrets[key] = os.environ[var]
    return out, secrets


class Files:
    def __init__(self):
        self.fds = [0, 1, 2]
        self.rename = None

    def add(self, fd):
        self.fds.append(fd)
        return "fd:%d" % (len(self.fds) - 1)


def open_input(files, path, what):
    try:
        # O_NONBLOCK so a FIFO can't hang us; only regular files are passed on.
        fd = os.open(os.path.expanduser(path), os.O_RDONLY | os.O_NONBLOCK)
    except OSError as e:
        fail("cannot open %s %s: %s" % (what, path, e.strerror))
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        fail("%s %s is not a regular file" % (what, path))
    os.set_blocking(fd, True)
    return files.add(fd)


def attach_files(argv, files):
    if not argv:
        return argv
    out = list(argv)
    cmd = out[0]
    if cmd == "create":
        for i, a in enumerate(out):
            opt, eq, val = a.partition("=")
            if opt in ("-o", "--os"):
                v = val if eq else (out[i + 1] if i + 1 < len(out) else "")
                if v and not re.match(r"^[1-9]\Z", v) and ("/" in v or v.endswith(".iso") or os.path.exists(v)):
                    ref = open_input(files, v, "ISO")
                    if eq:
                        out[i:i + 1] = [opt, ref]
                    else:
                        out[i + 1] = ref
                break
    elif cmd == "create-iso":
        rebuilt, i = [], 0
        while i < len(out):
            opt, eq, val = out[i].partition("=")
            if opt in ("--iso", "-o") and (eq or i + 1 < len(out)):
                if "--iso" in rebuilt:
                    fail("give --iso once")
                if not eq:
                    i += 1
                    val = out[i]
                rebuilt += ["--iso", open_input(files, val, "ISO")]
            else:
                rebuilt.append(out[i])
            i += 1
        out = rebuilt
    elif cmd in ("import",) or out[:2] == ["backup", "import"]:
        k = 1 if cmd == "import" else 2
        if len(out) > k:
            out[k] = open_input(files, out[k], "archive")
    elif out[:2] == ["backup", "export"] and len(out) - out.count("--full") >= 3:
        full = ["--full"] if "--full" in out else []
        rest = [a for a in out[2:] if a != "--full"]
        dest = "."
        looks_like_id = re.match(r"^(latest|[0-9]{8}_[0-9]{6}|[0-9]{2}\.[0-9]{2}\.[0-9]{4}(-[0-9]+)?)\Z", rest[1]) if len(rest) == 2 else None
        if len(rest) == 3 or (len(rest) == 2 and not looks_like_id and (os.path.isdir(os.path.expanduser(rest[1])) or "/" in rest[1])):
            dest = rest.pop()
            if not os.path.isdir(os.path.expanduser(dest)):
                fail("%s is not a folder" % dest)
        vm = rest[0]
        label = rest[1] if len(rest) > 1 else "latest"
        if not re.match(r"^[A-Za-z0-9_][A-Za-z0-9_-]{2,63}\Z", vm) or not re.match(r"^[0-9A-Za-z._:-]{1,64}\Z", label) or label.startswith("fd:"):
            fail("usage: dcvm backup export <vm> [id|latest] [folder] [--full]")
        name = os.path.join(os.path.expanduser(dest), "%s-%s.tar.gz" % (vm, label.replace(":", "")))
        if os.path.exists(name):
            fail("%s already exists" % name)
        tmp = name + ".part"
        try:
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except OSError as e:
            fail("cannot create %s: %s" % (tmp, e.strerror))
        files.rename = (tmp, name)
        out = out[:2] + rest + [files.add(fd)] + full
    return out


def public_key():
    """Return (key, path of a key pair made now, or None)."""
    home = os.path.expanduser("~")
    for name in ("id_ed25519.pub", "id_ecdsa.pub", "id_rsa.pub"):
        path = os.path.join(home, ".ssh", name)
        try:
            with open(path) as f:
                return f.read(16384).strip(), None
        except OSError:
            continue
    key = os.path.join(home, ".ssh", "id_ed25519")
    if os.path.exists(key):
        print("dcvm: %s has no readable .pub file; the VM gets no SSH key of yours" % key, file=sys.stderr)
        return None, None
    try:
        os.makedirs(os.path.dirname(key), mode=0o700, exist_ok=True)
        made = subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", key], stdin=subprocess.DEVNULL,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    except OSError:
        made = False
    if made:
        with open(key + ".pub") as f:
            return f.read().strip(), key
    return None, None


def columns():
    for fd in (2, 1, 0):
        try:
            return os.get_terminal_size(fd).columns
        except OSError:
            continue
    return 80


def recv_exact(conn, n):
    data = b""
    while len(data) < n:
        chunk = conn.recv(n - len(data))
        if not chunk:
            return None
        data += chunk
    return data


def main(argv):
    argv, secrets = pull_secrets(argv)
    files = Files()
    argv = attach_files(argv, files)
    req = {"v": PROTOCOL, "argv": argv, "stdin": 0, "stdout": 1, "stderr": 2,
           "term": os.environ.get("TERM", "dumb"), "cols": columns(),
           "origin": os.environ.get("DCVM_ORIGIN") or ("terminal" if os.isatty(0) and os.isatty(1) else "agent")}
    if secrets:
        req["secrets"] = secrets
    try:
        conn = connect()
        # After connecting: someone the socket turns away must not get a key made in ~/.ssh.
        made = None
        if argv[:1] == ["create"] and "--without-ssh-key" not in argv:
            key, made = public_key()
            if key:
                req["pubkey"] = key
        rc = talk(json.dumps(req).encode(), files, conn)
        if made and rc == 77:
            # The server refused the create, so nothing uses the key made for it.
            for path in (made, made + ".pub"):
                try:
                    os.unlink(path)
                except OSError:
                    pass
        elif made:
            print("dcvm: created an SSH key for you in %s" % made, file=sys.stderr)
        sys.exit(rc)
    finally:
        if files.rename and os.path.exists(files.rename[0]):
            os.unlink(files.rename[0])


def connect():
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        conn.connect(SOCKET)
    except FileNotFoundError:
        fail("the dcvm service is not running (%s missing); ask an admin to run: sudo dcvm doctor --fix" % SOCKET, 70)
    except PermissionError:
        fail("you are not in the dcvm group (or haven't logged in again since being added); ask an admin: sudo dcvm user add %s" % os.environ.get("USER", "<you>"), 77)
    except OSError as e:
        fail("cannot reach the dcvm service at %s: %s; ask an admin to run: sudo dcvm doctor --fix" % (SOCKET, e.strerror), 70)
    return conn


def talk(data, files, conn):
    if len(data) > 262144:
        fail("the command is too long")
    try:
        conn.sendmsg([struct.pack(">I", len(data)) + data], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, struct.pack("%di" % len(files.fds), *files.fds))])
    except OSError:
        # The server may refuse before reading the request; its answer is still there to read.
        pass
    for fd in files.fds[3:]:
        os.close(fd)
    interrupts = [0]

    def on_int(_sig, _frame):
        interrupts[0] += 1
        if interrupts[0] == 1:
            try:
                conn.shutdown(socket.SHUT_WR)
            except OSError:
                pass
            print("\ndcvm: cancelling (an operation that changes a VM finishes safely first); Ctrl-C again to leave",
                  file=sys.stderr)
        else:
            if files.rename and os.path.exists(files.rename[0]):
                os.unlink(files.rename[0])
            os._exit(130)

    def on_term(sig, _frame):
        sys.exit(128 + sig)

    signal.signal(signal.SIGINT, on_int)
    signal.signal(signal.SIGTERM, on_term)
    signal.signal(signal.SIGHUP, on_term)
    try:
        head = recv_exact(conn, 4)
        resp = json.loads(recv_exact(conn, struct.unpack(">I", head)[0]).decode())
        rc = resp["exit"]
        if not isinstance(rc, int):
            raise ValueError
    except (ValueError, TypeError, KeyError, AttributeError, OSError, struct.error):
        fail("the dcvm service ended without an answer; ask an admin to check: journalctl -u 'dcvm@*'", 70)
    if (rc == 70 or resp.get("show")) and resp.get("error"):
        print("error: %s" % resp["error"], file=sys.stderr)
    if files.rename:
        tmp, name = files.rename
        if rc == 0 and os.path.getsize(tmp) > 0:
            os.replace(tmp, name)
            print("dcvm: exported to %s" % name, file=sys.stderr)
    if interrupts[0] and rc != 0:
        return 130
    return 128 - rc if rc < 0 else rc


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except KeyboardInterrupt:
        sys.exit(130)
