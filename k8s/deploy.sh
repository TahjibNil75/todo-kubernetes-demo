#!/bin/bash

set -e

# -------------------------
# CONFIG
# -------------------------
REGION="ap-south-1"
CLUSTER_NAME="<your-cluster-name>"
PROFILE="<your-profile-name-configure-in-cli>"
NAMESPACE="todo-app"

echo "🔧 Updating kubeconfig..."
aws eks --region $REGION \
  --profile $PROFILE \
  update-kubeconfig \
  --name $CLUSTER_NAME

echo "📦 Creating namespace..."
kubectl apply -f namespace.yml

echo "🔐 Applying secrets..."
kubectl apply -f secrets.yml

echo "⚙️ Applying configmap..."
kubectl apply -f configmap.yaml

echo "💾 Applying PVC..."
kubectl apply -f pvc.yaml

echo " Deploying PostgreSQL..."
kubectl apply -f postgres-service.yml
kubectl apply -f postgres-statefulset.yaml

echo "⏳ Waiting for PostgreSQL to be ready..."
kubectl wait --for=condition=ready pod -l app=postgres -n $NAMESPACE --timeout=180s

echo "🚀 Deploying backend..."
kubectl apply -f backend-deployment.yml
kubectl apply -f backend-service.yaml

echo "🎨 Deploying frontend..."
kubectl apply -f frontend-deployment.yaml
kubectl apply -f frontend-service.yml

echo "🌐 Deploying ingress (ALB)..."
kubectl apply -f ingress.yml

echo "✅ All resources deployed successfully!"
echo "📊 Checking pods..."
kubectl get pods -n $NAMESPACE

echo "🔗 Services:"
kubectl get svc -n $NAMESPACE

echo "🌍 Ingress:"
kubectl get ingress -n $NAMESPACE