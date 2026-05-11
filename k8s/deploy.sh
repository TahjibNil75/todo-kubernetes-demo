#!/bin/bash

set -e
trap 'echo "❌ Script failed at line $LINENO — exiting." >&2' ERR

# -------------------------
# CONFIG — only edit these
# -------------------------
REGION="ap-south-1"
CLUSTER_NAME="todo-eks-cluster"
PROFILE="mlbd-tahjib"
NAMESPACE="todo-app"

echo "=============================="
echo "🚀 EKS FULL DEPLOY"
echo "=============================="

# -------------------------
# STEP 1: KUBECONFIG + DERIVE VARS
# -------------------------
echo ""
echo "🔧 [1/9] Updating kubeconfig..."
aws eks \
  --region $REGION \
  --profile $PROFILE \
  update-kubeconfig \
  --name $CLUSTER_NAME

AWS_ACCOUNT_ID=$(aws sts get-caller-identity \
  --profile $PROFILE \
  --query Account \
  --output text)

OIDC_ID=$(aws eks describe-cluster \
  --name $CLUSTER_NAME \
  --region $REGION \
  --profile $PROFILE \
  --query 'cluster.identity.oidc.issuer' \
  --output text | cut -d'/' -f5)

EBS_ROLE_NAME="ebs-csi-${CLUSTER_NAME}"
# IAM role names max 64 chars — truncate if needed
EBS_ROLE_NAME=$(echo "$EBS_ROLE_NAME" | cut -c1-64)

echo "  ✅ Account ID : $AWS_ACCOUNT_ID"
echo "  ✅ OIDC ID    : $OIDC_ID"
echo "  ✅ EBS Role   : $EBS_ROLE_NAME"

# -------------------------
# STEP 1.5: CLEAN EXISTING EBS CSI ADDON
# -------------------------
echo ""
echo "🧹 Cleaning existing EBS CSI addon if present..."
AWS_PROFILE=$PROFILE eksctl delete addon \
  --name aws-ebs-csi-driver \
  --cluster $CLUSTER_NAME \
  --region $REGION 2>/dev/null || echo "  ℹ️  No existing addon to delete"

echo "  ⏳ Waiting for old CSI pods to terminate..."
kubectl wait pod \
  -n kube-system \
  -l app=ebs-csi-controller \
  --for=delete \
  --timeout=60s 2>/dev/null || true

# -------------------------
# STEP 2: EBS CSI IAM ROLE
# -------------------------
echo ""
echo "🔑 [2/9] Creating IAM role for EBS CSI driver..."

cat > /tmp/ebs-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/oidc.eks.${REGION}.amazonaws.com/id/${OIDC_ID}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.${REGION}.amazonaws.com/id/${OIDC_ID}:sub": "system:serviceaccount:kube-system:ebs-csi-controller-sa",
          "oidc.eks.${REGION}.amazonaws.com/id/${OIDC_ID}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF

aws iam create-role \
  --role-name $EBS_ROLE_NAME \
  --assume-role-policy-document file:///tmp/ebs-trust.json \
  --profile $PROFILE 2>/dev/null || echo "  ℹ️  IAM role already exists, skipping..."

aws iam attach-role-policy \
  --role-name $EBS_ROLE_NAME \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
  --profile $PROFILE 2>/dev/null || echo "  ℹ️  Policy already attached, skipping..."

rm -f /tmp/ebs-trust.json

kubectl create serviceaccount ebs-csi-controller-sa \
  -n kube-system --dry-run=client -o yaml | kubectl apply -f -

kubectl annotate sa ebs-csi-controller-sa \
  -n kube-system \
  eks.amazonaws.com/role-arn=arn:aws:iam::${AWS_ACCOUNT_ID}:role/${EBS_ROLE_NAME} \
  --overwrite

# -------------------------
# STEP 3: EBS CSI ADDON
# -------------------------
echo ""
echo "🧩 [3/9] Installing EBS CSI driver addon..."
AWS_PROFILE=$PROFILE eksctl create addon \
  --name aws-ebs-csi-driver \
  --cluster $CLUSTER_NAME \
  --region $REGION \
  --service-account-role-arn arn:aws:iam::${AWS_ACCOUNT_ID}:role/${EBS_ROLE_NAME} \
  --force

