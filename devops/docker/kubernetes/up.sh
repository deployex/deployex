#!/bin/sh
# Creates a local cluster with kind and deploys DeployEx and HAProxy in one pod.
#
# Everything goes through a kubeconfig of its own, next to this file, so the contexts of
# your kubectl are never read or changed. Run from the root of the repository.
set -e
here=devops/docker/kubernetes
src=devops/docker
export KUBECONFIG="$PWD/$here/kubeconfig"
mkdir -p "$src/bucket"

docker compose -f "$src/compose.yaml" build deployex
# Run again, it keeps the cluster and brings the image and the configuration up to date
if kind get clusters 2>/dev/null | grep -qx deployex-trial; then
  existing=true
  kind export kubeconfig --name deployex-trial --kubeconfig "$KUBECONFIG"
else
  existing=false
  kind create cluster --config "$here/kind-cluster.yaml" --kubeconfig "$KUBECONFIG"
fi
kind load docker-image deployex-trial:latest --name deployex-trial
kubectl create configmap deployex-config --dry-run=client -o yaml \
  --from-file=deployex.yaml="$src/deployex.yaml" --from-file=haproxy.cfg="$src/haproxy.cfg" |
  kubectl apply -f -
# The hash is the one of "deployex", the password of the admin user
kubectl create secret generic deployex-secrets --dry-run=client -o yaml \
  --from-literal=DEPLOYEX_SECRET_KEY_BASE='e4CXwPpjrAJp9NbRobS8dXmOHfn0EBpFdhZlPmZo1y3N/BzW9Z/k7iP7FjMk+chi' \
  --from-literal=DEPLOYEX_ERLANG_COOKIE='cookie' \
  --from-literal=DEPLOYEX_ADMIN_HASHED_PASSWORD='$2b$12$vNAn.RJezPdQF7Dcy4c9Q.p34hdeNnkIaGTk80xdc/Rk18vWjUOC.' |
  kubectl apply -f -
kubectl apply -f "$here/deployex.yaml"
# A pod that was already there has the previous image, haproxy.cfg and secrets
if [ "$existing" = true ]; then
  kubectl rollout restart deployment/deployex
fi
# The pod is ready once an application is published and answers: make docker-app
kubectl rollout status deployment/deployex --timeout=60s || kubectl get pods
echo "DeployEx: http://localhost:5011 (admin / deployex). The app, once published: http://localhost:8090"
echo "kubectl for this cluster: export KUBECONFIG=$KUBECONFIG"
