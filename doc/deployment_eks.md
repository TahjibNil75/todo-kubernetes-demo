# Deploying a Full-Stack App on AWS EKS — A Beginner's Guide to Kubernetes Manifests

So you've built a full-stack app, dockerized it, and now you want to deploy it on a real cloud Kubernetes cluster. This guide walks you through deploying a Todo application on **AWS EKS (Elastic Kubernetes Service)** using Kubernetes manifest files — step by step, concept by concept.

By the end of this post you'll understand:
- What each manifest file does and why it exists
- How all the pieces connect together
- How to deploy everything on EKS from scratch

The repo contains a Dockerized frontend (React + Nginx) and backend (FastAPI) which we'll deploy on AWS EKS using the Kubernetes manifest files covered in this guide.

---

## What is Kubernetes and Why EKS?

**Kubernetes (K8s)** is a system that manages containerized applications across a cluster of machines. Instead of manually running `docker run` on servers, you describe *what* you want running (in YAML files called manifests) and Kubernetes makes it happen — and keeps it that way.

**AWS EKS** is Amazon's managed Kubernetes service. It handles the hard parts (the control plane, upgrades, high availability) so you can focus on deploying your app.

---

## The Big Picture

Here's what we're deploying:

```
Internet
   │
   ▼
AWS ALB (Load Balancer)        ← created by ingress.yaml
   │
   ├── /api  ──────────────►  Backend Pods (FastAPI)
   │                               │
   └── /     ──────────────►  Frontend Pods (React/Nginx)
                                   
Backend Pods ──────────────►  PostgreSQL (StatefulSet)
                                   │
                              EBS Volume (persistent disk)
```

Every arrow in that diagram corresponds to a Kubernetes manifest file. Let's go through each one.

---

## Prerequisites

Before deploying, you need:

