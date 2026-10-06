# Contributing to DCVM

Thank you for your interest in contributing to DCVM! This guide will help you understand the project structure and development workflow.

## Project Structure

DCVM follows a modular architecture. Please review [docs/project-structure.md](docs/project-structure.md) for a complete overview.

## Development Setup

### Prerequisites

- Linux system (Ubuntu 20.04+, Debian 11+)
- KVM/QEMU virtualization support
- Root/sudo access
- Git

### Clone and Setup

```bash
git clone https://github.com/metharda/dcvm.git
cd dcvm
```

## Code Organization

### Adding New Features

1. **Determine the correct location:**
   - Core VM operations → `lib/core/`
   - Network features → `lib/network/`
   - Storage/backup → `lib/storage/`
   - Utilities → `lib/utils/`

2. **Create your script:**
   ```bash
   # Example: Adding a new network feature
   touch lib/network/my-feature.sh
   chmod +x lib/network/my-feature.sh
   ```

3. **Script template:**
   ```bash
   #!/bin/bash
   #
   # Description of what this script does
   #

   set -euo pipefail

   # Source common utilities
   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
   source "$SCRIPT_DIR/../utils/common.sh"

   # Load configuration
   load_dcvm_config

   # Your code here
   main() {
       print_info "Starting my feature..."
       # Implementation
       print_success "Feature completed!"
   }

   main "$@"
   ```

4. **Add route in `dcvm`:**
   ```bash
   # In the case statement
   my-feature)
       exec "$LIB_DIR/network/my-feature.sh" "$@"
       ;;
   ```

5. **Update documentation:**
   - Add command to `docs/usage.md`
   - Create example in `docs/examples/` if needed
   - Update README.md if it's a major feature

## Coding Standards

### Bash Best Practices

1. **Use strict mode:**
   ```bash
   set -euo pipefail
   ```

2. **Quote variables:**
   ```bash
   # Good
   echo "$variable"

   # Bad
   echo $variable
   ```

3. **Use functions:**
   ```bash
   my_function() {
       local param="$1"
       # Implementation
   }
   ```

4. **Error handling:**
   ```bash
   if ! some_command; then
       print_error "Command failed"
       return 1
   fi
   ```

5. **Use common utilities:**
   ```bash
   # Instead of echo
   print_info "Information message"
   print_success "Success message"
   print_warning "Warning message"
   print_error "Error message"

   # Instead of manual checks
   require_root
   check_dependencies virsh qemu-img
   validate_vm_name "$name"
   ```

### File Naming

- Use lowercase with hyphens: `my-script.sh`
- Be descriptive: `setup-port-forwarding.sh`
- Use `.sh` extension for shell scripts

### Comments

```bash
# Single-line comment

# Multi-line comment explaining
# complex logic or important notes
# about the implementation

#
# Section header for major parts
#
```

## Testing

### Manual Testing

```bash
# Run a library script from your clone directly
bash lib/core/your-script.sh

# Test through main CLI (see the warning below if DCVM is installed)
./dcvm your-command
```

### Warning: `./dcvm` from a clone may run the installed code

When `./dcvm` starts, it checks for `/etc/dcvm-install.conf`. If that file
exists (any machine where DCVM is installed), `./dcvm` sources it and sets
`LIB_DIR` to `${DCVM_LIB_DIR:-/usr/local/lib/dcvm}`. It then runs the installed
scripts under `/usr/local/lib/dcvm`, not the `lib/` directory of your clone,
unless you override `DCVM_LIB_DIR`.

The installer never writes `DCVM_LIB_DIR` into `/etc/dcvm-install.conf`, so an
environment variable you set survives `source` and overrides the default. To
test your working copy on a machine with DCVM installed:

```bash
DCVM_LIB_DIR=$PWD/lib ./dcvm your-command
sudo DCVM_LIB_DIR=$PWD/lib ./dcvm your-command
```

You can also run a changed script directly, e.g. `bash lib/core/create-vm.sh ...`
or `bash lib/network/network-manager.sh ...`. Note that most library scripts call
`load_dcvm_config`, which exits if `/etc/dcvm-install.conf` is missing (except
paths that only need `dcvm version` / `dcvm help` via the entry point).

