# Everest hotfix deploy — Jira-driven, version-locked GitOps flow

**The one-line story:** a hotfix version is deployed across a *set* of services, and Harness refuses
to start unless every service in that set is on the same released version.

A hotfix is rarely one service. It is a group that has to move together, and if one member is a patch
behind, deploying the rest is worse than deploying nothing. Everything here exists to enforce that.

This directory holds both halves of the flow:

- **the manifests ArgoCD watches** (`dev/`, `test/`, `prod/`) — the deployed state,
- **the Harness definitions that drive them** (`harness/`) — pipeline, input sets, services, GitOps
  applications, OPA policy.

```
everest/
├── README.md                 ← you are here
├── dev/  test/  prod/
│   └── everest-{a,b}/deployment.yaml     one manifest per service per environment
└── harness/
    ├── pipelines/everest_hotfix_deploy.yaml
    ├── input-sets/everest_hotfix_set.yaml              ← WHERE THE SERVICE NAMES LIVE
    ├── input-sets/everest_hotfix_set_misaligned.yaml   ← the sad-path demo
    ├── policies/hotfix_release_gate.rego
    └── entities/
        ├── services-everest.yaml
        └── gitops-applications-everest.yaml
```

`harness/` is **source, not sync**. Harness Git Experience is not wired up, so editing a file here
does not change the pipeline — these are the authored definitions, kept next to what they deploy so
the two never drift silently. Push changes to Harness with the API or the UI (see
[Recreating this in Harness](#recreating-this-in-harness)).

---

## The flow

Eight stages, mapping to the three stages of the source flow diagram. Two of them wait for a human;
everything else is automatic.

```
STAGE 1   validate ............... OPA policy → input-set completeness → VERSIONS ALIGNED
                                   → Jira ticket cross-check → declared-vs-values
                                   → adjacency pre-check → Jira "cleared to deploy"
                                   ▸ writes nothing but that one comment

STAGE 2   technical_gate ......... HarnessApproval                        ⏸ HUMAN (Harness)

STAGE 3   business_gate .......... JiraApproval on the ticket             ⏸ HUMAN (Jira)
          predeploy_recheck ...... serialize → deployment window → ADJACENCY RE-CHECK
                                   → Jira "deployment started"
          deploy_dev ............. UpdateReleaseRepo → MergePR → GitOpsSync
          deploy_test ............ same, environment test
          deploy_prod ............ same, environment prod
          close_out .............. Jira → Done
```

`allowStageExecutions: true`, so Stage 1 can be run on its own to show the validation without
committing to a deploy.

### The gate, and why it is enforced twice

The central check is `versions_aligned` in Stage 1: every service in the declared set is on the
**same** version, that version equals the requested `hotfixVersion`, and it is not an `-RC` or
`-SNAPSHOT` build.

It is enforced by two independent mechanisms:

1. **`opa_on_run`** — a Policy step evaluating `hotfix_release_gate` against a *custom payload*, so
   the rules see what this specific run actually submitted rather than the stored pipeline YAML. It
   refuses mixed versions, pre-release builds, and malformed ticket keys.
2. **`versions_aligned`** — a shell step doing the same check independently.

Two nets, because this is the single thing the whole flow depends on. Disable the policy set and the
shell step still stops the run.

### One version, derived once

`versions_aligned` exports **`RESOLVED_VERSION`**. Every later stage — both approvals, the re-check,
all three deploys, the closing comment — reads that one output:

```
<+stages.validate.spec.execution.steps.versions_aligned.output.outputVariables.RESOLVED_VERSION>
```

No stage re-parses the input or re-decides what version it is deploying. That is what stops dev and
prod drifting apart mid-run.

### The service names live in the input set

The pipeline hardcodes no service names. `harness/input-sets/everest_hotfix_set.yaml` carries:

```yaml
services:        everest_a,everest_b
serviceVersions: everest_a=4.1.3,everest_b=4.1.3
deploymentTicket: <+input>     # changes every run
hotfixVersion:    <+input>     # changes every run
```

Adding a service is an edit to the input set, not to the pipeline. The ticket and version stay
runtime inputs because they change every run; the service list does not.

Two independent places carry the list — the variables Stage 1 validates, and each deploy stage's
`services.values`. `input_set_complete` and `adjacency_recheck` reconcile them, so editing one and
forgetting the other stops the run instead of silently deploying a subset.

Each deploy stage is multi-service with `metadata: {parallel: false}`, so Harness fans out
`UpdateReleaseRepo → MergePR → GitOpsSync` once per service, in order.

### How a deploy actually happens

Per service, per environment:

| Step | What it does |
|---|---|
| `GitOpsUpdateReleaseRepo` | Patches `spec.template.spec.containers[0].image` in `everest/<env>/<service>/deployment.yaml` and **opens a PR** on this repo. |
| `MergePR` | Squash-merges it. **The merge is the deployment event.** |
| `GitOpsSync` | Tells ArgoCD to sync `<gitopsAppPrefix>-<env>` now rather than waiting for its poll. |

The diff on that PR is the audit trail: a one-line image change, by a named pipeline, against a
ticket. All three deploy stages use a `PipelineRollback` failure strategy, so a prod failure reverts
every service already moved in the run. The set rolls back as a set, the same way it deployed.

### The waiting-room problem

A set can drift while it sits waiting for a human. `predeploy_recheck` therefore runs the adjacency
check **again**, after both gates, and fails the pipeline if any service would now be skipped. It
also:

- **serializes** with a `Queue` step keyed `everest-hotfix-deploy` — two concurrent runs would
  interleave PRs on this repo and the adjacency guarantee would be gone;
- checks a **deployment window** (UTC hours, `0`–`24` by default, i.e. always open). Outside it, the
  run comments *deferred* on the ticket and **holds** at a `Wait` step with
  `onTimeout: MarkAsSuccess`. Deliberately not a Harness freeze window: a freeze *rejects* a run, and
  the requirement is to hold and resume it.

---

## Jira

All five Jira touchpoints go through one connector (`account.CCM_Jira`). There is no Jira URL and no
Jira credential variable in the pipeline — one credential, one thing to rotate.

| Step | Stage | What it needs |
|---|---|---|
| `ticket_cross_check` | 1 | The version string in the ticket's **summary**. Read-only. |
| `jira_cleared` | 1 | Permission to comment. |
| `jira_business_gate` | 3 | Ticket moved to **`Selected for Development`** to approve; **`Invalid`** to reject. |
| `jira_started` | 3 | A transition to **`In Progress`**. |
| `jira_complete` | 3 | A transition to **`Done`**. |

Ticket lifecycle across a run:
`Backlog` → *(human, at the business gate)* `Selected for Development` → `In Progress` → `Done`.

### Never guess a status name

`ticket_cross_check` is a `JiraApproval` with **Jexl** criteria —
`<+issue.Summary>.contains("<RESOLVED_VERSION>")` — rather than a shell step calling the Jira REST
API. Two reasons, both learned the hard way:

- A Harness Jira connector testing green does **not** mean its stored token works for Atlassian REST
  basic auth. Ours is rejected with HTTP 401 by `/rest/api/2/myself`. Using the connector avoids
  minting a second credential just to read one field.
- Jira Cloud answers **404, not 401**, for an unauthenticated read of a private issue, so a bad
  credential looks exactly like a missing ticket. If you ever do debug a raw call, probe
  `/rest/api/2/myself` first.

The tradeoff: an approval step *polls*. A summary that does not mention the version fails at the 5m
timeout instead of instantly — which also means you can fix the summary mid-run and the step picks it
up on its next cycle.

The status names above are the **real** ones for this project (`Backlog`, `Blocked`, `Done`,
`In Progress`, `Invalid`, `Selected for Development`, `Waiting for customer`). Note there is **no
`Approved` and no `Rejected`** — the gate was originally written against those and would have waited
out its full 1-day timeout without ever resolving. A gate wired to a status that does not exist fails
*silently*, which is the worst way for a gate to fail. List a project's statuses before hardcoding:

```
GET /ng/api/jira/statuses?connectorRef=<connector>&projectKey=<KEY>&issueType=Task
```

That endpoint goes through the connector, so it works where raw REST does not.

`Done` is deliberately **not** an approval status: `close_out` sets it, so accepting it at the gate
would let an already-closed ticket auto-approve its own redeploy. `Blocked` and `Waiting for
customer` are holds, not refusals, so they leave the gate waiting rather than failing the run.

---

## Environments

| Environment | Namespace | Replicas | Sync policy |
|---|---|---|---|
| `dev` | `dev` | 1 | **auto-sync** (prune + selfHeal) |
| `test` | `test` | 2 | **manual** — only the pipeline moves it |
| `prod` | `prod` | 3 | **manual** — only the pipeline moves it |

Resources are identical across environments (256Mi–512Mi, 250m–500m) because this is a demo on a
small cluster, not a capacity model.

Do **not** add an `automated:` block to the test or prod GitOps applications. ArgoCD would race the
pipeline, and the gates would stop meaning anything.

### Probes

All six manifests gate startup with a **`startupProbe`** (36 × 5s = 3 min) rather than
`livenessProbe.initialDelaySeconds`. The app needs ~40s to boot under a 500m CPU limit; a liveness
delay long enough to cover that also blinds you to a genuinely hung container for the same period.
The startupProbe owns the boot window, and liveness only engages once it passes.

---

## Recreating this in Harness

Prerequisites, in dependency order:

1. **Connectors** — a Jira connector, and a GitHub connector with write access to this repo (needed
   by `UpdateReleaseRepo`/`MergePR`).
2. **A delegate.** Stage 1's shell steps and every Jira step need one; each shell step sets
   `onDelegate: true`. No `delegateSelectors` are pinned, so any healthy eligible delegate picks the
   work up — account-scoped delegates are eligible for project-scoped executions. This is also why
   Stage 1 is a **Custom** stage: running the shell as CI `Run` steps on hosted build infrastructure
   would split validation across two stages and leave the Jira steps homeless anyway.
3. **GitOps agent + cluster**, and a GitOps repository pointing at this repo.
4. **Environments** `dev`, `test`, `prod`, with the cluster linked to each.
5. **Services** — `harness/entities/services-everest.yaml`. Both need `gitOpsEnabled: true` and a
   **ReleaseRepo manifest**, without which `UpdateReleaseRepo` has nothing to patch. One manifest
   entry covers all three environments via `everest/<+env.name>/<+service.name>/deployment.yaml`, so
   **environment names must equal directory names**.
6. **GitOps applications** — `harness/entities/gitops-applications-everest.yaml`, 2 services × 3
   environments.
7. **Policy + policy set** — `harness/policies/hotfix_release_gate.rego`, entity type Custom, action
   `onstep`, enforced.
8. **Pipeline + both input sets**.

### Gotchas that cost real time

- **A policy set is created EMPTY.** The create call returns `policies: []` even when you pass a
  policies list; attaching is a separate `PATCH`. An empty policy set makes the Policy step **pass
  vacuously** — the gate looks green and enforces nothing. Always read back and assert `policies` is
  non-empty.
- **A policy set with `type: custom` needs `action: onstep`**, not `onrun`.
- **Harness OPA is Rego v0.** Local `opa` 1.x needs `opa check --v0-compatible`. Do not shadow
  builtins — a helper named `trim` is a compile error.
- **Scope prefixes follow the *agent*.** A project-scoped agent means the cluster identifier is plain
  (`incluster`); an account-scoped one means `account.incluster`. Get it wrong and you get
  "No GitOps Cluster is selected".
- **GitOps applications need labels** `harness.io/serviceRef` and `harness.io/envRef`, or GitOpsSync
  fails with "Application does not correspond to the service(s) selected".
- **Never build an image reference from `<+service.name>`** — display names can contain spaces. Use an
  explicit service variable (`imageName` here).
- **Application names are load-bearing**: GitOpsSync resolves
  `<+service.variables.gitopsAppPrefix>-<env>`, so they must be exactly
  `<gitopsAppPrefix>-{dev,test,prod}`.
- **GitOps app creation can return `400 "the request has timed out waiting for the agent"` even
  though the app WAS created.** Re-list before retrying; blind retries just bump the resource
  generation.
- **Input sets are not validated against the pipeline on save.** A variable the pipeline no longer has
  sits there silently. Resolve with `POST /pipeline/api/inputSets/merge` and read the returned
  `pipelineYaml` before trusting it.
- **Running with an input set plus extra runtime inputs**: `/execute/{id}/inputSetList` will not
  accept a `runtimeInputYaml` for the remaining `<+input>`s. Merge first, substitute into the returned
  YAML, then execute that. For a single stage, POST to `/execute/{id}/stages` with
  `{runtimeInputYaml, stageIdentifiers: [...]}`.
- **If the target cluster cannot pull from the registry** (e.g. a local cluster behind a
  TLS-intercepting proxy), the manifests' `imagePullPolicy: IfNotPresent` means preloaded images work
  — but **every new tag the pipeline introduces must be loaded onto the node first**, or the pod goes
  `ErrImagePull` at the end of an otherwise green run.

---

## Running it

Run the pipeline with input set **Everest Hotfix Set**, a deployment ticket whose **summary** mentions
the version, and that version. It stops twice — Stage 2 in Harness, the business gate in Jira — and is
otherwise automatic through prod.

**The run is one-shot.** It leaves all six manifests at the new version, so a second run produces
empty PRs and looks like nothing happened. Reset the manifests to the previous version and push before
running again.

To demo the refusal, run with **Everest Hotfix Set Misaligned** (`everest_b` one patch behind). Stage
1 stops at the policy, every other stage stays `NotStarted`, and nothing is written: no PR, no sync,
no Jira comment.

---

## Deliberately out of scope

- The **pre-Harness column** of the source flow diagram — code scanning, developer branches, the
  external promotion and chart-publish jobs. This flow starts where Harness starts: someone has a
  deployment ticket and a set of services.
- The **artifact-repository "charts exist" pre-check**, dropped on request.
- **Adjacency** is modelled as "the declared set is closed at one version". There is no real service
  dependency graph behind it.
- Two services, not twenty-six. Each new one needs a service entity, three GitOps applications, three
  manifests, and one entry in each of the three `services.values` lists in the input set.
