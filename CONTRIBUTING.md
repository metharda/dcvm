# Contributing to DCVM

Thank you for your interest in contributing to DCVM! This guide will help you understand the project structure and development workflow.

## Project Structure

DCVM follows a modular architecture. Please review [docs/project-structure.md](project-structure.md) for a complete overview.

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

4. **Add route in `bin/dcvm`:**
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
# Test your changes
sudo bash lib/core/your-script.sh

# Test through main CLI
sudo ./bin/dcvm your-command
```

### Future: Automated Tests
When test framework is implemented:
```bash
# Run unit tests
./tests/unit/test-your-feature.sh

# Run integration tests
./tests/integration/test-your-feature.sh
```

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
2. Update relevant documentation
3. Follow coding standards
4. Check for conflicts with main branch

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

2. Add route in `bin/dcvm`:
   ```bash
   my-operation)
       exec "$LIB_DIR/core/my-operation.sh" "$@"
       ;;
   ```

3. Document in `docs/usage.md`

### Adding a Configuration Option

1. Add to `config/dcvm.conf.example`
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

- 📖 Review [docs/project-structure.md](project-structure.md)
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
