# Release Repository - Kubernetes Manifests

ArgoCD GitOps repository containing Kubernetes manifests for the demo-app across environments.

## Structure

```
release-repo/
├── argocd/       # ArgoCD Application manifests (one per environment)
├── demo/         # Self-contained demo env — deployed to the harness-sruthi namespace
├── dev/          # Development environment (1 replica, minimal resources)
├── staging/      # Staging environment (2 replicas, moderate resources)
└── prod/         # Production environment (3 replicas, high resources, rolling updates)
```

## GitOps topology

- **GitOps agent**: account-level Harness GitOps agent `argoagentdemo`, running in the
  `harness-sruthi` namespace of the `ise-lab` EKS cluster.
- **Applications**: defined in `argocd/`. Each `Application` points at one env directory and
  syncs it to a target namespace. `destination.namespace` (not a hardcoded `metadata.namespace`
  in the manifests) controls placement — the manifests stay namespace-agnostic.
- **Sync policy**: dev/staging/demo are fully automated (`prune: true`, `selfHeal: true`);
  prod is manual-sync so promotions are deliberate.
- The `demo/` app is the one wired up live in this environment (namespace `harness-sruthi`)
  and uses a public image so it runs without any private registry credentials.

Apply the Applications through the Harness GitOps agent (recommended) or directly:

```bash
kubectl apply -f argocd/demo-app-demo.yaml
```

Each environment contains:
- `deployment.yaml` - Kubernetes Deployment manifest
- `service.yaml` - Kubernetes Service manifest
- `values.yaml` - Environment-specific configuration values

## Environment Differences

| Config | Dev | Staging | Prod |
|--------|-----|---------|------|
| Replicas | 1 | 2 | 3 |
| Memory Request | 256Mi | 512Mi | 1Gi |
| Memory Limit | 512Mi | 1Gi | 2Gi |
| CPU Request | 250m | 500m | 1000m |
| CPU Limit | 500m | 1000m | 2000m |
| Image Pull Policy | Always | Always | IfNotPresent |
| Liveness Initial Delay | 30s | 30s | 60s |
| Readiness Initial Delay | 10s | 10s | 20s |
| Deployment Strategy | - | - | RollingUpdate (maxSurge:1, maxUnavailable:0) |

## ArgoCD Application Setup

Example ArgoCD Application manifest for dev:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: demo-app-dev
  namespace: argocd
spec:
  project: default
  source:
    repoURL: <your-release-repo-url>
    targetRevision: HEAD
    path: dev
  destination:
    server: https://kubernetes.default.svc
    namespace: dev
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
```

## Image Tag Updates

To deploy a new version, update the `image` field in the respective environment's `deployment.yaml`:

```yaml
image: demo-app:v1.2.3  # Update this tag
```

For automated updates via CI/CD, use tools like:
- `yq` to update YAML in-place
- `kustomize` with image overlays
- ArgoCD Image Updater
- Harness GitOps with automated image tag management

## Health Checks

All environments use the `/health` endpoint for:
- **Liveness probe** - Restart unhealthy containers
- **Readiness probe** - Remove unhealthy pods from service load balancing

## Notes

- All services use `ClusterIP` type (internal cluster access only)
- Service exposes port 80, forwards to container port 8080
- Spring profiles are set via `SPRING_PROFILES_ACTIVE` environment variable
- Production includes JVM tuning via `JAVA_OPTS`
