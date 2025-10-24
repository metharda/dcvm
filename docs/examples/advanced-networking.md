# Advanced Networking Examples

## Custom port mappings
Edit `$DATACENTER_BASE/port-mappings.txt` and add entries like:
```
# host_port vm_name vm_port proto
2222 webserver 22 tcp
8080 webserver 80 tcp
8443 webserver 443 tcp
```
Then apply:
```bash
sudo dcvm network ports apply
```

## Verify rules
```bash
dcvm network ports show
```

## Test connectivity
```bash
dcvm network ports test
```

## Clear all mappings
```bash
sudo dcvm network ports clear
```
