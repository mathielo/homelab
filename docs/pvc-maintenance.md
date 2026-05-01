# PVC Maintenance

PVCs can't be touched while there are pods bound to them. Services are managed by ArgoCD and are set to `self-heal`, so a few triggers need to be disabled before any changes can be made to PVCs.

## Stopping pods safely with ArgoCD

ArgoCD's `selfHeal: true` will immediately undo a manual `scale --replicas=0`. The auto-sync policy must be removed first:

```bash
# 1. Strip auto-sync (can list multiple app names in one command)
kubectl -n argocd patch application <app> --type merge -p '{"spec":{"syncPolicy":null}}'

# 2. Scale down
kubectl -n <namespace> scale deploy/<app> --replicas=0

# To stop all media and dashboard apps at once:
kubectl -n argocd patch application autobrr bazarr plex prismarr prowlarr \
  qbittorrent radarr sabnzbd searcharr seerr sonarr watchlistarr uptime-kuma \
  --type merge -p '{"spec":{"syncPolicy":null}}'
kubectl -n media scale deploy --all --replicas=0
kubectl -n dashboard scale deploy --all --replicas=0
```

## Restoring pods

To restore auto-sync after changes are committed and pushed, re-enable via the ArgoCD UI (Application → "Enable Auto-Sync") or:

```bash
kubectl -n argocd patch application <app> --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true},"syncOptions":["CreateNamespace=true"]}}}'
```