### Repository Test Suite

`lib/utils/test-suite.sh` is the project's test runner. Supported options:

| Flag | What it runs |
|------|--------------|
| `--quick` | Syntax checks, shellcheck, configuration, dependency and `common.sh` function tests. No VM creation, no root required. This is what CI runs. |
| `--full` | Everything in the default run plus the VM lifecycle tests (create, start, stop, delete). Needs root and a working libvirt/QEMU host. |
| `--syntax` | `bash -n` syntax checks and shellcheck only. |
| `--unit` | `common.sh` function tests only (`validate_*`, `format_*`, `generate_*`). |
| `--integration` | libvirt, network, storage, VM listing and VM lifecycle tests. Requires root; the lifecycle tests are skipped unless `--full` is also given. |
| `--verbose`, `-v` | Show detailed output. |
| `--help`, `-h` | Show usage. |

With no flag, the suite runs the quick tests plus the libvirt, directory
structure, CLI, VM listing, network, storage, mirror/template, self-update,
fix-lock and error-handling tests.
It does not run the VM lifecycle tests.

```bash
# Syntax + shellcheck checks
bash lib/utils/test-suite.sh --syntax

# Quick tests (same as CI)
bash lib/utils/test-suite.sh --quick

# Full tests (root + libvirt/qemu host; creates and deletes a test VM)
sudo bash lib/utils/test-suite.sh --full
```

Notes:

- If test dependencies `openssl` or `genisoimage` are missing, the suite tries
  to install those with `apt-get` (as root, or via `sudo`). It does not
  auto-install `shellcheck` or `bc`.
- Suite shellcheck uses `shellcheck --severity=error` on `lib/**/*.sh` only
  (not the top-level `dcvm` entry point). Missing `shellcheck` skips that
  section.
- VM lifecycle tests (`--full`) skip silently when no templates are present
  under `$DATACENTER_BASE/storage/templates`. The create call uses `-o 3`
  (Debian 11 after the 0.9.0 OS menu renumber).

### Requirement: Tests for New Features

All new features or behavioral changes MUST include tests demonstrating the intended behavior.

- Add unit-style checks for small utilities or pure functions (see `test_common_functions` in `lib/utils/test-suite.sh`).
- For CLI behavior, add tests that call the command non-interactively (use `-f`/`--force` where appropriate) and check the expected exit codes and output.
- For changes that touch libvirt/network or storage and cannot run on CI-hosted runners, document how you tested them manually in the PR.

Include the tests in your PR and reference them in the PR description. CI must pass for the PR to be merged.

## CI Rules

Every pull request goes through the GitHub Actions workflows in `.github/workflows/`:

1. **Version bump required** (`version-bump.yaml`, runs on every PR). The
   `dcvm` file must be modified, and the `Version: X.Y.Z` string in
   `show_version()` must be higher than on the base branch. Raising the patch
   number by at least one is enough; raising the minor or major number also
   passes. This applies to documentation-only PRs as well. `dcvm self-update`
   compares this string to decide whether an update is available, so a change
   merged without a bump never reaches existing installs.

   ```bash
   # in dcvm
   show_version() {
     echo "DCVM - Datacenter Virtual Machine Manager"
     echo "Version: X.Y.Z"   # bump this
     ...
   }
   ```

   If two open PRs bump to the same version, the second one to merge must be
   rebased onto the updated `main` and bumped again. Treat that as a manual
   rule: CI does not re-run the version check when `main` moves after your PR
   was opened.

2. **Lint** (`lint.yaml`, on PRs touching `dcvm` or `*.sh`). CI runs
   `bash -n` and `shellcheck -S error` on `dcvm` and every tracked `*.sh`
   file (errors fail the job; warnings are allowed). Run the same checks
   locally before pushing:

   ```bash
   for f in $(git ls-files -- dcvm '*.sh'); do
     bash -n "$f" && shellcheck -S error "$f"
   done
   ```

