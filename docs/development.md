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
- Output goes through the helpers in `common.sh`, so every command looks the
  same: a `ui_title`, one `ui_step` per step (wrap slow commands in `ui_run`),
  then `ui_done` or a `ui_box`, and `ui_next`. Listings are a `ui_title` and
  a `ui_table` (or `ui_kv`), with `ui_section` between parts; help texts go
  through `ui_help`. Colour only on a terminal and
  never without a symbol or word next to it; keep `ui_box` rows ASCII.
  Errors and warnings always print; detail lines go through `print_info`,
  which `ui_quiet` hides unless `DCVM_VERBOSE=1`.
- Validate user input with the `validate_*` helpers before writing anything.
- Two-space indentation, kebab-case file names.
- Anything that runs inside the guest goes into the cloud-init `user-data`;
  passwords go in only as hashes (see [security.md](security.md)).

## Shared helpers

`lib/utils/common.sh` is the one place for logic used by more than one
script; the installer sources it too (from the checkout, or fetched from the
same branch when it runs on its own). Reuse these before writing new code.
Image downloads have one module, `lib/utils/mirror-manager.sh`
(`rank_mirrors`, `download_with_mirrors`, `download_image_ui` with its
progress view, `image_label`), sourced by `create`, `backup`, the installer
and `dcvm template`.

| Area | Functions |
| :--- | :-------- |
| Output and logs | `print_info`, `print_success`, `print_warning`, `print_error`, `print_status`, `log`, `log_to_file` |
| Screens | `ui_title`, `ui_section` (heading inside a screen), `ui_step` (one line per step), `ui_run` (spinner around a slow command), `ui_kv` (label and value lines), `ui_table` (tab-separated rows), `ui_box` (key result), `ui_done` (result line), `ui_next` (next steps), `ui_help` (colours a help text), `ui_quiet` (hide info/success lines; `DCVM_VERBOSE=1` shows them), `confirm_action` (y/N question) |
| Live output | `ui_live` (can we draw?), `ui_watch` (redraw while a background job runs), `ui_spin` / `ui_spin_clear` (spinner line), `ui_bar` (progress bar) |
| Formatting | `plural` (`3 VMs`), `format_bytes` (`6.9 GB`), `file_bytes` |
| Repository | `fetch_repo_file`, `list_repo_files` (the installer and `self-update` download dcvm with them) |
| Config and checks | `load_dcvm_config`, `require_root`, `command_exists`, `check_dependencies` |
| Validation | `validate_vm_name`, `validate_vm_name_list`, `validate_username`, `validate_password`, `validate_package_list`, `validate_ip_in_subnet`, `validate_memory_size`, `validate_cpu_count`, `validate_disk_size`, `trim_whitespace` |
| VMs | `list_datacenter_vm_names`, `check_vm_exists`, `get_vm_state`, `get_vm_ip`, `get_vm_mac`, `get_vm_disk_path`, `get_vm_username`, `default_username`, `list_datacenter_vms`, `is_vm_in_network`, `stop_vm_gracefully` |
| Network | `get_port_mappings_file`, `read_port_mappings`, `check_port_forward`, `check_port_connectivity`, `check_ping`, `get_host_ip`, `detect_host_ip`, `save_iptables_rules` |
| DHCP | `leases_table`, `filter_lease_lines`, `cleanup_dhcp_lease` (locked), `cleanup_dhcp_lease_unlocked` |
| Credentials | `read_password` (no echo), `generate_password_hash` (SHA-512 crypt), `generate_random_mac` |
| Prompts | `interactive_prompt_memory_common`, `interactive_prompt_cpus_common`, `interactive_prompt_disk_common`, `interactive_prompt_static_ip_common`, `confirm_action`, `require_confirmation` |

## Recording the demos

The GIFs in the README are recorded from real sessions with
[VHS](https://github.com/charmbracelet/vhs) v0.12.1. Each `docs/demo/*.tape`
types real commands into a real dcvm host; nothing is mocked. Waits for a VM
to boot are hidden, and each GIF says so in its caption or on screen.

They are recorded on a GitHub-hosted runner by
[`.github/workflows/demos.yml`](../.github/workflows/demos.yml): the runner is
a fresh Ubuntu 24.04 VM with KVM, so it serves as the dcvm host and is thrown
away afterwards. Run it from the Actions tab (*Record demos*) or with:

```bash
gh workflow run demos.yml -f tapes="hero backup daily"   # README GIFs from this checkout
gh workflow run demos.yml -f tapes=quickstart            # install GIF; installs from main
gh workflow run demos.yml -f tapes=screens               # screenshots of every long screen
gh run download --name demos                             # GIFs and screenshots
```

| Tape | GIF | Starting state (set by `docs/demo/prepare.sh`) |
| :--- | :-- | :--------------------------------------------- |
| `hero.tape` | `hero.gif` | dcvm installed from the checkout, Ubuntu 24.04 image downloaded, no VMs |
| `backup.tape` | `backup.gif` (3x playback) | `web` from `hero.tape`, booted |
| `daily.tape` | `daily.gif` | `web` and `ctf` (Debian 13) running |
| `quickstart.tape` | `quickstart.gif` (4x playback) | A fresh runner; it runs the README one-liner, so it shows `main` |
| `screens.tape` | screenshots | A fresh runner; installs from the checkout |

`_style.tape` holds the shared look (JetBrains Mono 16, 1200x720, Catppuccin
Mocha, colourful window bar, teal margin) and `_login.tape` the hidden SSH
login to `$LAB_HOST`, which sets a plain `lab# ` prompt and exports
`VM_PASSWORD` from a root-only file, so no password is typed on camera. The
same tapes work against any dcvm host you can SSH into as root: put the key in
`./key` and run
`docker run --rm --network host -e LAB_HOST=<host> -v "$PWD":/vhs -w /vhs <vhs image with openssh-client> docs/demo/hero.tape`.

**Check every GIF** before committing it: look at the last frame and a
contact sheet of the whole recording for wrapped lines, leaked setup
commands, empty output or errors.

```bash
ffmpeg -v error -sseof -1 -i docs/demo/hero.gif -update 1 last.png
ffmpeg -v error -i docs/demo/hero.gif -vf "fps=1/2,scale=600:-1,tile=4x4" -frames:v 1 sheet.png
```

The workflow runs `docs/demo/shrink.sh` on each GIF: 20 fps keeps typing and
spinners smooth, and a 64-colour palette built from all pixels keeps the
coloured labels.
