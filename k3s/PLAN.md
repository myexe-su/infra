# K3s Installation Plan

| Step | Component | Where | Namespace |
|------|-----------|-------|-----------|
| 1 | k3s (Server) | Server 1 (native) | — |
| 2 | k9s | Server 1 (native) | — |
| 3 | Helm | Server 1 (native) | — |
| 4 | cert-manager | k3s (Helm) | cert-manager |
| 5 | PostgreSQL | k3s (Helm/operator) | common |
| 6 | Redis | k3s (Helm) | common |
| 7 | SeaweedFS (S3) | k3s (Helm) | common |
| 8 | GitLab CE | k3s (Helm) | gitlab |
| 9 | Argo CD | k3s (Helm) | common |
| 10 | GitLab Runner | k3s (Helm) | gitlab-runners |
| 11 | Linkerd | k3s (CLI) | linkerd |
| 12 | Prometheus + Grafana | k3s (Helm) | monitoring |
| 13 | Loki | k3s (Helm) | monitoring |
| 14 | Vault | k3s (Helm) | common |
| 15 | Keycloak | k3s (Helm) | common |
| 16 | MongoDB | k3s (Helm/operator) | common |
| 17 | RabbitMQ | k3s (Helm) | common |
| 18 | k3s (Agent) | Server 2 (native) | — |
