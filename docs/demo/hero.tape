# Hero: one command gives you a ready Ubuntu VM with nginx, reachable over SSH.
# Real time. Only the wait for first boot (cloud-init installing packages) is
# cut, and the tape says so on screen.
Output docs/demo/hero.gif
Source docs/demo/_style.tape
Source docs/demo/_login.tape

Type 'dcvm create web -f -p "$VM_PASSWORD" -k nginx --ip 10.10.10.50'
Sleep 600ms
Enter
Wait+Line@5m /lab#\s*$/
Sleep 7s

# Hidden: wait until cloud-init has installed nginx, then start a clean screen.
Hide
Type "until curl -sf -o /dev/null 10.10.10.50; do sleep 3; done; clear"
Enter
Wait+Line@15m /^lab#\s*$/
Show

Type "# first boot finished: cloud-init installed nginx (~1 min, cut)"
Sleep 400ms
Enter
Sleep 1s
Type "curl -s 10.10.10.50"
Sleep 400ms
Enter
Sleep 3s
Type "ssh ubuntu@10.10.10.50 'cat /etc/issue.net; systemctl is-active nginx'"
Sleep 400ms
Enter
Wait+Line@30s /lab#\s*$/
Sleep 7s
