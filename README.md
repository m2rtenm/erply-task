# DevOps Engineer Practical Assignment: Legacy EC2 to AWS EKS Migration

Welcome! Your task is to help us modernize our infrastructure.

We are currently transitioning our workloads from traditional **Ansible + EC2** virtual machines to **AWS EKS (Kubernetes)**.

This assignment simulates a real-world scenario we encounter: taking a legacy web service, containerizing it following cloud-native best practices, orchestrating it securely in Kubernetes, and defining infrastructure as code.

---

## ⏱ Timebox and Expectations
- **Expected time commitment:** 3–4 hours. We do not expect a production-grade mega-project with every edge case covered.
- **No AWS account or cloud expenses required:** Your solution should be testable locally (e.g., using `kind`, `k3d`, `minikube`, or `docker-compose`). You do not need to provision real AWS resources.
- If you run out of time or decide to skip certain components, document it in your submission: **explain what you would have done and why**. A thoughtful architectural rationale is just as valuable to us as working code.

---

## 📂 Included Assets
In the `app/` directory, you will find a simple PHP web service (`index.php`) that reads configuration from environment variables and provides two health check endpoints:
- `/healthz` (Liveness)
- `/readyz` (Readiness)

---

## 🎯 Assignment Tasks

### 1. Containerization (`Dockerfile`)
Create a production-ready `Dockerfile` (or multiple, if using a sidecar pattern):
- **Security:** The container must not run as `root`.
- **Image optimization:** Use a minimal base image (e.g., Alpine-based).
- **Process management:** How is the web server handled (Nginx + PHP-FPM, Caddy, FrankenPHP, etc.)?
- **Logging:** Application and access logs must be streamed directly to `stdout`/`stderr` rather than written to local files inside the container.

### 2. Kubernetes / EKS Manifests (Helm Chart or Kustomize)
Create declarative Kubernetes manifests (preferably a **Helm chart** or **Kustomize** configuration):
- **Deployment:**
  - At least 2 replicas for high availability.
  - Sane resource `requests` and `limits`.
  - Health checks: `livenessProbe` and `readinessProbe`.
  - Rolling update strategy.
- **Configuration & Secrets:**
  - Clear separation between non-sensitive configs (`ConfigMap`) and sensitive credentials (`Secret`).
- **Autoscaling:**
  - `HorizontalPodAutoscaler` (HPA) definition based on resource metrics (e.g., CPU/memory).
- **Networking & Ingress:**
  - `Service` (ClusterIP).
  - `Ingress` definition including annotations you would use with the AWS Load Balancer Controller (ALB Ingress) or Nginx Ingress.

### 3. AWS & Terraform Integration (Snippet/Sample)
In the `terraform/` directory, provide a concise Terraform (HCL) snippet demonstrating:
- How pods in EKS can securely authenticate and access AWS resources (such as S3 or AWS Secrets Manager) **without static, long-lived AWS Access Keys**.
  *(Hint: IAM Roles for Service Accounts / IRSA or EKS Pod Identity, along with the corresponding Kubernetes `ServiceAccount`).*

### 4. Documentation (`SOLUTION.md`)
Provide a brief write-up answering:
1. **How to run and verify the setup locally?** (Exact commands: `docker build`, `helm install` / `kubectl apply`, test requests).
2. **Observability strategy:** How would you collect and ship container logs and metrics from EKS to a centralized stack (e.g., Fluent Bit to Elasticsearch/OpenSearch/Kibana, CloudWatch, Prometheus/Grafana)?
3. **Production considerations:** What additional practices would you introduce in a live production environment (e.g., GitOps with ArgoCD/Flux, secret management with External Secrets Operator, AWS WAF + CloudFront integration)?

---

## 📦 Submission
Please submit your work as either:
1. A link to a public or private GitHub / GitLab repository, or
2. A `.zip` archive via email.

Good luck! We look forward to discussing your architecture and decisions during the technical interview.
