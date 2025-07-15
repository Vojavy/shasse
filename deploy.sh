#!/bin/bash
set -e

if [ "$1" != "dev" ] && [ "$1" != "prod" ]; then
  echo "Usage: $0 dev|prod"
  exit 1
fi

echo "Applying ConfigMap and Secrets..."
kubectl apply -f ./k3s/envs/

echo "Applying Ingress..."
kubectl apply -f ./k3s/ingress/

echo "Applying $1 overlay for music-service..."
kubectl apply -k ./k3s/services/music/$1

if [ "$1" = "dev" ]; then
  echo "Запуск minikube tunnel в фоне..."
  nohup minikube tunnel >/dev/null 2>&1 &
  disown
fi

echo "✅ $1 deployment complete!"
