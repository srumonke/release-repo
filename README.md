# release-repo — GitOps manifests for `service-a`

Kubernetes manifests for the `service-a` demo app, deployed by **Harness GitOps (ArgoCD)**.
This is the **source of truth for what runs in each cluster**: nothing is `kubectl apply`-ed by
hand — a change is deployed by committing to this repo and letting ArgoCD reconcile it.

Paired with the application source in
[`application-repo`](https://github.com/srumonke/application-repo).

## Structure

```
release-repo/
├── argocd/                    # ArgoCD Application definitions (reference copies)
│   ├── demo-app-dev.yaml      # watches dev/,  auto-sync (prune + selfHeal)
│   └── demo-app-prod.yaml     # watches prod/, MANUAL sync (pipeline-driven)
├── dev/                       # Dev environment
│   ├── deployment.yaml        # 1 replica, small resources
│   └── service.yaml           # ClusterIP :80 → :8080
└── prod/                      # Prod environment
    ├── deployment.yaml        # 3 replicas, RollingUpdate (zero-downtime)
    └── service.yaml           # ClusterIP :80 → :8080
```

## How deployment works (GitOps)

```
edit deployment.yaml image tag  →  git commit  →  ArgoCD detects  →  cluster matches Git
   (declares desired state)        (the deploy)     (reconcile)        (running state)
```

Each ArgoCD `Application` in `argocd/` points at one env directory and syncs it to a namespace:

| App | Path | Namespace | Sync policy |
|-----|------|-----------|-------------|
| `demo-app-dev`  | `dev/`  | `dev`  | Automated (`prune` + `selfHeal`) |
| `demo-app-prod` | `prod/` | `prod` | **Manual** — promotions go through the Harness CD pipeline |

Dev auto-syncs on every commit. **Prod is deliberately manual** so a promotion is an explicit,
approved, audited action driven by the `service-a-hotfix` pipeline (see application-repo), not a
silent reaction to a commit.

## Environment differences

| Config | Dev | Prod |
|--------|-----|------|
| Replicas | 1 | 3 |
| Strategy | RollingUpdate (default) | RollingUpdate `maxSurge:1, maxUnavailable:0` |
| Memory request / limit | 256Mi / 512Mi | 256Mi / 1Gi* |
| CPU request / limit | 250m / 500m | 150m / 1000m* |
| Spring profile | `dev` | `prod` (+ `JAVA_OPTS` tuning) |

\* Prod resource *requests* are trimmed for a local `kind` cluster. A real prod would request
~1Gi / 1000m per replica.

## Deploying a new version

**Manual (dev):** bump the image tag and commit — ArgoCD auto-syncs.

```bash
# edit dev/deployment.yaml → image: ghcr.io/srumonke/service-a:<new-tag>
git commit -am "Deploy service-a <new-tag> to dev" && git push
```

**Prod:** run the `service-a-hotfix` pipeline. After the approval gate, its **Update Release Repo**
step opens a PR bumping `prod/deployment.yaml` to the release tag, **Merge PR** merges it, and
**GitOps Sync** rolls prod. See [application-repo](https://github.com/srumonke/application-repo) for
the full pipeline (build → scan → deploy dev → approval → retag → deploy prod).

## Health checks

Both environments probe `GET /health` (returns `{"status":"UP"}`) for liveness and readiness.
Services are `ClusterIP`, exposing port 80 → container port 8080.

## Registering the ArgoCD Applications

The manifests in `argocd/` are reference copies. Apply them through the Harness GitOps agent, or
directly against a cluster that has ArgoCD:

```bash
kubectl apply -f argocd/demo-app-dev.yaml
kubectl apply -f argocd/demo-app-prod.yaml
```
