## Namespaces

| Namespace | Contents |
|-----------|----------|
| `common` | Shared services for all projects: PostgreSQL, Redis, SeaweedFS, MongoDB, RabbitMQ, Keycloak, Vault, Argo CD |
| `gitlab` | GitLab |
| `gitlab-runners` | CI job pods (and Runner manager) |
| `monitoring` | Prometheus, Grafana, Loki |
| `linkerd` | Linkerd |

Project-specific services are deployed in their own namespaces. Secrets do not cross namespaces: GitLab's secrets (DB password, S3 keys) are created in `gitlab`, the services they point to live in `common`.

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

```bash
helm repo add seaweedfs https://seaweedfs.github.io/seaweedfs/helm
helm repo update

helm install seaweedfs seaweedfs/seaweedfs \
  --namespace common \
  --values helm/seaweedfs/values.yaml
```

Create S3 auth secret and buckets:

```bash
kubectl create secret generic seaweedfs-s3-secret \
  --namespace common \
  --from-literal=seaweedfs_s3_config='{
  "identities": [
    {
      "name": "gitlab",
      "credentials": [{"accessKey": "gitlab-access-key", "secretKey": "gitlab-secret-key"}],
      "actions": ["Read", "Write", "List", "Tagging", "Admin"]
    }
  ]
}'

kubectl exec -n common -l app.kubernetes.io/component=s3 -- sh -c "echo '
s3.bucket.create -name gitlab-artifacts
s3.bucket.create -name gitlab-lfs
s3.bucket.create -name gitlab-uploads
s3.bucket.create -name gitlab-packages
s3.bucket.create -name gitlab-registry
exit' | weed shell -master=seaweedfs-master:9333"
```

## CoreDNS custom hosts

k3s CoreDNS reads custom server blocks from a ConfigMap named `coredns-custom` in `kube-system`. Create it to resolve internal hostnames from within the cluster:

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

Create the namespace and secrets:

```bash
kubectl create namespace gitlab

kubectl create secret generic gitlab-postgresql-secret \
  --namespace gitlab \
  --from-literal=postgresql-password=gitlab

kubectl create secret generic gitlab-s3-secret \
  --namespace gitlab \
  --from-literal=connection="$(cat <<'EOF'
provider: AWS
region: us-east-1
aws_access_key_id: gitlab-access-key
aws_secret_access_key: gitlab-secret-key
aws_signature_version: 4
host: seaweedfs-s3.common.svc.cluster.local
endpoint: http://seaweedfs-s3.common.svc.cluster.local:8333
path_style: true
EOF
)"

kubectl create secret generic gitlab-registry-s3-secret \
  --namespace gitlab \
  --from-literal=config="$(cat <<'EOF'
s3:
  bucket: gitlab-registry
  accesskey: gitlab-access-key
  secretkey: gitlab-secret-key
  regionendpoint: http://seaweedfs-s3.common.svc.cluster.local:8333
  region: us-east-1
  pathstyle: true
EOF
)"
```

Create GitLab DB and user:

```bash
kubectl exec -n common postgres-1 -c postgres -- psql -U postgres -c "CREATE USER gitlab WITH PASSWORD 'gitlab';"
kubectl exec -n common postgres-1 -c postgres -- psql -U postgres -c "CREATE DATABASE gitlabhq_production OWNER gitlab;"
```

GitLab is served at `git.home` (registry and kas stay on `s1.home`); all three names must resolve to the node on clients too (router DNS or `/etc/hosts`).

Issue the TLS certificate with the local CA (needs `ClusterIssuer local-ca` from the cert-manager step):

```bash
kubectl apply -f helm/gitlab/certificate.yaml
kubectl get certificate -n gitlab   # wait for gitlab-tls READY True
```

Create secret with the CA that signed it, for Runner (file name must be `<hostname>.crt`; it must exist before the Runner pod starts):

```bash
kubectl create secret generic gitlab-runner-certs \
  --namespace gitlab \
  --from-literal=git.home.crt="$(kubectl get secret gitlab-tls -n gitlab -o jsonpath='{.data.ca\.crt}' | base64 -d)"
```

Install GitLab:

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

Admin settings (stored in the database, set once in the UI under Admin → Settings):

- Sign-up restrictions: disable sign-up. Console alternative (takes ~1.5 min):
  ```bash
  kubectl exec -n gitlab deploy/gitlab-toolbox -- gitlab-rails runner "Gitlab::CurrentSettings.current_application_settings.update!(signup_enabled: false)"
  ```
- Metrics and profiling: disable "Enable GitLab Prometheus metrics endpoint" (otherwise a Sidekiq sampler polls Redis constantly), then `kubectl rollout restart deployment/gitlab-sidekiq-all-in-1-v2 -n gitlab`.
- Usage statistics and event tracking: disable version check, Service Ping, event tracking.
- Web IDE: disable single origin fallback.