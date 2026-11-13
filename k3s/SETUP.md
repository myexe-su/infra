## Namespaces

| Namespace | Contents |
|-----------|----------|
| `common` | Shared services for all projects: PostgreSQL, Redis, SeaweedFS, MongoDB, RabbitMQ, Keycloak, Vault |
| `gitlab` | GitLab |
| `argocd` | Argo CD |
| `gitlab-runners` | CI job pods (and Runner manager) |
| `monitoring` | Prometheus, Grafana, Loki |
| `linkerd` | Linkerd |

Project-specific services are deployed in their own namespaces. Secrets do not cross namespaces: GitLab's secrets (DB password, S3 keys) are created in `gitlab`, the services they point to live in `common`.

## Configs

All commands below are run on the server from the `k3s` directory of this repository (they use relative paths like `helm/...`). Copy it from the client first:

```bash
scp -r k3s myexe@192.168.1.3:~/
```

```bash
cd ~/k3s
```

## Firewalld (Fedora)

k3s uses Flannel for pod networking. Fedora's firewalld blocks pod-to-pod traffic by default — fix it before installing k3s:

```bash
sudo firewall-cmd --zone=trusted --add-interface=flannel.1 --permanent
sudo firewall-cmd --zone=trusted --add-source=10.42.0.0/16 --permanent
sudo firewall-cmd --reload
```

## k3s

```bash
# k3s-selinux needs to be installed before k3s (slow mirror workaround)
sudo dnf install k3s-selinux

# Install k3s
curl -sfL https://get.k3s.io | sh -

# Copy kubeconfig
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown myexe:myexe ~/.kube/config
chmod 600 ~/.kube/config

# Configure shell
mkdir -p ~/.bashrc.d
echo 'export KUBECONFIG=~/.kube/config' > ~/.bashrc.d/k3s.sh
source ~/.bashrc
```

## k9s

```bash
sudo dnf install k9s
```

## Helm

```bash
sudo dnf install helm
```

## cert-manager

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update

kubectl create namespace cert-manager

helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --values helm/cert-manager/values.yaml

# For local network (no internet)
kubectl apply -f helm/cert-manager/cluster-issuer-local.yaml

# For public server with Let's Encrypt
# kubectl apply -f helm/cert-manager/cluster-issuer-letsencrypt.yaml
```

## PostgreSQL (CloudNativePG)

```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update

helm install cloudnativepg cnpg/cloudnative-pg \
  --namespace cnpg-system \
  --create-namespace

# Wait for the operator, otherwise its webhook is unavailable and the apply below fails
kubectl wait --for=condition=Available deployment --all -n cnpg-system --timeout=180s

kubectl create namespace common
kubectl apply -f helm/cloudnativepg/cluster.yaml
```

## Redis

```bash
helm install redis oci://registry-1.docker.io/bitnamicharts/redis \
  --namespace common \
  --set architecture=standalone \
  --set auth.enabled=false
```

## SeaweedFS (S3)

S3 auth is enabled in `values.yaml`, so the S3 pod will not start until the secret with its users exists. Generate the admin keys and save them in a password manager:

```bash
S3_ACCESS_KEY=$(openssl rand -hex 8)
S3_SECRET_KEY=$(openssl rand -hex 20)
echo "S3_ACCESS_KEY=$S3_ACCESS_KEY S3_SECRET_KEY=$S3_SECRET_KEY"
```

Create the secret first, with one `admin` user and these keys:

```bash
kubectl create secret generic seaweedfs-s3-secret \
  --namespace common \
  --from-literal=seaweedfs_s3_config="$(cat <<EOF
{
  "identities": [
    {
      "name": "admin",
      "credentials": [{"accessKey": "$S3_ACCESS_KEY", "secretKey": "$S3_SECRET_KEY"}],
      "actions": ["Read", "Write", "List", "Tagging", "Admin"]
    }
  ]
}
EOF
)"
```

Install SeaweedFS:

```bash
helm repo add seaweedfs https://seaweedfs.github.io/seaweedfs/helm
helm repo update