echo "  ⏳ Waiting for EBS CSI deployment to appear..."
until kubectl get deployment/ebs-csi-controller -n kube-system &>/dev/null; do
  echo "  ... deployment not yet created, retrying in 10s"
  sleep 10
done

echo "  ⏳ Waiting for EBS CSI controller to be ready..."
kubectl rollout status deployment/ebs-csi-controller -n kube-system --timeout=180s

# -------------------------
# STEP 4: ALB CONTROLLER
# -------------------------
echo ""
echo "⚖️  [4/9] Installing AWS Load Balancer Controller..."

curl -sO https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json \
  --profile $PROFILE 2>/dev/null || echo "  ℹ️  IAM policy already exists, skipping..."

rm -f iam_policy.json

AWS_PROFILE=$PROFILE eksctl create iamserviceaccount \
  --cluster $CLUSTER_NAME \
  --namespace kube-system \
  --name aws-load-balancer-controller \
  --region $REGION \
  --attach-policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy \
  --override-existing-serviceaccounts \
  --approve

helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
helm repo update

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller

echo "  ⏳ Waiting for ALB controller to be ready..."
kubectl rollout status deployment/aws-load-balancer-controller -n kube-system --timeout=120s

# -------------------------
# STEP 5: NAMESPACE + BASE RESOURCES
# -------------------------
echo ""
echo "📦 [5/9] Creating namespace and base resources..."
kubectl apply -f namespace.yaml
kubectl apply -f storageclass.yaml
kubectl apply -f secrets.yaml
kubectl apply -f configmap.yaml

# -------------------------
# STEP 6: POSTGRES
# -------------------------
echo ""
echo "🐘 [6/9] Deploying PostgreSQL..."
kubectl apply -f postgres-service.yaml
kubectl apply -f postgres-statefulset.yaml

echo "  ⏳ Waiting for PVC to bind (EBS provisioning can take ~60s)..."
kubectl wait \
  --for=jsonpath='{.status.phase}'=Bound \
  pvc/postgres-storage-postgres-0 \
  -n $NAMESPACE \
  --timeout=300s

echo "  ⏳ Waiting for PostgreSQL pod to be ready..."
kubectl wait \
  --for=condition=ready \
  pod/postgres-0 \
  -n $NAMESPACE \
  --timeout=300s

# -------------------------
# STEP 7: BACKEND
# -------------------------
echo ""
echo "🚀 [7/9] Deploying backend..."
kubectl apply -f backend-deployment.yaml
kubectl apply -f backend-service.yaml

echo "  ⏳ Waiting for backend rollout..."
kubectl rollout status deployment/backend -n $NAMESPACE --timeout=300s

# -------------------------
# STEP 8: FRONTEND
# -------------------------
echo ""
echo "🎨 [8/9] Deploying frontend..."
kubectl apply -f frontend-deployment.yaml
kubectl apply -f frontend-service.yaml

echo "  ⏳ Waiting for frontend rollout..."
kubectl rollout status deployment/frontend -n $NAMESPACE --timeout=300s

# -------------------------
# STEP 9: INGRESS
# -------------------------
echo ""
echo "🌐 [9/9] Deploying ingress (ALB)..."
kubectl apply -f ingress.yaml

echo "  ⏳ Waiting for ALB hostname (up to 3 minutes)..."
for i in $(seq 1 18); do
  HOSTNAME=$(kubectl get ingress todo-app-ingress -n $NAMESPACE \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  if [ -n "$HOSTNAME" ]; then
    break
  fi
  echo "  ... still waiting ($((i*10))s)"
  sleep 10
done

# -------------------------
# SUMMARY
# -------------------------
echo ""
echo "=============================="
echo "✅ DEPLOYMENT COMPLETE"
echo "=============================="
echo ""
kubectl get pods -n $NAMESPACE
echo ""
kubectl get svc -n $NAMESPACE
echo ""
kubectl get ingress -n $NAMESPACE
echo ""

HOSTNAME=$(kubectl get ingress todo-app-ingress -n $NAMESPACE \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)

if [ -n "$HOSTNAME" ]; then
  echo "🌍 App URL: http://$HOSTNAME"
else
  echo "⚠️  ALB hostname not ready yet. Run to check:"
  echo "    kubectl get ingress -n $NAMESPACE"
fi