- An AWS account with CLI configured (`aws configure`)
- `eksctl` installed — [install guide](https://eksctl.io/installation/)
- `kubectl` installed — [install guide](https://kubernetes.io/docs/tasks/tools/)
- `helm` installed — [install guide](https://helm.sh/docs/intro/install/)

---

## Step 1 — Create the EKS Cluster

First, create the cluster control plane (no worker nodes yet):

```bash
eksctl create cluster \
  --name todo-eks-cluster \
  --region ap-south-1 \
  --zones ap-south-1a,ap-south-1b \
  --without-nodegroup \
  --profile <your-aws-profile>
```

Then enable OIDC — this lets Kubernetes pods securely talk to AWS services:

```bash
eksctl utils associate-iam-oidc-provider \
  --region ap-south-1 \
  --cluster todo-eks-cluster \
  --approve \
  --profile <your-aws-profile>
```

Then add worker nodes:

```bash
eksctl create nodegroup \
  --cluster todo-eks-cluster \
  --name medium-ng \
  --region ap-south-1 \
  --instance-types t3.medium \
  --nodes 2 \
  --nodes-min 1 \
  --nodes-max 3 \
  --node-volume-size 20 \
  --node-volume-type gp3 \
  --managed \
  --alb-ingress-access \
  --asg-access \
  --full-ecr-access \
  --profile <your-aws-profile>
```

> **What are worker nodes?** The control plane is Kubernetes' brain — it makes decisions. Worker nodes are the actual machines that run your containers.

---

## The Manifest Files — One by One

All YAML files live in the `k8s/` folder. Here's the full list and how they connect:

```
k8s/
├── namespace.yaml
├── storageclass.yaml
├── secrets.yaml
├── configmap.yaml
├── postgres-service.yaml
├── postgres-statefulset.yaml
├── backend-deployment.yaml
├── backend-service.yaml
├── frontend-deployment.yaml
├── frontend-service.yaml
└── ingress.yaml
```

---

### `namespace.yaml` — The Boundary

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: todo-app
```

**What it does:** Creates an isolated space called `todo-app` inside the cluster.

**Think of it like:** A folder on your computer. Everything — pods, services, secrets — lives inside this namespace. It keeps your app's resources separate from other apps running on the same cluster.

Every other manifest has `namespace: todo-app` in it, which is how Kubernetes knows they all belong together.

---

### `storageclass.yaml` — The Disk Blueprint

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ebs-sc
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
parameters:
  type: gp3
```

**What it does:** Defines *how* to create a persistent disk when one is requested. It uses AWS EBS (Elastic Block Store) — a cloud hard drive.

**Key settings explained:**
- `provisioner: ebs.csi.aws.com` — use the AWS EBS driver to create disks
- `volumeBindingMode: WaitForFirstConsumer` — don't create the disk until a pod actually needs it (important for EBS which is zone-specific)
- `reclaimPolicy: Retain` — keep the disk even if the app is deleted (protects your data)

**Think of it like:** A template for ordering a hard drive. When PostgreSQL says "I need 10GB of storage", Kubernetes looks at this template to know how to provision it on AWS.

---

### `secrets.yaml` — Sensitive Credentials

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: todo-app-secrets
  namespace: todo-app
type: Opaque
data:
  DB_USER: dG9kb2FwcA==       # base64 encoded
  DB_PASSWORD: c3VwZXJzZWNyZXQ=
```

**What it does:** Stores sensitive values (database username and password) separately from your application code.

**Why base64?** Kubernetes Secrets store values as base64-encoded strings. It's not encryption — it's just encoding. For production, use a proper secrets manager like AWS Secrets Manager or HashiCorp Vault.

To encode your own values:
```bash
echo -n "mypassword" | base64
```

**Think of it like:** A locked box that pods can open when they need credentials — without those credentials being hardcoded in your Docker images or YAML files.

---

### `configmap.yaml` — Non-Secret Configuration

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: todo-app-config
  namespace: todo-app
data:
  DB_HOST: "postgres-service"
  DB_PORT: "5432"
  DB_NAME: "todoapp"
```

**What it does:** Stores non-sensitive configuration that pods need — like the database hostname and port.

**Notice `DB_HOST: "postgres-service"`** — this is not an IP address. It's a Kubernetes DNS name that resolves to the PostgreSQL service. This is how pods find each other inside the cluster.

**Think of it like:** Environment variables for your app, but managed by Kubernetes so you can update them without rebuilding Docker images.

---

### `postgres-service.yaml` — The Database's Address

```yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres-service
  namespace: todo-app
spec:
  type: ClusterIP
  clusterIP: None          # headless service
  selector:
    app: postgres
  ports:
  - port: 5432
    targetPort: 5432
```

**What it does:** Gives the PostgreSQL pod a stable DNS name (`postgres-service`) that other pods can use to connect to it.

**Why `clusterIP: None`?** This makes it a "headless" service, which is required for StatefulSets. Instead of load balancing across pods, it returns the pod's IP directly. Since we only have one Postgres pod, this is what we want.

**Think of it like:** A phone book entry. Instead of pods needing to know Postgres's exact IP (which changes every time a pod restarts), they just call `postgres-service:5432` and Kubernetes handles the routing.

---

### `postgres-statefulset.yaml` — The Database Itself

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: todo-app
spec:
  serviceName: postgres-service
  replicas: 1
  ...
  volumeClaimTemplates:
  - metadata:
      name: postgres-storage
    spec:
      storageClassName: ebs-sc
      resources:
        requests:
          storage: 10Gi
```

**What it does:** Runs the PostgreSQL database container and automatically requests a 10GB EBS volume for it.

**Why StatefulSet and not Deployment?** Deployments are for stateless apps — any pod is interchangeable. StatefulSets are for stateful apps like databases where:
- Each pod has a stable, predictable name (`postgres-0`)
- Each pod gets its own persistent storage that follows it around
- Pods start and stop in order

**The connection chain:**
- `serviceName: postgres-service` → connects to the Service we created above
- `storageClassName: ebs-sc` → uses the StorageClass to provision an EBS volume
- Reads `DB_NAME` from the ConfigMap and `DB_USER`/`DB_PASSWORD` from the Secret

**`PGDATA: /var/lib/postgresql/data/pgdata`** — This sets the data directory to a subdirectory, which avoids an issue where PostgreSQL refuses to start if the mount point has a `lost+found` directory.

---

### `backend-deployment.yaml` — The API

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: todo-app
spec:
  replicas: 2
  ...
  initContainers:
  - name: wait-for-postgres
    image: busybox
    command:
      - sh
      - -c
      - until nc -z postgres-service 5432; do echo waiting; sleep 2; done
```

**What it does:** Runs 2 copies of the backend API container.

**Key concepts:**

**Init container** — Before the backend starts, a tiny `busybox` container runs first and keeps checking if `postgres-service:5432` is reachable. Only when Postgres is ready does the actual backend container start. This prevents the "backend crashed because DB wasn't ready" problem.

**Replicas: 2** — Two identical backend pods run at the same time. If one crashes, the other keeps serving traffic. Kubernetes automatically restarts the crashed one.

**Rolling update strategy** — When you deploy a new version, Kubernetes replaces pods one at a time — so there's zero downtime.

**Readiness/Liveness probes:**
- **Readiness** — "Is this pod ready to receive traffic?" Kubernetes won't send requests to a pod until this passes.
- **Liveness** — "Is this pod still healthy?" If this fails repeatedly, Kubernetes restarts the pod.

---

### `backend-service.yaml` — The API's Internal Address

```yaml
apiVersion: v1
kind: Service
metadata:
  name: backend-service
  namespace: todo-app
spec:
  type: ClusterIP
  selector:
    app: backend
  ports:
  - port: 8000
    targetPort: 8000
```

**What it does:** Creates a stable internal address for the backend pods.

Since we have 2 backend pods, this service also **load balances** between them — requests are distributed across both pods automatically.

**Think of it like:** A receptionist in front of the backend team. You call `backend-service:8000` and the receptionist forwards you to whichever backend pod is available.

---

### `frontend-deployment.yaml` and `frontend-service.yaml`

These work exactly the same way as the backend equivalents — a Deployment running 2 Nginx pods serving the React app, and a ClusterIP Service in front of them on port 80.

---

### `ingress.yaml` — The Internet Gateway

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: todo-app-ingress
  namespace: todo-app
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
spec:
  ingressClassName: alb
  rules:
  - http:
      paths:
      - path: /api
        pathType: Prefix
        backend:
          service:
            name: backend-service
            port:
              number: 8000
      - path: /
        pathType: Prefix
        backend:
          service:
            name: frontend-service
            port:
              number: 80
```

**What it does:** Creates an AWS Application Load Balancer (ALB) and routes incoming internet traffic to the right service based on the URL path.

**Routing rules:**
- `/api` and anything under it → `backend-service:8000`
- `/` and everything else → `frontend-service:80`

**Why `ingressClassName: alb`?** This tells Kubernetes to use the AWS Load Balancer Controller to provision a real AWS ALB. Without the controller installed, this Ingress would just sit there doing nothing.

**`internet-facing`** — the ALB gets a public IP/hostname accessible from the internet. The alternative is `internal` for private load balancers.

**Think of it like:** The front door of your app. All traffic enters here and gets directed to the right place.

---

## How Everything Connects

Here's the full dependency chain:

```
namespace.yaml
    │
    ├── storageclass.yaml ──────────────────────────────┐
    │                                                   │
    ├── secrets.yaml ─────────────────┐                 │
    │                                 │                 │
    ├── configmap.yaml ───────────────┤                 │
    │                                 │                 ▼
    ├── postgres-service.yaml ──► postgres-statefulset.yaml
    │                                       │
    │                               (EBS volume created)
    │                                       │
    ├── backend-deployment.yaml ◄───────────┘
    │   (init container waits for postgres-service)
    │
    ├── backend-service.yaml ◄── backend-deployment.yaml
    │
    ├── frontend-deployment.yaml
    │
    ├── frontend-service.yaml ◄── frontend-deployment.yaml
    │
    └── ingress.yaml ◄── backend-service + frontend-service
```

---

## Step 2 — Install Cluster Add-ons

Before applying the manifests, two add-ons must be installed:

### EBS CSI Driver

This allows Kubernetes to create and attach EBS volumes:

```bash
# Create IAM role for EBS CSI
eksctl create iamserviceaccount \
  --name ebs-csi-controller-sa \
  --namespace kube-system \
  --cluster todo-eks-cluster \
  --region ap-south-1 \
  --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
  --approve

# Install the addon
eksctl create addon \
  --name aws-ebs-csi-driver \
  --cluster todo-eks-cluster \
  --region ap-south-1 \
  --force
```

### AWS Load Balancer Controller

This watches for Ingress objects and creates real AWS ALBs:

```bash
# Download and create IAM policy
curl -sO https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json

# Create service account
eksctl create iamserviceaccount \
  --cluster todo-eks-cluster \
  --namespace kube-system \
  --name aws-load-balancer-controller \
  --attach-policy-arn arn:aws:iam::<your-account-id>:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve

# Install via Helm
helm repo add eks https://aws.github.io/eks-charts
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=todo-eks-cluster \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller
```

---

## Step 3 — Apply the Manifests

Now apply everything in the correct order:

```bash
# Foundation
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/storageclass.yaml
kubectl apply -f k8s/secrets.yaml
kubectl apply -f k8s/configmap.yaml

# Database
kubectl apply -f k8s/postgres-service.yaml
kubectl apply -f k8s/postgres-statefulset.yaml

# Wait for Postgres to be ready
kubectl wait --for=condition=ready pod/postgres-0 -n todo-app --timeout=300s

# Application
kubectl apply -f k8s/backend-deployment.yaml
kubectl apply -f k8s/backend-service.yaml
kubectl apply -f k8s/frontend-deployment.yaml
kubectl apply -f k8s/frontend-service.yaml

# Ingress (ALB)
kubectl apply -f k8s/ingress.yaml
```

Or use the provided `deploy.sh` script which handles all of this automatically including waiting for each step to complete.

---

## Step 4 — Verify the Deployment

```bash
# Check all pods are running
kubectl get pods -n todo-app

# Expected output:
# NAME                        READY   STATUS    RESTARTS   AGE
# postgres-0                  1/1     Running   0          3m
# backend-7d6f8b9c4-xk2p9    1/1     Running   0          2m
# backend-7d6f8b9c4-mn3q1    1/1     Running   0          2m
# frontend-6c8d9f7b5-pq4r2   1/1     Running   0          2m
# frontend-6c8d9f7b5-rs5t3   1/1     Running   0          2m

# Check services
kubectl get svc -n todo-app

# Get the ALB hostname (takes 2-3 minutes to provision)
kubectl get ingress -n todo-app
```

Once the `ADDRESS` column shows a hostname in the ingress output, open it in your browser — your app is live.

---

## Common Issues and Fixes

**PVC stuck in Pending**
The EBS CSI driver may not be ready or lacks IAM permissions. Check:
```bash
kubectl describe pvc postgres-storage-postgres-0 -n todo-app
kubectl get pods -n kube-system | grep ebs-csi
```

**Ingress has no ADDRESS after 5+ minutes**
The ALB controller may have an error. Check:
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=20
```

**Backend pods crashing**
Usually the init container is waiting for Postgres. Check:
```bash
kubectl describe pod -l app=backend -n todo-app
kubectl logs -l app=backend -n todo-app
```

---

## Key Concepts Summary

| Concept | What it is | Example in this project |
|---|---|---|
| Namespace | Isolated group of resources | `todo-app` |
| ConfigMap | Non-secret config | DB host, port, name |
| Secret | Sensitive config | DB username, password |
| StorageClass | Disk provisioning template | EBS gp3 volumes |
| StatefulSet | Manages stateful pods | PostgreSQL |
| Deployment | Manages stateless pods | Backend, Frontend |
| Service (ClusterIP) | Internal load balancer / DNS | `postgres-service`, `backend-service` |
| Ingress | External traffic routing | ALB routing `/api` and `/` |
| Init Container | Runs before main container | Wait for Postgres |
| PVC | Persistent storage request | 10Gi for Postgres data |

---

## Wrapping Up

Deploying on Kubernetes might feel overwhelming at first, but the core idea is simple: **you describe what you want, and Kubernetes makes it happen.**

Each manifest file is a piece of that description — the namespace is the boundary, the secrets and configmaps are the configuration, the statefulset and deployments are the workloads, the services are the internal networking, and the ingress is the front door.

Once you understand how these pieces connect, deploying any application to Kubernetes follows the same pattern.

The full source code including the `deploy.sh` automation script is in the `k8s/` folder of the repository.