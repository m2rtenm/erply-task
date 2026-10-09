# Solution: Legacy PHP service from EC2 to EKS

> This is the short version. For design rationale, line-by-line explanations, the full production Ingress example and the complete limitations list, see **[SOLUTION-DETAILED.md](SOLUTION-DETAILED.md)**.

## What is here
| Path | Purpose |
|---|---|
| `Dockerfile`, `docker/Caddyfile` | Image: FrankenPHP (Caddy + PHP) on Alpine, non-root (UID 10001), port 8080, logs to stdout/stderr, PHP errors logged not displayed |
| `helm/legacy-web/` | Helm chart: Deployment (2+ replicas, rolling update, probes, resources), ConfigMap, Secret, ServiceAccount, HPA, PDB, Service (ClusterIP), Ingress |
| `helm/legacy-web/values-nginx.yaml` | Local ingress testing (ingress-nginx) |
| `helm/legacy-web/values-prod.yaml` | Example production overrides (ALB, WAF, ACM, External Secrets) |
| `terraform/main.tf` | IRSA: OIDC provider, scoped IAM role, annotated ServiceAccount |
| `scripts/local-test.sh`, `local-test.log` | End-to-end local test and its output |

## Key decisions
- **One process:** FrankenPHP instead of nginx + php-fpm, so there is no supervisor and a crash is visible to Kubernetes.
- **Logging:** Caddy access logs on stdout, PHP errors on stderr (`display_errors` off, so nothing leaks to clients). Verified with a script that triggers a warning.
- **Non-root:** numeric UID, unprivileged port, file capabilities removed, all Linux capabilities dropped in the pod.
- **Zero-downtime rollouts:** `maxUnavailable: 0`, readiness gating, `preStop` sleep, PDB, zone spread.
- **Resources:** memory limit only (no CPU limit, to avoid throttling); HPA on CPU 70 % and memory 80 %, 2 to 6 replicas.
- **Config vs. secrets:** ConfigMap for plain values, Secret for credentials. The chart's `DB_PASSWORD` is a placeholder; production uses External Secrets Operator via `secret.existingSecret`.
- **No static AWS keys:** IRSA, with a trust policy limited to one ServiceAccount and a least-privilege Secrets Manager policy.

## 1. Run and verify locally
```bash
# container
docker build -t legacy-web:1.0.0 .
docker run --rm -p 8080:8080 legacy-web:1.0.0
curl -i localhost:8080/healthz; curl -i localhost:8080/readyz; curl -i localhost:8080/

# Kubernetes (minikube, with ingress-nginx)
minikube start
minikube image load legacy-web:1.0.0
minikube addons enable metrics-server ingress
helm lint helm/legacy-web
helm install legacy-web helm/legacy-web -f helm/legacy-web/values-nginx.yaml
kubectl rollout status deploy/legacy-web-legacy-web
kubectl get deploy,pods,svc,hpa,pdb,ingress

kubectl port-forward svc/legacy-web-legacy-web 8081:80 &
curl -i localhost:8081/readyz

kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller 8082:80 &
curl -i -H 'Host: legacy-web.local' localhost:8082/readyz   # 200
curl -i -H 'Host: other.local'      localhost:8082/readyz   # 404

# AWS side (validate only)
cd terraform && terraform init -backend=false && terraform validate
```
If `helm install` fails with an ingress-nginx webhook error right after enabling the addon, wait a few seconds and rerun `helm upgrade --install`. `./scripts/local-test.sh` automates all of this; its output is in `local-test.log`.

The production ALB Ingress (needs the AWS Load Balancer Controller, so not runnable locally) is rendered with:
`helm template legacy-web helm/legacy-web -f helm/legacy-web/values-prod.yaml --show-only templates/ingress.yaml`

## 2. Observability strategy
- **Logs:** Fluent Bit DaemonSet tails container logs, adds Kubernetes metadata and ships to CloudWatch Logs or OpenSearch. The app already logs JSON to stdout, so no parsing is needed. ALB access logs go to S3.
- **Metrics:** Prometheus and Grafana (kube-prometheus-stack, or Amazon Managed Prometheus/Grafana) for cluster and workload metrics. Caddy can expose Prometheus metrics (opt-in, tested, not enabled by default; see the detailed doc); a ServiceMonitor would scrape them.
- **Alerts:** 5xx rate, p95 latency, pod restarts, readiness failures, HPA at max, unhealthy ALB targets.

## 3. Production considerations
- **GitOps** (ArgoCD/Flux), CI with image scanning and signing, images deployed by digest, progressive delivery.
- **Secrets:** External Secrets Operator with AWS Secrets Manager, KMS encryption of etcd.
- **Edge:** CloudFront and AWS WAF in front of the ALB, ACM certificates, external-dns, one shared ALB per environment.
- **Hardening:** NetworkPolicies (default deny), Pod Security `restricted`, read-only root filesystem, admission policies.
- **Operations:** Karpenter or Cluster Autoscaler, SLOs, runbooks, load testing to tune resources.
- **App:** a real `/readyz` that checks DB and cache (the supplied one always returns 200).

## Verified vs. not verified
Verified locally (see `local-test.log`): image build, non-root user, stdout logging, PHP error logging, Caddy metrics (opt-in variant), probes, rollout, ConfigMap values, ingress routing (200 for the right host, 404 otherwise), `helm lint`/`template`, `terraform validate`.
Not verified (no AWS account): ALB annotations, WAF, ACM, CloudFront, external-dns, `terraform apply`. These are documented and linted only.
