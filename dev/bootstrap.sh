#!/usr/bin/env bash
# Reaplica el bootstrap del cluster (idempotente). Pre-requisito de `tilt up`.
# Requiere KUBECONFIG apuntando al cluster Talos.
set -euo pipefail
cd "$(dirname "$0")/.."

# 1. storageClass local-path (Talos: ruta /var, /opt es read-only)
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.31/deploy/local-path-storage.yaml
kubectl -n local-path-storage patch configmap local-path-config --type merge \
  -p '{"data":{"config.json":"{\n  \"nodePathMap\":[\n    {\n      \"node\":\"DEFAULT_PATH_FOR_NON_LISTED_NODES\",\n      \"paths\":[\"/var/local-path-provisioner\"]\n    }\n  ]\n}"}}'
kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# 2. PodSecurity labels (privileged) para local-path-storage + traefik
kubectl apply -f dev/cluster-psa.yaml

# 3. Traefik + resolver netlify ACME (token desde plane/.env)
[ -f dev/.env ] || { echo "falta dev/.env con NETLIFY_TOKEN (ver dev/.env.example)" >&2; exit 1; }
NT=$(grep -E '^NETLIFY_TOKEN=' dev/.env | cut -d= -f2-)
kubectl -n traefik create secret generic netlify-creds \
  --from-literal=NETLIFY_TOKEN="$NT" --dry-run=client -o yaml | kubectl apply -f -
helm repo add traefik https://traefik.github.io/charts >/dev/null 2>&1 || true
helm repo update traefik >/dev/null
helm upgrade --install traefik traefik/traefik -n traefik -f dev/traefik-values.yaml --wait --timeout 3m

# 4. Registry TLS en cluster + IngressRoute (cert LE via netlify)
kubectl apply -f dev/registry.yaml
kubectl apply -f dev/registry-ingressroute.yaml

# 5. namespace de la app
kubectl create namespace gt --dry-run=client -o yaml | kubectl apply -f -
echo "bootstrap OK -> ahora: DOCKER_CONFIG=\$HOME/.config/docker tilt up"
