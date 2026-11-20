# Advanced Networking Examples

See [Networking](../networking.md) for how port forwarding works.

## Custom port mappings
`dcvm network ports setup` writes `$DATACENTER_BASE/port-mappings.txt`, one
line per VM: name, VM IP, host port for SSH (to port 22), host port for HTTP
(to port 80).
```
# VM_NAME VM_IP SSH_PORT HTTP_PORT
webserver 10.10.10.50 2221 8081
dbserver 10.10.10.51 2222 8082
```
To pick your own host ports, edit the file and apply it:
```bash
dcvm network ports apply
```
Only ports 22 and 80 on the VM can be forwarded this way. `ports setup`
rewrites the file, so run `apply` (not `setup`) after editing it.

## Verify rules
```bash
dcvm network ports show    # the saved table
dcvm network ports rules   # the iptables DNAT rules
```

## Test connectivity
```bash
dcvm network ports test
```

## Remove all forwarding rules
```bash
dcvm network ports clear
```
