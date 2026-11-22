"""dcvm client: runs as the user and hands the command to the dcvm socket."""

import json
import os
import re
import signal
import socket
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
    while i < len(argv):
        a = argv[i]
        opt, eq, val = a.partition("=")
        if opt in SECRET_OPTS and argv[:1] in (["create"], ["create-iso"]):
            if not eq:
                if i + 1 >= len(argv):
                    fail("%s needs a value" % opt)
                val = argv[i + 1]
                i += 1
            secrets[SECRET_OPTS[opt]] = val
        else:
            out.append(a)
        i += 1
    for var, key in SECRET_ENV.items():
        if os.environ.get(var) and key not in secrets and argv[:1] in (["create"], ["create-iso"]):
            secrets[key] = os.environ[var]
    return out, secrets


class Files:
    def __init__(self):
        self.fds = [0, 1, 2]
        self.cleanup = []
        self.rename = None

    def add(self, fd):
        self.fds.append(fd)
        return "fd:%d" % (len(self.fds) - 1)


def open_input(files, path, what):
    try:
        fd = os.open(os.path.expanduser(path), os.O_RDONLY)
    except OSError as e:
        fail("cannot open %s %s: %s" % (what, path, e.strerror))
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
                if v and not re.match(r"^[1-9]$", v) and ("/" in v or v.endswith(".iso") or os.path.exists(v)):
                    ref = open_input(files, v, "ISO")
                    if eq:
                        out[i] = opt + "=" + ref
                    else:
                        out[i + 1] = ref
                break
    elif cmd == "create-iso":
        for i, a in enumerate(out):
            if a == "--iso" and i + 1 < len(out):
                out[i + 1] = open_input(files, out[i + 1], "ISO")
    elif cmd in ("import",) or out[:2] == ["backup", "import"]:
        k = 1 if cmd == "import" else 2
        if len(out) > k:
            out[k] = open_input(files, out[k], "archive")
    elif out[:2] == ["backup", "export"] and len(out) >= 3:
        rest = out[2:]
        dest = "."
        if len(rest) >= 2 and os.path.isdir(os.path.expanduser(rest[-1])):
            dest = rest.pop()
        vm = rest[0]
        label = rest[1] if len(rest) > 1 else "latest"
        name = os.path.join(os.path.expanduser(dest), "%s-%s.tar.gz" % (vm, label))
        tmp = name + ".part"
        try:
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except OSError as e:
            fail("cannot create %s: %s" % (tmp, e.strerror))
        files.cleanup.append(tmp)
        files.rename = (tmp, name)
        out = out[:2] + rest + [files.add(fd)]
    return out


def public_key():
    home = os.path.expanduser("~")
    for name in ("id_ed25519.pub", "id_ecdsa.pub", "id_rsa.pub"):
        path = os.path.join(home, ".ssh", name)
        if os.path.isfile(path):
            with open(path) as f:
                return f.read(16384).strip()
    key = os.path.join(home, ".ssh", "id_ed25519")
    os.makedirs(os.path.dirname(key), mode=0o700, exist_ok=True)
    try:
        made = subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", key],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    except OSError:
        made = False
    if made:
        print("dcvm: created an SSH key for you in %s" % key, file=sys.stderr)
        with open(key + ".pub") as f:
            return f.read().strip()
    return None


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
    if argv[:1] in (["create"], ["create-iso"]) and "--without-ssh-key" not in argv:
        key = public_key()
        if key:
            req["pubkey"] = key
    data = json.dumps(req).encode()
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        conn.connect(SOCKET)
    except FileNotFoundError:
        fail("the dcvm service is not running (%s missing); ask an admin to run: sudo dcvm doctor --fix" % SOCKET)
    except PermissionError:
        fail("you are not in the dcvm group (or haven't logged in again since being added); ask an admin: sudo dcvm user add %s" % os.environ.get("USER", "<you>"))
    conn.sendmsg([struct.pack(">I", len(data)) + data], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, struct.pack("%di" % len(files.fds), *files.fds))])
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
            os._exit(130)

    signal.signal(signal.SIGINT, on_int)
    head = recv_exact(conn, 4)
    resp = json.loads(recv_exact(conn, struct.unpack(">I", head)[0]).decode()) if head else {"exit": 1}
    rc = resp.get("exit", 1)
    if files.rename:
        tmp, name = files.rename
        if rc == 0 and os.path.getsize(tmp) > 0:
            os.replace(tmp, name)
            print("dcvm: exported to %s" % name, file=sys.stderr)
        else:
            os.unlink(tmp)
    sys.exit(rc if isinstance(rc, int) else 1)


if __name__ == "__main__":
    main(sys.argv[1:])
