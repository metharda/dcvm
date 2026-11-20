# Development

How the repository is laid out, how to work on it, and how to re-record the
README demos. [CONTRIBUTING.md](../CONTRIBUTING.md) has the coding standards,
CI rules and pull request checklist; this page doesn't repeat them.

- [Repository layout](#repository-layout)
- [Workflow](#workflow)
- [Conventions](#conventions)
- [Shared helpers](#shared-helpers)
- [Recording the demos](#recording-the-demos)

See also: [Architecture](architecture.md) · [Operations](operations.md)

## Repository layout

```
dcvm/
├── dcvm                        # CLI entry point: routes commands, holds the version
├── lib/
│   ├── core/
│   │   ├── create-vm.sh        # dcvm create (cloud image + cloud-init)
│   │   ├── custom-iso.sh       # dcvm create-iso / create -o file.iso
│   │   ├── delete-vm.sh        # dcvm delete
│   │   └── vm-manager.sh       # list, status, start, stop, restart, console
│   ├── network/
│   │   ├── network-manager.sh  # dcvm network (show, status, vnc, ...)
│   │   ├── port-forward.sh     # dcvm network ports
│   │   └── dhcp.sh             # dcvm network dhcp
│   ├── storage/
│   │   ├── backup.sh           # dcvm backup / restore
│   │   └── storage-manager.sh  # dcvm storage / storage-cleanup (hourly timer)
│   ├── installation/
│   │   ├── install-dcvm.sh     # installer (also the curl | bash entry point)
│   │   ├── self-update.sh      # dcvm self-update
│   │   └── uninstall-dcvm.sh   # dcvm uninstall
│   └── utils/
│       ├── common.sh           # shared helpers, sourced by every script
│       ├── mirror-manager.sh   # cloud image mirrors (dcvm template)
│       ├── fix-lock.sh         # dcvm fix-lock
│       ├── dcvm-completion.sh  # bash completion
│       └── test-suite.sh       # repository test suite
├── docs/
│   ├── demo/                   # VHS tapes, the GIFs they produce, shrink.sh
│   └── examples/
├── .github/workflows/          # lint, format, test, version-bump
├── CHANGELOG.md
└── CONTRIBUTING.md
```

## Workflow

1. **Branch** from `main` (`feature/...`, `fix/...`).
2. **Change** the script under `lib/`. New commands also need a route in
   `dcvm`, a line in `show_usage`, completion in `dcvm-completion.sh`, and
   docs in [usage.md](usage.md).
3. **Run the checks** (bash 4+; on macOS use Homebrew's bash):

   ```bash
   bash lib/utils/test-suite.sh --syntax   # bash -n + shellcheck
   bash lib/utils/test-suite.sh --quick    # what CI runs; no root, no VMs
   shfmt -d -i 2 dcvm lib                  # formatting, as in CI
   sudo bash lib/utils/test-suite.sh --full  # on a KVM host: creates and deletes a VM
   ```

4. **Bump the version** in `dcvm` (`Version: X.Y.Z` in `show_version`) and
   add a [CHANGELOG.md](../CHANGELOG.md) entry. CI rejects a pull request that
   doesn't raise the version.
5. **Test on a real host.** On a machine where dcvm is installed, `./dcvm`
   from a clone runs the *installed* libraries (it reads `DCVM_LIB_DIR` from
   `/etc/dcvm-install.conf`). Run the changed script directly instead, for
   example `sudo bash lib/core/create-vm.sh web -f -p "$VM_PASSWORD"`; see
   CONTRIBUTING.md for details.

CI (`.github/workflows/`) runs on pull requests that touch shell files:
`bash -n` and `shellcheck -S error` on every script, `shfmt -i 2`, the quick
test suite on Ubuntu 22.04, the latest Ubuntu and a Debian 12 container, and
the version-bump check.

## Conventions

- Scripts start with `#!/usr/bin/env bash`, find their directory with
  `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`, source
  `../utils/common.sh` and call `load_dcvm_config`.
- Output goes through `print_info`, `print_success`, `print_warning` and
  `print_error`, so every command looks the same.
- Validate user input with the `validate_*` helpers before writing anything.
- Two-space indentation, kebab-case file names.
- Anything that runs inside the guest goes into the cloud-init `user-data`;
  passwords go in only as hashes (see [security.md](security.md)).

## Shared helpers

`lib/utils/common.sh` is the one place for logic used by more than one
script. Reuse these before writing new code:

| Area | Functions |
| :--- | :-------- |
| Output and logs | `print_info`, `print_success`, `print_warning`, `print_error`, `print_status`, `log`, `log_to_file` |
| Config and checks | `load_dcvm_config`, `require_root`, `command_exists`, `check_dependencies` |
| Validation | `validate_vm_name`, `validate_vm_name_list`, `validate_username`, `validate_password`, `validate_package_list`, `validate_ip_in_subnet`, `validate_memory_size`, `validate_cpu_count`, `validate_disk_size`, `trim_whitespace` |
| VMs | `check_vm_exists`, `get_vm_state`, `get_vm_ip`, `get_vm_mac`, `get_vm_disk_path`, `get_vm_username`, `default_username`, `list_datacenter_vms`, `is_vm_in_network`, `stop_vm_gracefully` |
| Network | `get_port_mappings_file`, `read_port_mappings`, `check_port_forward`, `check_port_connectivity`, `check_ping`, `detect_host_ip` |
| DHCP | `filter_lease_lines`, `cleanup_dhcp_lease` (locked), `cleanup_dhcp_lease_unlocked` |
| Credentials | `read_password` (no echo), `generate_password_hash` (SHA-512 crypt), `generate_random_mac` |
| Prompts | `interactive_prompt_memory_common`, `interactive_prompt_cpus_common`, `interactive_prompt_disk_common`, `interactive_prompt_static_ip_common`, `confirm_action`, `require_confirmation` |

## Recording the demos

The GIFs in the README are recorded from real sessions with
[VHS](https://github.com/charmbracelet/vhs) v0.12.1. Each `docs/demo/*.tape`
types real commands into a real dcvm host; nothing is mocked. Waits for a VM
to boot are hidden, and each GIF says so in its caption or on screen.

| Tape | GIF | Starting state of the recording host |
| :--- | :-- | :----------------------------------- |
| `quickstart.tape` | `quickstart.gif` (6× playback) | Fresh Ubuntu 24.04, dcvm not installed |
| `hero.tape` | `hero.gif` | dcvm installed, Ubuntu 24.04 image downloaded, no VMs |
| `backup.tape` | `backup.gif` (3× playback) | `web` from `hero.tape`, running, first boot finished |
| `daily.tape` | `daily.gif` | `web` running, plus `ctf` (`dcvm create ctf -f -p "$VM_PASSWORD" -o 1`) running |

`_style.tape` holds the shared look (JetBrains Mono 16, 1200×720, Catppuccin
Mocha, colourful window bar, teal margin) and `_login.tape` the hidden SSH
login, which sets a plain `lab# ` prompt and exports `VM_PASSWORD` from a
root-only file so no password is typed on camera.

**Recording host.** Keep recordings off your own machine: run VHS in Docker
on a test server and point it at a disposable Ubuntu 24.04 VM with nested KVM
(here called `lab`) that acts as the dcvm host. Put the lab VM on a network
other than `10.10.10.0/24` (libvirt's `default` network works), since dcvm
creates that subnet inside it.

```bash
# On the test server, once
cat > Dockerfile <<'EOF'
FROM ghcr.io/charmbracelet/vhs:v0.12.1
RUN apt-get update -qq && apt-get install -y -qq openssh-client && rm -rf /var/lib/apt/lists/*
EOF
docker build -t dcvm-vhs:0.12.1 .
ssh-keygen -t ed25519 -N '' -f ~/dcvm-demo/key   # add key.pub to root@lab

# On the lab VM, once (after dcvm is installed)
printf 'Host 10.10.10.*\n  StrictHostKeyChecking accept-new\n  LogLevel ERROR\n' >> ~/.ssh/config
(umask 077; openssl rand -base64 18 > /root/.demo-pass)
```

Run each tape from a checkout of this repository on the test server. Keep
the private key outside the checkout and mount it where `_login.tape` expects
it:

```bash
docker run --rm --network host -e LAB_HOST=<lab-ip> \
  -v "$PWD":/vhs -v ~/dcvm-demo/key:/vhs/key:ro -w /vhs \
  dcvm-vhs:0.12.1 docs/demo/hero.tape
```

Take a libvirt snapshot of the lab VM before each take
(`virsh snapshot-create-as lab hero-ready`) and roll back with
`virsh snapshot-revert lab hero-ready` to record it again.

**Check every GIF** before committing it: look at the last frame and a
contact sheet of the whole recording for wrapped lines, leaked setup
commands, empty output or errors.

```bash
ffmpeg -v error -sseof -1 -i docs/demo/hero.gif -update 1 last.png
ffmpeg -v error -i docs/demo/hero.gif -vf "fps=1/2,scale=600:-1,tile=4x4" -frames:v 1 sheet.png
```

**Shrink them** with `docs/demo/shrink.sh` (ffmpeg, available in the VHS
image): 8 fps and a 64-colour palette built from all pixels, and for the
installer recording 1 fps during the scrolling `apt` part.

```bash
docker run --rm -v "$PWD":/vhs -w /vhs --entrypoint bash dcvm-vhs:0.12.1 docs/demo/shrink.sh
```

That gives about 280 KB for the hero, 0.7-1.1 MB for the scrolling backup and
day-to-day GIFs and 3.2 MB for the installer.
