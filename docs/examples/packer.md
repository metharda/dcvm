# Packer Integration with DCVM

This guide explains how to build QEMU images (qcow2/raw) with Packer and automatically import them into DCVM.

## Quick start

```bash
# Validate and init
dcvm packer validate --template build.ubuntu-22_04.pkr.hcl
dcvm packer init --template build.ubuntu-22_04.pkr.hcl

# Build + auto-import into a VM
sudo dcvm packer build runner-ubuntu2204 \
  --template build.ubuntu-22_04.pkr.hcl \
  --only qemu.ubuntu-22_04 \
  --var-file values.pkrvars.hcl \
  --os-variant ubuntu22.04 \
  -m 8192 -c 4
```

- `runner-ubuntu2204`: Name of the VM to create.
- After the Packer build completes, DCVM locates the newest qcow2/raw artifact and imports it with `dcvm import-image`.

If the artifact cannot be auto-detected, pass it explicitly with `--artifact /path/to/output.qcow2`.

## Options
- `--only`: Run only the specified QEMU builder target (e.g., `qemu.ubuntu-22_04`).
- `--var-file` and `--var`: Packer variables.
- `--os-variant`: libosinfo OS variant (e.g., ubuntu22.04, debian12).
- `--attach-cidata`: Attach an empty cloud-init ISO to the resulting VM.

## Notes
- DCVM requires a Linux host with KVM/libvirt.
- You can build images with Packer on macOS, but the VM will run on Linux/KVM where DCVM is installed.
- If your build outputs land in custom folders, specify the exact file with `--artifact`.
