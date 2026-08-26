#!/usr/bin/env bash

set -euo pipefail

NAMESPACE="argocd"
ARGOCD_MANIFEST="https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"

echo "Creating Argo CD namespace..."

kubectl create namespace "${NAMESPACE}" \
  --dry-run=client \
  -o yaml | kubectl apply -f -

echo "Installing Argo CD..."

kubectl apply \
  --server-side \
  --force-conflicts \
  -n "${NAMESPACE}" \
  -f "${ARGOCD_MANIFEST}"

echo "Waiting 30 seconds for Argo CD resources..."

sleep 30

echo "Forcing Argo CD onto controller..."

for deployment in \
  argocd-server \
  argocd-repo-server \
  argocd-dex-server \
  argocd-notifications-controller \
  argocd-applicationset-controller \
  argocd-redis
do

  kubectl -n "${NAMESPACE}" patch deployment "${deployment}" \
    --type=merge \
    -p '{
      "spec": {
        "template": {
          "spec": {
            "nodeSelector": {
              "kubernetes.io/hostname": "controller"
            },
            "tolerations": [
              {
                "key": "node-role.kubernetes.io/control-plane",
                "operator": "Exists",
                "effect": "NoSchedule"
              }
            ]
          }
        }
      }
    }'

done

kubectl -n "${NAMESPACE}" patch statefulset argocd-application-controller \
  --type=merge \
  -p '{
    "spec": {
      "template": {
        "spec": {
          "nodeSelector": {
            "kubernetes.io/hostname": "controller"
          },
          "tolerations": [
            {
              "key": "node-role.kubernetes.io/control-plane",
              "operator": "Exists",
              "effect": "NoSchedule"
            }
          ]
        }
      }
    }
  }'

echo
echo "=========================================="
echo " Argo CD installed on controller"
echo "=========================================="

kubectl get pods -n "${NAMESPACE}" -o wide
