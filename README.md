# ArgoCD tenant-release lab

A self-contained local lab (kind + ArgoCD v3.4.5) that reproduces harmony's
ApplicationSet topology in miniature and runs scripted, asserted scenarios
for the "all of a tenant's migrations before any service of that release
serves" problem. It was used to validate the design in the TRD
*Tenant release app-of-apps — migrations as PreSync of the parent*.

The lab repo is itself the ArgoCD source: everything ArgoCD reads lives under
`gitops/` on `main`, and every scenario release is a real commit pushed to it.

## Model — two clusters, like harmony

```
CONTROL cluster (kind: argocd-migration-poc)          ~ harmony-platform-use2
  ArgoCD + every Application object
  └─ tenant-<tenant>            the parent, one per tenant (chart: tenant-parent, renders ONLY Applications)
       ├─ PreSync ─► tenant-migrations-<tenant>       an Application, destination = workload cluster
       │                source = the tenant-migrations chart: one Job per migrating service,
       │                plain resources named per release, sync-waves serialize same-DB services
       └─ Sync ────► backend-<tenant> (wave 2), subgraph-a/-b-<tenant> (wave 4)

WORKLOAD cluster (kind: ...-workload)                 ~ harmony-nonprod-use2
  tenant namespaces: postgres + the service pods. No ArgoCD, no Application CRD.
  Registered with ArgoCD as a remote cluster, exactly as harmony registers nonprod.
```

Two tenants (`acme`, `globex`), three fake services each — `backend` and
`subgraph-a` share DB `main`, `subgraph-b` owns `subgraph_b`. Migration Jobs are
`psql` scripts that write a ledger row, sleep a configurable time and can be made
to fail. Releases are real commits: the driver stamps versions into the tenant
value files and pushes.