3. **Formatting** (`format.yaml`). On pull requests, CI runs a check-only
   `shfmt -d` diff (it does not rewrite files or push commits). Format
   locally with `shfmt -i 2 -w` before pushing so the check stays green:

   ```bash
   shfmt -i 2 -w dcvm $(git ls-files -- '*.sh')
   # or verify without writing:
   shfmt -i 2 -d dcvm $(git ls-files -- '*.sh')
   ```

4. **Quick tests** (`test.yaml`, on PRs touching `dcvm` or `*.sh`). Runs
   `bash lib/utils/test-suite.sh --quick` on `ubuntu-latest`, `ubuntu-22.04`
   and in a `debian:bookworm` container.

When you release, also add your changes to `CHANGELOG.md`.

## Documentation

### Required Documentation

1. **Code comments** - Explain complex logic
2. **Function descriptions** - What each function does
3. **Usage examples** - How to use your feature
4. **README updates** - If it's a major feature

### Documentation Guidelines

- Keep language simple and clear
- Include examples for complex features
- Update existing docs if behavior changes
- Add screenshots if relevant (for UI features)

## Pull Request Process

### Before Submitting

1. Test your changes thoroughly
2. Bump the version in `dcvm` (see [CI Rules](#ci-rules))
3. Run `shfmt -i 2` and `shellcheck` on changed scripts
4. Update relevant documentation and `CHANGELOG.md`
5. Check for conflicts with main branch

### PR Template

```markdown
## Description
Brief description of what this PR does.

## Type of Change
- [ ] Bug fix
- [ ] New feature
- [ ] Documentation update
- [ ] Performance improvement
- [ ] Code refactoring

## Testing
Describe how you tested your changes.

## Documentation
- [ ] Updated relevant documentation
- [ ] Added examples if needed
- [ ] Updated README if major feature

## Checklist
- [ ] Code follows project style
- [ ] Comments added for complex logic
- [ ] No new warnings generated
- [ ] Tested on supported platforms
```

## Common Tasks

### Adding a New VM Operation

1. Create script in `lib/core/`:
   ```bash
   vim lib/core/my-operation.sh
   ```

2. Add route in `dcvm`:
   ```bash
   my-operation)
       exec "$LIB_DIR/core/my-operation.sh" "$@"
       ;;
   ```

3. Document in `docs/usage.md`

### Adding a Configuration Option

1. Document the option and how it is stored. Installed hosts keep settings in
   `/etc/dcvm-install.conf` with these keys written by the installer:
   `DATACENTER_BASE`, `NETWORK_NAME`, `BRIDGE_NAME`, and `NETWORK_SUBNET`.
2. Document in `docs/installation.md`
3. Use in scripts via `load_dcvm_config`

### Creating Documentation

1. Determine the right location:
   - Installation → `docs/installation.md`
   - Usage → `docs/usage.md`
   - Examples → `docs/examples/`
   - Architecture → `docs/project-structure.md`

2. Use clear Markdown formatting
3. Include code examples
4. Add to README navigation if needed

## Git Workflow

### Branches

```bash
# Create feature branch
git checkout -b feature/my-feature

# Create bugfix branch
git checkout -b fix/bug-description
```

### Commits

```bash
# Use descriptive commit messages
git commit -m "Add port forwarding for HTTPS"
git commit -m "Fix VM deletion error handling"
git commit -m "Update usage documentation"
```

### Commit Message Format

```
<type>: <subject>

<body>

<footer>
```

**Types:**

- `feat:` New feature
- `fix:` Bug fix
- `docs:` Documentation
- `style:` Formatting
- `refactor:` Code refactoring
- `test:` Tests
- `chore:` Maintenance

**Example:**

```
feat: Add automated backup scheduling

- Implement cron job for daily backups
- Add configuration options for backup schedule
- Update backup.sh with scheduling logic

Closes #123
```

## Questions?

- 📖 Review [docs/project-structure.md](docs/project-structure.md)
- 💬 Open a GitHub issue
- 📧 Contact maintainers

## Code of Conduct

- Be respectful and inclusive
- Provide constructive feedback
- Help others learn and grow
- Focus on the code, not the person

## License

By contributing, you agree that your contributions will be licensed under the same license as the project.

---

Thank you for contributing to DCVM!