helm install seaweedfs seaweedfs/seaweedfs \
  --namespace common \
  --values helm/seaweedfs/values.yaml
```

Wait for the S3 pod:

```bash
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/component=s3 -n common --timeout=300s
```

## GitLab

Gateway API is disabled in `values.yaml` (`gatewayApi.enabled: false`), so the two steps below (policy removal and Envoy CRDs) are probably not needed. Not verified: on a fresh install skip them first, and run them only if `helm install` fails because of missing CRDs.

k3s bundles standard Gateway API CRDs and blocks experimental ones. GitLab requires experimental CRDs — remove the policy before installing:

```bash
kubectl delete validatingadmissionpolicy safe-upgrades.gateway.networking.k8s.io
kubectl delete validatingadmissionpolicybinding safe-upgrades.gateway.networking.k8s.io
```

Install Envoy Gateway CRDs manually (needed by GitLab, skipped via --skip-crds to avoid cert-manager conflict):

```bash
helm pull gitlab/gitlab --untar --untardir ~/gitlab-chart
kubectl apply --server-side -f ~/gitlab-chart/gitlab/charts/gateway-helm/charts/crds/crds/generated/
```

Generate the GitLab database password and its own S3 keys (save them in a password manager; they are used in several steps below, so keep the same shell session or set them again from the saved values):

```bash
GITLAB_PG_PASSWORD=$(openssl rand -hex 16)
GITLAB_S3_ACCESS_KEY=$(openssl rand -hex 8)
GITLAB_S3_SECRET_KEY=$(openssl rand -hex 20)
echo "GITLAB_PG_PASSWORD=$GITLAB_PG_PASSWORD GITLAB_S3_ACCESS_KEY=$GITLAB_S3_ACCESS_KEY GITLAB_S3_SECRET_KEY=$GITLAB_S3_SECRET_KEY"
```

Create the S3 buckets:

```bash
kubectl exec -n common deploy/seaweedfs-s3 -- sh -c "echo '
s3.bucket.create -name gitlab-artifacts
s3.bucket.create -name gitlab-lfs
s3.bucket.create -name gitlab-uploads
s3.bucket.create -name gitlab-packages
s3.bucket.create -name gitlab-registry
exit' | weed shell -master=seaweedfs-master:9333"
```

Create the S3 user `gitlab` with access to these buckets only:

```bash
kubectl exec -n common deploy/seaweedfs-s3 -- sh -c "echo '
s3.configure -user=gitlab -access_key=$GITLAB_S3_ACCESS_KEY -secret_key=$GITLAB_S3_SECRET_KEY -buckets=gitlab-artifacts,gitlab-lfs,gitlab-uploads,gitlab-packages,gitlab-registry -actions=Read,Write,List,Tagging,Admin -apply
exit' | weed shell -master=seaweedfs-master:9333"
```

Create the namespace and secrets:

```bash
kubectl create namespace gitlab

kubectl create secret generic gitlab-postgresql-secret \
  --namespace gitlab \
  --from-literal=postgresql-password="$GITLAB_PG_PASSWORD"

kubectl create secret generic gitlab-s3-secret \
  --namespace gitlab \
  --from-literal=connection="$(cat <<EOF
provider: AWS
region: us-east-1
aws_access_key_id: $GITLAB_S3_ACCESS_KEY
aws_secret_access_key: $GITLAB_S3_SECRET_KEY
aws_signature_version: 4
host: seaweedfs-s3.common.svc.cluster.local
endpoint: http://seaweedfs-s3.common.svc.cluster.local:8333
path_style: true
EOF
)"

kubectl create secret generic gitlab-registry-s3-secret \
  --namespace gitlab \
  --from-literal=config="$(cat <<EOF
s3:
  bucket: gitlab-registry
  accesskey: $GITLAB_S3_ACCESS_KEY
  secretkey: $GITLAB_S3_SECRET_KEY
  regionendpoint: http://seaweedfs-s3.common.svc.cluster.local:8333
  region: us-east-1
  pathstyle: true
