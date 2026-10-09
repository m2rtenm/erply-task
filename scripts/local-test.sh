#!/usr/bin/env bash
# Local verification: docker, helm, minikube. Output is logged by the caller.
cd "$(dirname "$0")/.."
run() { echo; echo "\$ $*"; "$@" 2>&1; echo "[exit=$?]"; }
echo "== Run at $(date -u +%FT%TZ) =="
run docker build -t legacy-web:1.0.0 .
run docker run -d --name lw -p 8080:8080 legacy-web:1.0.0
sleep 4
for p in healthz readyz ""; do run curl -si localhost:8080/$p; done
run docker exec lw id
run docker logs lw
run docker rm -f lw

echo; echo "== PHP error handling: warnings must reach stderr, not the HTTP response =="
T=$(mktemp -d)
printf '<?php\necho $undefined;\ntrigger_error("custom-test-error", E_USER_WARNING);\necho "ok";\n' > $T/err.php
chmod a+r $T/err.php
run docker run -d --name lw-err -p 8090:8080 -v $T/err.php:/app/public/err.php:ro legacy-web:1.0.0
sleep 4
echo "\$ curl -s localhost:8090/err.php   (expect body: ok)"; curl -s localhost:8090/err.php; echo
echo "\$ docker logs (stderr only), PHP warnings:"; docker logs lw-err 2>&1 >/dev/null | grep 'PHP Warning' | cut -c1-200
echo "\$ X-Powered-By header (expect none):"; curl -sI localhost:8090/ | grep -i x-powered || echo "(none)"
run docker rm -f lw-err

echo; echo "== Caddy metrics (opt-in; not enabled in the shipped Caddyfile) =="
sed 's/^\tfrankenphp$/\tfrankenphp\n\tmetrics/; s#^\tphp_server#\tmetrics /metrics\n\tphp_server#' docker/Caddyfile > $T/Caddyfile
run docker run -d --name lw-met -p 8091:8080 -v $T/Caddyfile:/etc/caddy/Caddyfile:ro legacy-web:1.0.0
sleep 4
curl -s localhost:8091/healthz >/dev/null; curl -s localhost:8091/ >/dev/null
echo "\$ curl -s localhost:8091/metrics | grep caddy_http_requests_total"; curl -s localhost:8091/metrics | grep '^caddy_http_requests_total'
run docker rm -f lw-met
rm -rf $T
run helm lint helm/legacy-web
run helm template legacy-web helm/legacy-web
run helm template legacy-web helm/legacy-web -f helm/legacy-web/values-prod.yaml --show-only templates/ingress.yaml
run terraform -chdir=terraform fmt -check
# provider download can fail on flaky networks; retry
for i in 1 2 3; do
  run terraform -chdir=terraform init -backend=false -input=false && terraform -chdir=terraform validate -no-color >/dev/null 2>&1 && break
  sleep 5
done
run terraform -chdir=terraform validate
rm -rf terraform/.terraform terraform/.terraform.lock.hcl
run minikube start --driver=docker --wait=all
run minikube image load legacy-web:1.0.0
run minikube addons enable metrics-server
run minikube addons enable ingress
run kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=180s
run kubectl -n ingress-nginx wait --for=condition=complete job --all --timeout=120s
sleep 10   # let the admission webhook start serving
# the ingress-nginx admission webhook can lag behind the controller rollout; retry
for i in 1 2 3 4 5 6; do
  run helm upgrade --install legacy-web helm/legacy-web -f helm/legacy-web/values-nginx.yaml
  helm status legacy-web 2>/dev/null | grep -q 'STATUS: deployed' && break
  echo "webhook not ready, retry $i"; sleep 10
done
run kubectl rollout status deploy/legacy-web-legacy-web --timeout=120s
run kubectl get deploy,pods,svc,hpa,pdb,cm,secret,sa -o wide
kubectl port-forward svc/legacy-web-legacy-web 8081:80 >/dev/null 2>&1 & PF=$!
sleep 3
for p in healthz readyz ""; do run curl -si localhost:8081/$p; done
kill $PF
sleep 5
run kubectl get ingress
kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller 8082:80 >/dev/null 2>&1 & PF=$!
sleep 3
run curl -si -H 'Host: legacy-web.local' localhost:8082/readyz
run curl -si -H 'Host: other.local' localhost:8082/readyz
kill $PF
run kubectl delete pod -l app.kubernetes.io/name=legacy-web --wait=false
run kubectl get pods -o jsonpath='{.items[0].spec.terminationGracePeriodSeconds}{" "}{.items[0].spec.containers[0].lifecycle}{"\n"}'
run kubectl logs deploy/legacy-web-legacy-web --tail=10
run kubectl get pods -o jsonpath='{range .items[*]}{.metadata.name}{" uid="}{.spec.securityContext.runAsUser}{"\n"}{end}'
run helm uninstall legacy-web
run minikube delete
echo "== Done =="