Why the migration is an *Application* and not a Job hook of the parent: an
Application has exactly one `spec.destination` and every resource it renders —
hooks included — lands there. The parent must live where Application CRs exist
(the control cluster), so a Job hook would run there, away from the tenant's
database. Measured here: a PreSync Job with an explicit tenant namespace ran on
the control cluster even though the same namespace existed on the workload
cluster. ArgoCD has no per-resource destination (argo-cd#8944 is still open).

Why the migration Jobs are *plain resources* of that Application and not hooks
inside it: hooks are excluded from the sync comparison and from app health, so
an app containing only hooks manages nothing — it reports Synced/Healthy on
creation, never syncs, and the Jobs never run while the parent reports success.
As plain resources they are the app's state, so ArgoCD's built-in Job health
gates the parent: Progressing → Healthy, or Degraded on failure.

## Requirements

Any Docker-compatible engine for kind (Docker Desktop, OrbStack, Rancher
Desktop, colima — ~8 GiB for the engine is comfortable), and `kind`,
`kubectl`, `helm`, `git`, `gh` (>= 2.40) on `PATH`. Works on amd64 and
arm64 — all images are pinned multi-arch (`bootstrap/versions.env`).

One-time: fork/create a GitHub repo you can push to (ArgoCD reads it and the
scenario driver pushes release commits to it), set it as `origin` of this
checkout, push `main`. Then:

```
make bootstrap      # preflight → kind cluster → ArgoCD → repo Secret → root app → seed
```

Configuration (env or a gitignored `.env`): `REPO_URL` (default
`https://github.com/readyon-matheus-santos/argocd-migration-poc.git`), `GITHUB_LOGIN`
(default: the active `gh` login), `GIT_BRANCH` (`main`). The ArgoCD repository
Secret is created by piping `gh auth token` straight into `kubectl` — the
token never touches disk.

The lab only ever uses its own kubeconfig (`.cache/kubeconfig`); your default
kubeconfig is never read or written.

## Targets

| Target | What |
|---|---|
| `make bootstrap` | create the control cluster, install ArgoCD, repo Secret, root app-of-apps, seed |
| `make workload-cluster` | create + register the workload cluster. Re-run after a Docker restart: kind containers get new IPs and the registered endpoint goes stale |
| `make seed` | default profile at `r0`; smoke test of the whole stack |
| `make scenario-N` / `make assert-N` | run one scenario (self-contained from any prior state) / judge its evidence in `runs/sN/` |
| `make prepare-N` | converge a scenario's baseline without firing the release (for watching it live) |
| `make status` | remote revision, every Application, per-tenant pods |
| `make lint` | helm lint, `bash -n`, shellcheck if present, token/URL guards |
| `make teardown` / `make clean` | delete the kind cluster / also `.cache/` and `runs/` |

ArgoCD UI: `kubectl --kubeconfig .cache/kubeconfig -n argocd port-forward svc/argocd-server 8443:443`
(`admin` / `argocd-initial-admin-secret`).

Only the scenario driver may commit during a run — any other push changes the
revision every app sees.

## Scenarios

Times are relative to the release commit push, measured on the two-cluster lab.
Each scenario converges its own profile first, so they can run in any order.

| # | Run | What it shows | Observed |
|---|---|---|---|
| 1 | `make scenario-1` / `make assert-1` | **the problem** — harmony today (`layout: appsets`, per-service AppSets each running their own migration) | new code Ready **+9 s** while another service's migration ran on for ~2 min |
| 10a | `make prepare-10a` then `make scenario-10a` | **the design, success path** — watchable: tag bump → parent's hook Application → migrations → children | migrations done 20:30:45, first service pod 20:30:47, subgraphs 20:30:52 |
| 10 | `make scenario-10` / `make assert-10` | **the design, full journey** — release, failed migration, revert | failed migration ⇒ hook app Degraded, parent PreSync Failed, **no new pod ever created**, previous version served throughout; revert converges |

The rejected alternatives that earlier versions of this lab also ran (a wave-0
migrations app; a `migrations-complete` marker plus a `release-gate` init
container) have been removed along with their charts — their evidence lives in
the board review, and keeping unrunnable scenarios around was worse than
deleting them.

## What the runs established

- A PreSync **Job** of the parent runs on the *parent's* cluster, not the
  tenant's — measured with the same namespace present on both clusters. ArgoCD
  has no per-resource destination (argo-cd#8944), so the migration must travel
  inside an Application.
- Inside that Application the migration Jobs must be **plain resources, not
  hooks**: an app containing only hooks manages nothing, reports Synced/Healthy
  on creation and never runs them, while the parent reports success.
- A custom `Application` health check is required, and must treat
  `Synced + Healthy` as Healthy even when the last operation failed — otherwise a
  parent stalls after a revert whose manifests are unchanged.
- ArgoCD does not preempt an in-flight sync: a wedged parent needs
  `argocd app terminate-op`; pushing a new commit does nothing.
- `kubectl scale` on an automated+selfHeal app is reverted within seconds —
  scale through git or an HPA.
- `helm.fileParameters` accepts `$values/...` refs, and `helm.parameters`
  (`--set`) outranks both inline values and `valueFiles`.

## Layout of the repo

```
bootstrap/   cluster/ArgoCD install, repo secret, root app template, status/teardown
gitops/      what ArgoCD reads: root chart + AppSets, charts, values, tenants.yaml
  charts/tenant-parent/          the working demo: parent chart, renders the hook Application + children
  charts/tenant-migrations/      what the hook Application deploys: the tenant's migration Jobs
  charts/fake-service/           the stand-in service (Deployment + optional per-app hook Job, S1 baseline)

The production charts that came out of this lab live in readyon-harmony-charts
(`charts/tenant-parent`, `charts/tenant-migrations`) and are consumed by
readyon-harmony's `applicationsets/<env>/tenant-parent.yaml`; they are not
mirrored here.
scripts/     run.sh (driver), assert.sh, seed.sh, lint.sh, lib/ (env, kube, git, release, sampler)
runs/        evidence per scenario (gitignored)
```
