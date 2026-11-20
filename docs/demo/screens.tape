# Screenshots of every long dcvm screen, to review output changes before
# recording the GIFs. Run by .github/workflows/demos.yml; installs dcvm from
# the checkout copied to /root/dcvm-src.
Output screens/screens.gif
Source docs/demo/_style.tape
Set Height 1000
Source docs/demo/_login.tape

Type "bash /root/dcvm-src/lib/installation/install-dcvm.sh"
Sleep 300ms
Enter
Wait+Line@60s /Install directory.*:\s*$/
Enter
Wait+Line /Network name.*:\s*$/
Enter
Wait+Line /Bridge name.*:\s*$/
Enter
Wait+Line /Network subnet.*:\s*$/
Enter
Wait+Line@15m /#\?\s*$/
Type "2"
Enter
Wait+Line@5m /\[Y\/n\]:\s*$/
Enter
Wait+Line@1m /\[y\/N\]:\s*$/
Enter
Wait+Line@5m /lab#\s*$/
Sleep 1s
Screenshot screens/1-install.png

Hide
Type "export VM_PASSWORD=$(cat /root/.demo-pass); dcvm template download ubuntu-24.04-server-cloudimg-amd64.img >/dev/null 2>&1; dcvm template download debian-13-genericcloud-amd64.qcow2 >/dev/null 2>&1; clear"
Enter
Wait+Line@10m /^lab#\s*$/
Show
Type `dcvm create web -f -p "$VM_PASSWORD" -k nginx --ip 10.10.10.50`
Enter
Wait+Line@5m /lab#\s*$/
Sleep 1s
Screenshot screens/2-create.png

Hide
Type `clear; dcvm create ctf -f -p "$VM_PASSWORD" -o 1 >/dev/null 2>&1; until curl -sf -o /dev/null 10.10.10.50; do sleep 3; done; sleep 40; clear`
Enter
Wait+Line@15m /^lab#\s*$/
Show
Type "dcvm list"
Enter
Wait+Line@1m /lab#\s*$/
Type "dcvm status"
Enter
Wait+Line@1m /lab#\s*$/
Sleep 1s
Screenshot screens/3-list-status.png

Hide
Type "clear"
Enter
Show
Type "dcvm network ports setup"
Enter
Wait+Line@3m /lab#\s*$/
Type "dcvm network ports test"
Enter
Wait+Line@1m /lab#\s*$/
Sleep 1s
Screenshot screens/4-ports.png

Hide
Type "clear"
Enter
Show
Type "dcvm backup create web"
Enter
Wait+Line@5m /lab#\s*$/
Sleep 1s
Screenshot screens/5-backup.png

Hide
Type "until ssh -o ConnectTimeout=2 ubuntu@10.10.10.50 true 2>/dev/null; do sleep 2; done; clear"
Enter
Wait+Line@5m /^lab#\s*$/
Show
Type "dcvm backup restore web"
Enter
Wait+Line@2m /type .yes. to confirm\):\s*$/
Type "yes"
Enter
Wait+Line@10m /lab#\s*$/
Sleep 1s
Screenshot screens/6-restore.png

Hide
Type "clear"
Enter
Show
Type "dcvm delete ctf"
Enter
Wait+Line@3m /lab#\s*$/
Sleep 1s
Screenshot screens/7-delete.png
