# Quick start: install dcvm on a fresh Ubuntu 24.04 host with the README one-liner.
# Recorded at real speed and played back 4x faster (package install takes a few minutes).
Output docs/demo/quickstart.gif
Source docs/demo/_style.tape
Set PlaybackSpeed 4
Source docs/demo/_login.tape

Type 'bash -c "$(curl -fsSL https://raw.githubusercontent.com/metharda/dcvm/main/lib/installation/install-dcvm.sh)"'
Sleep 6s
Enter
# Accept the defaults: /srv/datacenter, datacenter-net, virbr-dc, 10.10.10.0/24
Wait+Line@60s /Install directory.*:\s*$/
Sleep 9s
Enter
Wait+Line /Network name.*:\s*$/
Sleep 6s
Enter
Wait+Line /Bridge name.*:\s*$/
Sleep 6s
Enter
Wait+Line /Network subnet.*:\s*$/
Sleep 6s
Enter
# Cloud images: download on first `dcvm create` instead of all eight now
Wait+Line@15m /#\?\s*$/
Sleep 12s
Type "2"
Sleep 1s
Enter
# Tab completion: yes (default)
Wait+Line@5m /\[Y\/n\]:\s*$/
Sleep 8s
Enter
# NFS shared folder: no (default)
Wait+Line@1m /\[y\/N\]:\s*$/
Sleep 8s
Enter
Wait+Line@5m /lab#\s*$/
Sleep 20s
Type "dcvm version"
Sleep 500ms
Enter
Sleep 18s