EOF
)"
```

Create GitLab DB and user:

```bash
kubectl exec -n common postgres-1 -c postgres -- psql -U postgres -c "CREATE USER gitlab WITH PASSWORD '$GITLAB_PG_PASSWORD';"
kubectl exec -n common postgres-1 -c postgres -- psql -U postgres -c "CREATE DATABASE gitlabhq_production OWNER gitlab;"
```

GitLab is served at `git.home` (registry and kas stay on `s1.home`); all three names must resolve to the node on clients too (router DNS or `/etc/hosts`).

Make these names resolvable inside the cluster (the Runner and other pods need them). k3s CoreDNS reads custom server blocks from a ConfigMap named `coredns-custom` in `kube-system`:

```bash
kubectl create configmap coredns-custom \
  --namespace kube-system \
  --from-literal=s1.home.server='s1.home:53 git.home:53 {
  hosts {
    192.168.1.3 git.home
    192.168.1.3 registry.s1.home
    192.168.1.3 kas.s1.home
    fallthrough
  }
  forward . /etc/resolv.conf
}'
```

CoreDNS picks up the ConfigMap automatically within ~15 seconds (no pod restart needed).

Note: use `.server` extension (new server block), not `.override` (imported inside existing block which already has `hosts` plugin).

Issue the TLS certificate with the local CA (needs `ClusterIssuer local-ca` from the cert-manager step):

```bash
kubectl apply -f helm/gitlab/certificate.yaml
kubectl get certificate -n gitlab   # wait for gitlab-tls READY True
```

Install GitLab (the bundled Runner is disabled, it is installed separately below):

```bash
helm repo add gitlab https://charts.gitlab.io
helm repo update

helm install gitlab gitlab/gitlab \
  --namespace gitlab \
  --values helm/gitlab/values.yaml \
  --skip-crds \
  --timeout 600s
```

Get initial root password:

```bash
kubectl get secret gitlab-gitlab-initial-root-password -n gitlab -ojsonpath='{.data.password}' | base64 --decode
```

## GitLab Runner

Installed as a separate release in `gitlab-runners`; job pods run in the same namespace.

1. Create the Runner in the UI: Admin → CI/CD → Runners → New instance runner (tags optional, "run untagged jobs" on). Copy the token (`glrt-...`).

2. Create the namespace and secrets:

```bash
kubectl create namespace gitlab-runners

kubectl create secret generic gitlab-runner-secret \
  --namespace gitlab-runners \
  --from-literal=runner-token='glrt-...' \
  --from-literal=runner-registration-token=''

# CA that signed gitlab-tls; file name must be <hostname>.crt
kubectl create secret generic gitlab-runner-certs \
  --namespace gitlab-runners \
  --from-literal=git.home.crt="$(kubectl get secret gitlab-tls -n gitlab -o jsonpath='{.data.ca\.crt}' | base64 -d)"
```

3. Install:

```bash
helm install gitlab-runner gitlab/gitlab-runner \
  --namespace gitlab-runners \
  --values helm/gitlab-runner/values.yaml
```

## Argo CD

Installed in `argocd` as Argo CD Core: headless, without API server, UI, Dex and notifications (controller, repo server and ApplicationSet controller). It uses the shared Redis from `common` as a cache. Applications are managed with `kubectl` (`kubectl get applications -n argocd`).

Argo CD fetches manifests from GitLab over SSH (`ssh://git@git.home:2222/...`), so it must know the GitLab host key. Take the key from the GitLab secret and save it in `known_hosts` format (it is passed to the chart as a file):

```bash
kubectl get secret gitlab-gitlab-shell-host-keys -n gitlab -o jsonpath='{.data.ssh_host_ed25519_key\.pub}' | base64 -d | awk '{print "[git.home]:2222", $1, $2}' > /tmp/gitlab-known-hosts
```

Add the Helm repository and install:

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --values helm/argocd/values.yaml \
  --set-file 'configs.ssh.extraHosts=/tmp/gitlab-known-hosts'

kubectl rollout status deployment/argocd-repo-server -n argocd --timeout=300s
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s
```

Without the API server nothing creates the `default` project that applications refer to, so create it:

```bash
kubectl apply -f helm/argocd/default-project.yaml
```
