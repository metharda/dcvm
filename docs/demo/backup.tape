# Key property: a backup brings a broken VM back exactly as it was.
# Recorded at real speed and played back 3x faster. The two waits for the VM
# to boot again (after the backup and after the restore) are cut.
Output docs/demo/backup.gif
Source docs/demo/_style.tape
Set PlaybackSpeed 3
Source docs/demo/_login.tape

# Scene 1: some data worth keeping, then a backup
Type "ssh ubuntu@10.10.10.50 'echo flag{keep-me} > notes.txt'"
Sleep 400ms
Enter
Wait+Line@30s /lab#\s*$/
Sleep 1s
Type "dcvm backup create web"
Sleep 400ms
Enter
Wait+Line@5m /lab#\s*$/
Sleep 12s

Hide
Type "until ssh -o ConnectTimeout=2 ubuntu@10.10.10.50 true 2>/dev/null; do sleep 2; done; clear"
Enter
Wait+Line@5m /^lab#\s*$/
Show

# Scene 2: break it, then restore
Type "# oops: delete the web root and the notes"
Sleep 400ms
Enter
Type "ssh ubuntu@10.10.10.50 'sudo rm -rf /var/www/html notes.txt'"
Sleep 400ms
Enter
Wait+Line@30s /lab#\s*$/
Type "curl -sI 10.10.10.50 | head -1"
Sleep 400ms
Enter
Sleep 4s
Type "dcvm backup restore web"
Sleep 400ms
Enter
Wait+Line@2m /type 'yes' to confirm\):\s*$/
Sleep 3s
Type "yes"
Sleep 600ms
Enter
Wait+Line@10m /lab#\s*$/
Sleep 12s

Hide
Type "until ssh -o ConnectTimeout=2 ubuntu@10.10.10.50 true 2>/dev/null && curl -sf -o /dev/null 10.10.10.50; do sleep 2; done; clear"
Enter
Wait+Line@5m /^lab#\s*$/
Show

# Scene 3: everything is back
Type "# VM booted from the restored disk"
Sleep 400ms
Enter
Type "curl -sI 10.10.10.50 | head -1"
Sleep 400ms
Enter
Sleep 2s
Type "ssh ubuntu@10.10.10.50 cat notes.txt"
Sleep 400ms
Enter
Wait+Line@30s /lab#\s*$/
Sleep 15s
