# Project Structure

This document describes the organization of the DCVM project.

## Directory Layout

```
dcvm/
├── bin/                          # Executable binaries
│   └── dcvm                      # Main CLI entry point
│
├── lib/                          # Core library functions
│   ├── core/                    # Core VM operations
│   │   ├── create-vm.sh         # VM creation script
│   │   ├── delete-vm.sh         # VM deletion script
│   │   └── vm-manager.sh        # VM management (start, stop, list, etc.)
│   │
│   ├── network/                 # Network management
│   │   ├── port-forward.sh      # Port forwarding management
│   │   └── dhcp.sh              # DHCP management
│   │
│   ├── storage/                 # Storage & backup
│   │   ├── backup.sh            # Backup and restore operations
│   │   └── storage-manager.sh   # Storage monitoring and cleanup
│   │
│   └── utils/                   # Utility functions
│       ├── common.sh            # Shared functions (logging, validation, etc.)
│       └── fix-lock.sh          # Resource lock fixing
│
├── lib/installation/             # Installation related files
│   ├── install-dcvm.sh          # Main installer
│   └── uninstall-dcvm.sh        # Uninstaller
│
├── config/                       # Configuration templates and examples
│   ├── dcvm.conf.example        # Main configuration example
│   └── network.conf.example     # Network configuration example
│
├── templates/                    # (Deprecated placeholder)
│   └── .gitkeep                 # Cloud images are stored at runtime under $DATACENTER_BASE/storage/templates
│
├── docs/                         # Documentation
│   ├── installation.md          # Installation guide
│   ├── usage.md                 # Usage guide
│   └── examples/                # Usage examples
│       └── basic-vm-creation.md # Basic VM creation examples
│
├── tests/                        # Test scripts
│   ├── unit/                    # Unit tests (future)
│   │   └── .gitkeep
│   └── integration/             # Integration tests (future)
│       └── .gitkeep
│
├── README.md                     # Main project documentation
├── LICENSE                       # License file
└── .gitignore                    # Git ignore rules
```

## Component Descriptions

### `bin/`
Contains the main `dcvm` command-line interface. This is the single entry point for all DCVM operations.

**Key file:**
- `dcvm` - Routes commands to appropriate scripts in `lib/`

### `lib/`
Core functionality organized by category:

#### `lib/core/`
Essential VM operations:
- **create-vm.sh** - Creates new VMs with cloud-init support
- **delete-vm.sh** - Safely removes VMs
- **vm-manager.sh** - Controls VM lifecycle (start, stop, restart, console, list)

#### `lib/network/`
Network-related utilities:
- **port-forward.sh** - Configures and manages NAT port forwarding
- **dhcp.sh** - Shows and cleans DHCP leases

#### `lib/storage/`
Storage and backup management:
- **backup.sh** - Creates and restores VM backups
- **storage-manager.sh** - Monitors disk usage and performs cleanup

#### `lib/utils/`
Shared utilities and helpers:
- **common.sh** - Common functions (logging, validation, config loading)
- **fix-lock.sh** - Fixes resource locks

### `lib/installation/`
Installation and removal scripts:
- **install-dcvm.sh** - Installs DCVM, dependencies, and configuration
- **uninstall-dcvm.sh** - Removes DCVM and optionally cleans up data

### `config/`
Configuration file templates and examples:
- **dcvm.conf.example** - Main configuration template
- **network.conf.example** - Network configuration template

Users can copy these to `/etc/` and customize as needed.

### `templates/`
Deprecated in repository. Cloud images are downloaded to `$DATACENTER_BASE/storage/templates` during runtime by the installer or on first VM creation.

### `docs/`
Comprehensive documentation:
- **installation.md** - Detailed installation instructions
- **usage.md** - Complete usage guide with all commands
- **examples/** - Practical examples and tutorials

### `tests/`
Test suite (planned for future development):
- **unit/** - Unit tests for individual functions
- **integration/** - End-to-end integration tests

## File Naming Conventions

- **Scripts**: Use kebab-case (e.g., `create-vm.sh`, `port-forward.sh`)
- **Documentation**: Use kebab-case (e.g., `installation.md`, `basic-vm-creation.md`)
- **Configuration**: Use kebab-case with `.conf` extension

## Command Flow

When a user runs `dcvm <command>`, the flow is:

1. **bin/dcvm** receives the command
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
3. Add route in `bin/dcvm`
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
