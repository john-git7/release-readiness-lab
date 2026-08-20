#!/bin/bash
set -euo pipefail

echo "============================================="
echo "EMERGENCY ROLLBACK: Checkout API Service"
echo "Target Stable Baseline: v2.3"
echo "============================================="

NAMESPACE="checkout-system"
DEPLOYMENT="checkout-api"
STABLE_IMAGE="kalvium/checkout-api:v2.3"

# Check if namespace exists
if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "Error: Namespace $NAMESPACE not found!"
    exit 1
fi

echo "[$(date -u +%T)] Reverting deployment image to $STABLE_IMAGE..."
kubectl set image deployment/"$DEPLOYMENT" "$DEPLOYMENT"="$STABLE_IMAGE" -n "$NAMESPACE"

echo "[$(date -u +%T)] Waiting for rollback rollout to complete..."
kubectl rollout status deployment/"$DEPLOYMENT" -n "$NAMESPACE" --timeout=120s

echo "============================================="
echo "Rollback successfully completed."
echo "Current pod status:"
kubectl get pods -n "$NAMESPACE" -l app=checkout-api
echo "============================================="
