# Hidden: log in to the recording host ($LAB_HOST, passed with docker -e) and
# set a plain prompt. VM_PASSWORD is read from a root-only file on the host,
# so no password is ever typed on camera.
Hide
Type "ssh -q -t -i /vhs/key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$LAB_HOST"
Enter
Sleep 3s
Type "export PS1='lab# ' LANG=${LANG:-C.UTF-8}; [ -f /root/.demo-pass ] && export VM_PASSWORD=$(cat /root/.demo-pass); clear"
Enter
Sleep 1s
Show
