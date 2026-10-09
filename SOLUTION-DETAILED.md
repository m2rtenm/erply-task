# Solution (detailed): Legacy PHP service from EC2 to EKS

> Long version with all design rationale. The short answer to the assignment questions is in [SOLUTION.md](SOLUTION.md).

This document explains what was built, why each decision was made, how to run and verify it, and what I would do differently in production. Where something could not be tested locally, it says so.

## Contents
1. [Overview and repository layout](#overview-and-repository-layout)
2. [Containerization](#containerization)
3. [Kubernetes / Helm chart](#kubernetes--helm-chart)
4. [Ingress in real life (AWS ALB)](#ingress-in-real-life-aws-alb)
5. [AWS and Terraform (IRSA)](#aws-and-terraform-irsa)
6. [How to run and verify locally](#1-how-to-run-and-verify-locally)
7. [Observability strategy](#2-observability-strategy)
8. [Production considerations](#3-production-considerations)
9. [Verification results](#verification-results)
10. [Known limitations and trade-offs](#known-limitations-and-trade-offs)

---

## Overview and repository layout

The legacy service is a single PHP file (`app/index.php`) that reads its configuration from environment variables and exposes `/healthz` (liveness) and `/readyz` (readiness). It was previously deployed with Ansible onto EC2. The goal here is to run it on EKS following cloud-native practices. The app code is unchanged: all work is packaging, orchestration and infrastructure.

```
.
├── app/index.php                      # the supplied application (unchanged)
├── Dockerfile                         # image build
├── docker/Caddyfile                   # web server configuration
├── docker/zz-prod.ini                 # PHP error handling (log to stderr, never to clients)
├── .dockerignore
├── helm/legacy-web/
│   ├── Chart.yaml
│   ├── values.yaml                    # defaults (safe for local use)
│   ├── values-nginx.yaml              # local ingress testing (ingress-nginx)
│   ├── values-prod.yaml               # example production overrides (ALB, WAF, ESO)
│   └── templates/                     # Deployment, Service, ConfigMap, Secret,
│                                      # ServiceAccount, HPA, PDB, Ingress
├── terraform/main.tf                  # IRSA: OIDC provider, IAM role, ServiceAccount
├── scripts/local-test.sh              # end-to-end local verification
├── local-test.log                     # output of the last run of that script
├── SOLUTION.md                        # short version
└── SOLUTION-DETAILED.md               # this file
```

---

## Containerization

### Choice of web server: FrankenPHP
FrankenPHP is the Caddy web server with PHP embedded in the same process. I chose it because the requirement "how is the web server handled?" is answered with the smallest number of moving parts:

| Option | Processes | Config files | Comment |
|---|---|---|---|
| nginx + php-fpm (one container) | 3 (nginx, fpm, supervisor) | nginx.conf, fpm pool, supervisord | Classic, but a supervisor in a container hides crashes from Kubernetes |
| nginx + php-fpm (sidecars) | 2 containers | nginx.conf, fpm pool, shared socket/volume | Good isolation, more wiring and two images to patch |
| **FrankenPHP (chosen)** | **1** | **1 Caddyfile** | One process, so a crash is visible to Kubernetes and restarted correctly |

Trade-off: the FrankenPHP image is larger than a bare `php-fpm-alpine` image, and it is a younger project than nginx + php-fpm. If a team already operates nginx + php-fpm and wants to tune or scale them separately, the sidecar pattern is the better fit.

### Dockerfile walkthrough
```dockerfile
FROM dunglas/frankenphp:1-php8.3-alpine
```
Alpine-based, minimal. Pinned to a major version and PHP minor version; in production I would pin by digest as well.

```dockerfile
COPY docker/Caddyfile /etc/caddy/Caddyfile
COPY docker/zz-prod.ini $PHP_INI_DIR/conf.d/zz-prod.ini
COPY app/ /app/public/
```
Configuration and application code only. `zz-prod.ini` sets `display_errors=Off`, `log_errors=On` and `expose_php=Off` (see Logging below). `.dockerignore` keeps `helm/`, `terraform/` and docs out of the build context.

```dockerfile
RUN apk add --no-cache libcap \
 && setcap -r /usr/local/bin/frankenphp || true \
 && apk del libcap \
 && adduser -D -u 10001 app \
 && mkdir -p /data/caddy /config/caddy \
 && chown -R app:app /data /config
```
- The upstream binary has file capabilities (to bind ports below 1024). A non-root user does not need them because we use port 8080, so they are removed (`setcap -r`).
- A dedicated user with a fixed numeric UID (10001). Kubernetes `runAsNonRoot` can only verify a numeric UID, not a user name.
- Caddy needs two writable directories for its state; only those are owned by the app user. Everything else is read-only to it.

```dockerfile
USER 10001
EXPOSE 8080
HEALTHCHECK ... wget -qO- http://127.0.0.1:8080/healthz
CMD ["frankenphp", "run", "--config", "/etc/caddy/Caddyfile"]
```
`HEALTHCHECK` is for plain Docker use; Kubernetes ignores it and uses its own probes.

### Caddyfile walkthrough
```
{
	admin off              # no admin API: not needed, and one less attack surface
	auto_https off         # TLS is terminated at the ALB; Caddy must not try to get certificates
	frankenphp             # enable the embedded PHP runtime
	log { output stderr; format console }   # server logs -> stderr
}

:8080 {                    # unprivileged port, any hostname
	root * /app/public
	log { output stdout }  # access logs -> stdout (JSON, one line per request)
	php_server             # serve PHP; unknown paths fall through to index.php
}
```
`php_server` is why `/healthz` and `/readyz` work: no files exist with those names, so the request is routed to `index.php`, which inspects the URI itself.

### Logging
Nothing is written to files inside the container. Access logs go to stdout and server logs to stderr, which is what Kubernetes and log shippers expect. Caddy's access log is JSON by default, so no parsing rules are needed downstream. PHP errors needed an explicit fix: the base image has no `php.ini`, so PHP defaults to `display_errors=On` and printed warnings (including file paths) into the HTTP response while nothing reached the logs. I found this by testing with a script that triggers a warning. `docker/zz-prod.ini` now turns display off and logging on; warnings appear on stderr as `PHP Warning: ... in /app/public/err.php on line N`, the response body contains only the intended output, and the `X-Powered-By` header is no longer sent.

### Verified
Image builds; `docker exec <container> id` shows `uid=10001(app)`; all three endpoints return 200; access log lines appear in `docker logs` (see `local-test.log`).

---

## Kubernetes / Helm chart

Helm was chosen over Kustomize because the same chart must be deployed with different settings (local nginx ingress vs. production ALB), and values files express that directly.

### Templates
| File | Purpose |
|---|---|
| `deployment.yaml` | The workload (details below) |
| `service.yaml` | ClusterIP Service, port 80 to container port 8080 |
| `configmap.yaml` | Non-sensitive configuration |
| `secret.yaml` | Sensitive configuration; skipped if `secret.existingSecret` is set |
| `serviceaccount.yaml` | ServiceAccount with optional IRSA annotation |
| `hpa.yaml` | HorizontalPodAutoscaler (autoscaling/v2) |
| `pdb.yaml` | PodDisruptionBudget |
| `ingress.yaml` | Ingress, class and annotations from values |

### Deployment decisions
- **Replicas:** 2 minimum for high availability. When the HPA is enabled the chart omits `spec.replicas`, so a `helm upgrade` does not reset the replica count the HPA has chosen.
- **Rolling update:** `maxSurge: 1`, `maxUnavailable: 0`. A new pod must become ready before an old one is removed, so capacity never drops during a rollout. The cost is slightly slower rollouts.
- **Probes:** liveness on `/healthz`, readiness on `/readyz`. Liveness answers "should this container be restarted?" and must not depend on external services, otherwise a database outage would cause Kubernetes to restart every pod. Readiness answers "should this pod receive traffic?" and is where dependency checks belong.
- **Resources:** requests `100m` CPU / `128Mi` memory; limit `256Mi` memory and **no CPU limit**. CPU limits cause throttling even when the node has spare CPU; memory limits protect the node from OOM. Requests still guarantee scheduling and drive the HPA. These numbers are starting points and should be set from real load tests.
- **Configuration and secrets:** both injected with `envFrom`, which matches how the app reads config. A `checksum/config` annotation on the pod template restarts pods when the ConfigMap changes (environment variables are otherwise only read at start).
- **Security context:** `runAsNonRoot`, `runAsUser: 10001`, `seccompProfile: RuntimeDefault`, `allowPrivilegeEscalation: false`, all capabilities dropped. This is compatible with the Pod Security Standards "restricted" profile except for a writable root filesystem (see limitations).
- **Writable paths:** an `emptyDir` is mounted at `/data` and `/config` for Caddy's state.
- **Spread:** `topologySpreadConstraints` over `topology.kubernetes.io/zone` with `ScheduleAnyway`, so replicas spread across availability zones when possible but scheduling never blocks.
- **Graceful shutdown:** a `preStop` sleep (15 s) and `terminationGracePeriodSeconds: 45`. When a pod is deleted, Kubernetes removes it from the Service and sends SIGTERM at roughly the same time; load balancers need a few seconds to notice. The sleep keeps the pod serving until the ALB has deregistered it, so in-flight requests are not dropped.

### Configuration and secrets
- **ConfigMap** (`config:` in values): `APP_NAME`, `APP_ENV`, `DB_HOST`, `DB_PORT`, `CACHE_HOST`.
- **Secret** (`secret.data`): `DB_PASSWORD`. **The value in `values.yaml` is a placeholder.** In production the chart is pointed at a Secret created by External Secrets Operator via `secret.existingSecret`, so no secret ever lives in Git or in Helm values.

### Autoscaling
HPA targeting 70 % average CPU and 80 % average memory utilisation, 2 to 6 replicas (relative to requests). Requires metrics-server (an addon on minikube; available on EKS as a managed addon). A PodDisruptionBudget (`minAvailable: 1`) keeps at least one pod running during voluntary disruptions such as node drains.

---

## Ingress in real life (AWS ALB)

Local clusters cannot run the AWS Load Balancer Controller, so locally I test routing with ingress-nginx (`values-nginx.yaml`). In production the same chart is deployed with `values-prod.yaml`, which uses the ALB class and annotations.

### Request path
```
Client -> Route 53 (external-dns) -> CloudFront + WAF -> ALB (ACM cert, TLS 1.3) -> pod IP:8080
```

### One-time, per cluster (Terraform)
1. Tag subnets: `kubernetes.io/role/elb=1` (public), `kubernetes.io/role/internal-elb=1` (private). The controller uses these to place the ALB.
2. Create an IRSA role for the controller with the official AWS Load Balancer Controller IAM policy (same pattern as `terraform/main.tf`, no static keys).
3. Install the controller:
```bash
helm repo add eks https://aws.github.io/eks-charts
helm install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system \
  --set clusterName=<cluster> \
  --set serviceAccount.create=true \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=<controller-role-arn>
```
4. Install external-dns (Route 53 records) and request an ACM certificate (wildcard, DNS-validated, in Terraform).

### Per application (what the chart renders with `values-prod.yaml`)
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: legacy-web-legacy-web
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip              # straight to pod IPs (VPC CNI)
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    alb.ingress.kubernetes.io/ssl-policy: ELBSecurityPolicy-TLS13-1-2-2021-06
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:eu-west-1:<acct>:certificate/<id>
    alb.ingress.kubernetes.io/wafv2-acl-arn: arn:aws:wafv2:eu-west-1:<acct>:regional/webacl/<name>/<id>
    alb.ingress.kubernetes.io/group.name: shared-public    # many services, ONE ALB (cost)
    alb.ingress.kubernetes.io/healthcheck-path: /readyz    # only ready pods get traffic
    alb.ingress.kubernetes.io/target-group-attributes: deregistration_delay.timeout_seconds=30
spec:
  ingressClassName: alb
  rules:
    - host: legacy-web.example.com      # external-dns creates the Route 53 record from this
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service: { name: legacy-web-legacy-web, port: { number: 80 } }
```
Deploy: `helm upgrade --install legacy-web helm/legacy-web -f helm/legacy-web/values-prod.yaml`

### Why these choices
- **`target-type: ip`** skips the NodePort hop and kube-proxy, so there is less latency and the ALB sees real pod health.
- **Health check on `/readyz`**, the **`preStop` sleep**, **`terminationGracePeriodSeconds: 45`** and **`deregistration_delay` 30 s** work together: during a rolling update the ALB stops sending traffic to a pod before it receives SIGTERM.
- **`group.name`**: one ALB per Ingress is expensive; grouping shares an ALB across services with host/path routing.
- **WAF on the ALB, CloudFront in front**: managed rule sets and rate limiting at the edge. The ALB security group would be restricted to the CloudFront managed prefix list so the edge cannot be bypassed.
- **Access logs to S3** (`load-balancer-attributes: access_logs.s3.enabled=true,...`) feed the observability stack.
- **ACM and external-dns** mean no certificates or DNS records are handled by hand.
- **Alternatives:** ingress-nginx behind an NLB gives more routing flexibility (rewrites, per-route rate limits) but is another component to run and patch. The Gateway API with the AWS controller is where things are heading and I would consider it for new clusters.

### Local equivalent (what was actually tested)
```bash
minikube addons enable ingress
helm install legacy-web helm/legacy-web -f helm/legacy-web/values-nginx.yaml
kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller 8082:80
curl -H 'Host: legacy-web.local' localhost:8082/readyz   # routed -> 200
curl -H 'Host: other.local'      localhost:8082/readyz   # no matching host -> 404
```
This validates the host rule and Service wiring. ALB-specific behaviour (annotations, WAF, ACM, target groups) can only be verified on a real EKS cluster, for example with a short-lived test cluster in CI. The ALB variant is rendered and linted here with `helm lint -f values-prod.yaml`.

---

## AWS and Terraform (IRSA)

`terraform/main.tf` shows how pods get AWS access without static keys, using IAM Roles for Service Accounts.

### How it works
1. EKS exposes an OIDC issuer. An `aws_iam_openid_connect_provider` registers it with IAM.
2. Kubernetes projects a short-lived, signed token into pods that use an annotated ServiceAccount.
3. The AWS SDK exchanges that token for temporary credentials with `sts:AssumeRoleWithWebIdentity`.
4. The IAM role's trust policy accepts tokens only when `sub` equals `system:serviceaccount:<namespace>:<serviceaccount>` and `aud` equals `sts.amazonaws.com`. Only that one ServiceAccount can assume the role.

### What the file contains
- OIDC provider for the cluster (data source `aws_eks_cluster`).
- Trust policy scoped to one ServiceAccount (the `sub` and `aud` conditions above).
- IAM role `legacy-web` with a least-privilege inline policy: `GetSecretValue` and `DescribeSecret` only, on `secret:legacy-web/*` in the current account. No wildcards on actions.
- A `kubernetes_service_account` carrying the `eks.amazonaws.com/role-arn` annotation.
- Output of the role ARN.

### Wiring with the chart
Either set `serviceAccount.annotations` in the chart (as `values-prod.yaml` does) or let Terraform own the ServiceAccount. A real setup should pick one, since both creating the same name would conflict. The default ServiceAccount name in `main.tf` matches the chart's (`<release>-<chart>`).

### Alternative: EKS Pod Identity
Pod Identity uses an EKS agent and an association between role and ServiceAccount, so no per-cluster OIDC provider is needed and the trust policy can be reused across clusters. IRSA works on all clusters (including Fargate and older versions), which is why it is used in this sample.

### Verified
`terraform fmt -check` and `terraform validate` pass. It was **not applied** (no AWS account is required or used).

---

## 1. How to run and verify locally

Prerequisites: Docker, Helm, kubectl, minikube (kind or k3d work too), Terraform for the optional validation step.

### Container only
```bash
docker build -t legacy-web:1.0.0 .
docker run --rm -p 8080:8080 legacy-web:1.0.0
curl -i localhost:8080/healthz     # {"status":"healthy",...}
curl -i localhost:8080/readyz      # {"status":"ready",...}
curl -i localhost:8080/            # service info JSON
docker exec <container> id         # uid=10001(app), not root
docker logs <container>            # JSON access logs on stdout
```

### Kubernetes (minikube) with ingress-nginx
```bash
minikube start
minikube image load legacy-web:1.0.0
minikube addons enable metrics-server ingress

helm lint helm/legacy-web
helm install legacy-web helm/legacy-web -f helm/legacy-web/values-nginx.yaml
kubectl rollout status deploy/legacy-web-legacy-web
kubectl get deploy,pods,svc,hpa,pdb,ingress

# direct to the Service
kubectl port-forward svc/legacy-web-legacy-web 8081:80
curl -i localhost:8081/readyz      # shows DB_HOST/CACHE_HOST from the ConfigMap

# through the ingress controller
kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller 8082:80
curl -i -H 'Host: legacy-web.local' localhost:8082/readyz    # 200
curl -i -H 'Host: other.local'      localhost:8082/readyz    # 404

kubectl logs deploy/legacy-web-legacy-web   # kube-probe and curl requests
```
If `helm install` fails with an ingress-nginx admission webhook error right after enabling the addon, the webhook is not ready yet; wait a few seconds and run `helm upgrade --install` again.

### Render the production (ALB) variant
```bash
helm template legacy-web helm/legacy-web -f helm/legacy-web/values-prod.yaml --show-only templates/ingress.yaml
helm lint helm/legacy-web -f helm/legacy-web/values-prod.yaml
```

### Terraform
```bash
cd terraform && terraform init -backend=false && terraform validate
```

### Everything at once
`./scripts/local-test.sh > local-test.log 2>&1` runs all of the above on a fresh minikube cluster, retrying the install while the webhook starts, and deletes the cluster at the end.

---

## 2. Observability strategy

### Logs
- **Collection:** a Fluent Bit DaemonSet tails `/var/log/containers/*.log` on every node, enriches records with Kubernetes metadata (namespace, pod, labels) and ships them. Because the app logs to stdout/stderr as JSON, no application agent or log files are needed.
- **Destination:** CloudWatch Logs for the low-effort option (Fluent Bit via the AWS for Fluent Bit image, using IRSA for permissions), or OpenSearch with Dashboards when richer search is needed. Retention and index lifecycle policies keep cost under control.
- **Other sources:** ALB access logs to S3 (queryable with Athena), CloudFront and WAF logs, EKS control plane logs to CloudWatch.

### Metrics
- **Cluster and workload:** kube-prometheus-stack (Prometheus, Alertmanager, Grafana, kube-state-metrics, node-exporter), or Amazon Managed Prometheus and Managed Grafana to avoid running storage. CloudWatch Container Insights is the lower-effort alternative.
- **Application:** Caddy can expose Prometheus metrics (request rate, latency, status codes). This is **opt-in and not enabled in the shipped Caddyfile**: it needs `metrics` in the global block and a `metrics /metrics` handler in the site block. I tested that variant and `/metrics` returns `caddy_http_requests_total` and `caddy_http_request_duration_seconds_*`. Note that on port 8080 the endpoint would also be reachable through the Ingress, so in production I would serve it on a separate internal port (for example `:9090`) that the Ingress does not route to, and scrape it with a `ServiceMonitor`. A custom metric on requests per second would make a better HPA signal than CPU.
- **Autoscaling inputs:** metrics-server for the HPA.

### Alerting and dashboards
Alert on symptoms rather than causes: 5xx rate, p95 latency, pod restarts and crash loops, readiness failures, HPA at max replicas, ALB unhealthy target count. Route through Alertmanager to Slack/PagerDuty. Add tracing with OpenTelemetry (AWS X-Ray or Tempo) once the service has downstream dependencies.

---

## 3. Production considerations

**Delivery**
- GitOps with ArgoCD or Flux; the cluster state is pulled from Git, drift is corrected automatically, and rollbacks are a revert.
- CI pipeline: lint (helm, terraform, hadolint), build, scan (Trivy), sign (cosign), push to ECR, deploy images by digest rather than tag.
- Progressive delivery (Argo Rollouts canary or blue/green) with automatic rollback on error-rate regressions.
- Per-environment values files and Terraform remote state with locking.

**Secrets and identity**
- External Secrets Operator syncing from AWS Secrets Manager into the Secret referenced by `secret.existingSecret` (authenticated via IRSA or Pod Identity). Rotation handled in Secrets Manager.
- EKS secrets encryption with a customer-managed KMS key.
- Separate IAM roles per workload; least-privilege policies; access reviews.

**Edge and network**
- CloudFront and AWS WAF in front of the ALB, Shield for DDoS, ACM certificates, external-dns for records.
- NetworkPolicies with default deny and explicit allows (ingress from the controller, egress to DB/cache and DNS).
- Private subnets for nodes, VPC endpoints for AWS APIs.

**Cluster and runtime**
- Pod Security Admission at `restricted`; admission policies (Kyverno or Gatekeeper) enforcing image signatures, resource limits and non-root.
- `readOnlyRootFilesystem: true` once tmp/state paths are confirmed.
- Karpenter or Cluster Autoscaler for nodes; Spot for stateless workloads, with the PDB and spread constraints already in the chart.
- Regular node and addon upgrades; image rebuilds on base image CVEs.

**Application readiness**
- `/readyz` should check DB and cache connectivity with short timeouts (the supplied app always returns 200). `/healthz` must stay dependency-free.
- Load-test to set requests/limits and HPA thresholds from data.
- Define SLOs (availability, latency) and alert on error budget burn.

**Reliability and recovery**
- Multi-AZ by default (spread constraints, PDB). Backups and restore drills for data stores. Runbooks for the alerts above.

---

## Verification results

The full output is in `local-test.log`, produced by `scripts/local-test.sh` on a fresh minikube cluster.

| Check | Result |
|---|---|
| `docker build` | Success |
| `/healthz`, `/readyz`, `/` in the container | HTTP 200 |
| Container user | `uid=10001(app)` |
| Logs on stdout | JSON access log lines in `docker logs` |
| PHP warnings | On stderr only; response body clean; no `X-Powered-By` (this test found and fixed a bug, see Logging) |
| Caddy metrics (opt-in variant) | `/metrics` returns Prometheus counters |
| `helm lint`, `helm template` (default and `values-prod.yaml`) | Pass |
| `terraform fmt -check`, `init -backend=false`, `validate` | Pass |
| minikube install with `values-nginx.yaml` | Deployed on the first attempt (the script waits for the ingress-nginx admission jobs and keeps a retry as a fallback) |
| Rollout, probes, ConfigMap values via `/readyz` | Working |
| Ingress `Host: legacy-web.local` / `Host: other.local` | 200 / 404 |
| `preStop` and grace period on the pod | `45`, `sleep 15` present |

## Known limitations and trade-offs

- **Not tested on real AWS/EKS:** ALB annotations, WAF, ACM, CloudFront and external-dns are documented and linted but not exercised. `terraform apply` was not run.
- **`/readyz` is a stub** in the supplied app; production needs real dependency checks.
- **Placeholders:** `DB_PASSWORD`, account IDs, ARNs and certificate IDs in the values files and Terraform are examples. The OIDC thumbprint in `main.tf` is required by the provider schema but ignored by AWS for EKS issuers.
- **Root filesystem is writable** inside the container (Caddy writes to `/data` and `/config`, which are `emptyDir` mounts in Kubernetes); making it read-only needs additional verification.
- **HPA on memory** can flap for apps whose memory does not shrink after load; CPU or request-rate metrics are preferable.
- **Resource values** are reasonable defaults, not measured.
- **ServiceAccount ownership:** the chart and Terraform can each create it; choose one per environment.
- **FrankenPHP** is a younger project than nginx + php-fpm; the sidecar pattern remains a valid alternative.
