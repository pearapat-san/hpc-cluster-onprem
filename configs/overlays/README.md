# Warewulf Site Overlays

Site overlays deliver node-specific configuration and services to stateless
nodes at provision time. On the master they live under `/srv/warewulf/overlays`.

Assign overlays with `wwctl node set` — note that `-O` **replaces** the entire
overlay list, so always pass the full set:

```bash
wwctl node set compute -O slurm,lustre-client
wwctl node set lustre  -O lustre-srv
wwctl overlay build
```

## Overlays in this cluster

| Overlay | Assigned to | Purpose |
|---------|-------------|---------|
| `slurm` | compute | slurmd config + MUNGE key so the node joins the Slurm cluster |
| `lustre-client` | compute | Lustre client mount of `192.168.200.12@tcp:/lustre` at `/mnt/lustre` (with a retry service for boot-order races) |
| `lustre-srv` | lustre | Lustre server (MGS + MDS + OSS) on the ZFS `lustre-pool` |

> **Do not commit secrets.** The `slurm` overlay normally carries the shared
> `munge.key`. Keep it out of git (see `.gitignore`) and distribute it out of band.

Overlay template files use the `.ww` extension and are rendered per node with
Warewulf's templating (e.g. `{{ .Ipaddr }}`). Export the real overlay trees with:

```bash
wwctl overlay list -a
# then copy /srv/warewulf/overlays/<name>/ here, minus any keys/secrets
```
