# Project Structure

This document describes the organization of the DCVM project.

## Directory Layout

```
dcvm/
├── dcvm                          # Main CLI entry point (repo root)
├── lib/                          # Core library functions
│   ├── core/                     # Core VM operations
│   │   ├── create-vm.sh          # VM creation with cloud-init
│   │   ├── custom-iso.sh         # VM creation from custom ISO
│   │   ├── delete-vm.sh          # VM deletion script
│   │   └── vm-manager.sh         # VM management (start, stop, list, etc.)
│   ├── network/                  # Network management
│   │   ├── network-manager.sh    # Network information and routing
│   │   ├── port-forward.sh       # Port forwarding management
│   │   └── dhcp.sh               # DHCP management
│   ├── storage/                  # Storage & backup
│   │   ├── backup.sh             # Backup and restore operations
│   │   └── storage-manager.sh    # Storage monitoring and cleanup
│   ├── installation/             # Install / update / uninstall
│   │   ├── install-dcvm.sh       # Main installer
│   │   ├── self-update.sh        # Self-update functionality
│   │   └── uninstall-dcvm.sh     # Uninstaller
│   └── utils/                    # Utility functions
│       ├── common.sh             # Shared functions (logging, validation, etc.)
│       ├── dcvm-completion.sh    # Shell completion script
│       ├── fix-lock.sh           # Resource lock fixing
│       ├── mirror-manager.sh     # Template/mirror management
│       └── test-suite.sh         # Repository test suite
├── docs/                         # Documentation
│   ├── installation.md
│   ├── usage.md
│   ├── networking.md
│   ├── backups.md
│   ├── troubleshooting.md
│   ├── project-structure.md
│   ├── CODE-ORGANIZATION.md
│   └── examples/
│       ├── basic-vm-creation.md
│       └── advanced-networking.md
├── .github/workflows/            # CI (lint, format, test, version-bump)
├── CHANGELOG.md
├── CONTRIBUTING.md
├── README.md
├── LICENSE
└── .gitignore
```

## Component Descriptions

### `dcvm` (repo root)
The main command-line interface and single entry point for all DCVM operations.
It routes commands to the appropriate scripts in `lib/`.

### `lib/`
Core functionality organized by category:

#### `lib/core/`
Essential VM operations:
- **create-vm.sh** - Creates new VMs with cloud-init support
- **custom-iso.sh** - Creates VMs from custom installer ISOs (Windows, Arch, etc.)
- **delete-vm.sh** - Safely removes VMs
- **vm-manager.sh** - Controls VM lifecycle (start, stop, restart, console, list)

#### `lib/network/`
Network-related utilities:
- **network-manager.sh** - Network information, routing, and `dcvm network` subcommands
- **port-forward.sh** - Configures and manages NAT port forwarding
- **dhcp.sh** - Shows and cleans DHCP leases

#### `lib/storage/`
Storage and backup management:
- **backup.sh** - Creates and restores VM backups
- **storage-manager.sh** - Monitors disk usage and performs cleanup

#### `lib/utils/`
Shared utilities and helpers:
- **common.sh** - Common functions (logging, validation, config loading)
- **dcvm-completion.sh** - Shell completion script
- **fix-lock.sh** - Fixes resource locks
- **mirror-manager.sh** - Template/mirror download and speed tests
- **test-suite.sh** - Repository test suite (`--quick`, `--full`, etc.)

### `lib/installation/`
Installation and removal scripts:
- **install-dcvm.sh** - Installs DCVM, dependencies, and configuration
- **self-update.sh** - Updates DCVM to the latest version from GitHub
- **uninstall-dcvm.sh** - Removes DCVM completely. **Destructive:** deletes all DCVM VMs (including their storage) and removes `DATACENTER_BASE` (including all backups)

### `docs/`
Project documentation:
- **installation.md** - Installation instructions
- **usage.md** - Usage guide with commands
- **networking.md** / **backups.md** / **troubleshooting.md** - Topic guides
- **project-structure.md** / **CODE-ORGANIZATION.md** - Architecture notes
- **examples/** - Practical examples and tutorials

### Runtime paths (not in the repo)
Installed hosts keep config in `/etc/dcvm-install.conf`. Cloud images live under
`$DATACENTER_BASE/storage/templates` (downloaded at install or first create).
Automated checks live in `lib/utils/test-suite.sh` rather than a top-level
`tests/` tree.

## File Naming Conventions

- **Scripts**: Use kebab-case (e.g., `create-vm.sh`, `port-forward.sh`)
- **Documentation**: Use kebab-case (e.g., `installation.md`, `basic-vm-creation.md`)
- **Configuration**: Use kebab-case with `.conf` extension

## Command Flow

When a user runs `dcvm <command>`, the flow is:

1. **dcvm** receives the command
2. Routes to appropriate script in **lib/**
3. Script sources **lib/utils/common.sh** for shared functions
4. Loads configuration from `/etc/dcvm-install.conf`
5. Executes the requested operation
6. Returns status to user

## Configuration Hierarchy

1. System defaults (hardcoded in scripts)
2. `/etc/dcvm-install.conf` (created during installation)
3. Environment variables (if any)
4. Command-line arguments (highest priority)

## Best Practices

### Adding New Features

1. Determine the appropriate directory:
   - Core VM operations → `lib/core/`
   - Network features → `lib/network/`
   - Storage/backup → `lib/storage/`
   - General utilities → `lib/utils/`

2. Create the script with proper shebang and documentation
3. Add route in `dcvm`
4. Update documentation in `docs/`
5. Add examples if applicable

### Modifying Existing Scripts

1. Source `lib/utils/common.sh` for shared functions
2. Use consistent error handling
3. Log important operations
4. Update relevant documentation
5. Test thoroughly

### Documentation

- Keep README.md concise and up-to-date
- Detailed guides go in `docs/`
- Examples in `docs/examples/`
- Comment complex code sections

## Future Enhancements

Planned additions to the structure:

- `contrib/` - Community contributions
- `hooks/` - Git hooks for development
- `logs/` - Log file storage (runtime)
- `man/` - Man pages for dcvm commands

## Related Files

- `.gitignore` - Specifies files to exclude from version control
- `LICENSE` - Project license (defines usage rights)
- `README.md` - Main project documentation and entry point
