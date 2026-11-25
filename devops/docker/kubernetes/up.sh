#!/bin/sh
# Creates a local cluster with kind and deploys DeployEx and nginx in one pod.
#
# Everything goes through a kubeconfig of its own, next to this file, so the contexts of
# your kubectl are never read or changed. Run from the root of the repository.
set -e
here=devops/docker/kubernetes
src=devops/docker
export KUBECONFIG="$PWD/$here/kubeconfig"
mkdir -p "$src/bucket"

docker compose -f "$src/compose.yaml" build deployex
kind create cluster --config "$here/kind-cluster.yaml" --kubeconfig "$KUBECONFIG"
kind load docker-image docker-deployex:latest --name deployex-trial
kubectl create configmap deployex-config \
  --from-file=deployex.yaml="$src/deployex.yaml" --from-file=nginx.conf="$src/nginx.conf"
# The hash is the one of "deployex", the password of the admin user
kubectl create secret generic deployex-secrets \
  --from-literal=DEPLOYEX_SECRET_KEY_BASE='e4CXwPpjrAJp9NbRobS8dXmOHfn0EBpFdhZlPmZo1y3N/BzW9Z/k7iP7FjMk+chi' \
  --from-literal=DEPLOYEX_ERLANG_COOKIE='cookie' \
  --from-literal=DEPLOYEX_ADMIN_HASHED_PASSWORD='$2b$12$vNAn.RJezPdQF7Dcy4c9Q.p34hdeNnkIaGTk80xdc/Rk18vWjUOC.'
kubectl apply -f "$here/deployex.yaml"
# The pod is ready once an application is published and answers: make docker-app
kubectl rollout status deployment/deployex --timeout=60s || kubectl get pods
echo "DeployEx: http://localhost:5011 (admin / deployex). The app, once published: http://localhost:8090"
echo "kubectl for this cluster: export KUBECONFIG=$KUBECONFIG"
