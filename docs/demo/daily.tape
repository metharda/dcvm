# Day to day: list VMs, open SSH/HTTP ports to the LAN, check them, stop and
# delete a VM. Real time, nothing cut.
Output docs/demo/daily.gif
Source docs/demo/_style.tape
Source docs/demo/_login.tape

Type "dcvm list"
Sleep 400ms
Enter
Sleep 4s
Type "dcvm network ports setup"
Sleep 400ms
Enter
Wait+Line@2m /lab#\s*$/
Sleep 7s
Type "dcvm network ports test"
Sleep 400ms
Enter
Wait+Line@1m /lab#\s*$/
Sleep 5s
Type "dcvm stop ctf"
Sleep 400ms
Enter
Wait+Line@1m /lab#\s*$/
Sleep 2s
Type "dcvm delete ctf"
Sleep 400ms
Enter
Wait+Line@2m /lab#\s*$/
Sleep 7s
