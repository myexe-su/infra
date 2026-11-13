# Argo CD: connecting a project

Argo CD is installed in [SETUP.md](SETUP.md) (Core, no UI). Each project is a repository with its Kubernetes manifests in the GitLab group `k8s`; Argo CD reads it over SSH and applies it to the cluster. The `Application` that connects a project is a file in [argocd/applications/](argocd/applications/), applied from the server like everything else.

## Once per cluster: access to the group

On the server, create a key pair for Argo CD:

```bash
ssh-keygen -t ed25519 -N "" -C argocd -f /tmp/argocd-key
cat /tmp/argocd-key.pub
```

Add the public key as a deploy key (read-only, no write permissions) to the first project: Settings → Repository → Deploy keys. Then store the private key in the cluster as credentials for the whole group and delete the files:

```bash
kubectl create secret generic k8s-repo-creds -n argocd \
  --from-literal=type=git \
  --from-literal=url=ssh://git@git.home:2222/k8s \
  --from-file=sshPrivateKey=/tmp/argocd-key
kubectl label secret k8s-repo-creds -n argocd argocd.argoproj.io/secret-type=repo-creds
rm /tmp/argocd-key /tmp/argocd-key.pub
```

## For every new project

1. Create the project in the group `k8s` (with a `main` branch, e.g. a README) and put the manifests in it (plain YAML or Kustomize).
2. Enable the existing key in the project: Settings → Repository → Deploy keys → "Privately accessible deploy keys" → Enable on `argocd`.
3. Copy [argocd/applications/template.yaml](argocd/applications/template.yaml) to `argocd/applications/<name>.yaml` and replace the four values in `<angle brackets>`:
   - `<name>`: application name, unique in `argocd`;
   - `<project>`: repository in the group `k8s`;
   - `<path>`: folder with the manifests in the repository (`.` for the root);
   - `<namespace>`: namespace to deploy to (created automatically).
4. Copy `k3s` to the server and apply the file:

```bash
kubectl apply -f argocd/applications/<name>.yaml
```

Changes are synchronized automatically (the repository is polled every 3 minutes). Objects removed from the repository are not deleted from the cluster; add `prune: true` under `automated` to change that.

## Checking

```bash
kubectl get applications -n argocd
kubectl describe application <name> -n argocd | tail -20
```

Force an immediate refresh:

```bash
kubectl annotate application <name> -n argocd argocd.argoproj.io/refresh=hard --overwrite
```

If an application stays in `Unknown` after its problem was fixed, restart the controller: `kubectl rollout restart statefulset/argocd-application-controller -n argocd`.
