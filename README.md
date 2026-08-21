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
  └─ tenant-<tenant>            the parent, one per tenant
       ├─ PreSync ─► tenant-migrations-<tenant>       an Application, destination = workload cluster
       │                └─ the migration Jobs (plain resources, hook waves for same-DB order)
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
| `make status` | remote revision, every Application, per-tenant pods and marker |
| `make lint` | helm lint, `bash -n`, shellcheck if present, token/URL guards |
| `make teardown` / `make clean` | delete the kind cluster / also `.cache/` and `runs/` |

ArgoCD UI: `kubectl --kubeconfig .cache/kubeconfig -n argocd port-forward svc/argocd-server 8443:443`
(`admin` / `argocd-initial-admin-secret`).

Only the scenario driver may commit during a run — any other push changes the
revision every app sees.

## Scenarios and observed results

Times are relative to the release commit push, ArgoCD v3.4.5 on kind, 2 s sampling.
Each scenario converges its own profile first, so they can run in any order.

### The design — app-of-apps, migrations as the parent's PreSync (`layout: appofapps`)

| # | Run | What it proves | Observed |
|---|---|---|---|
| 10a | `make prepare-10a` then `make scenario-10a` | success path, watchable: tag bump in the tenant files → parent hooks → children roll | last hook +89 s → first v2 pod +92 s → Ready +95 s |
| 10 | `make scenario-10` / `make assert-10` | full journey: release, failed migration, revert | child stayed Synced/Healthy through the whole hook run; failed migration ⇒ parent `Failed` +384 s, no v3 pod ever created, v2 served 447 s; revert applied +8 s with no hook re-run |

### Baseline — harmony today (`layout: appsets`)

| # | What it asks | Observed |
|---|---|---|
| 1 | does today's shape keep new code from serving while another service migrates? | no — backend v2 Ready **+9 s** while subgraph-a's migration ran to +131 s |
| 2 | is a separate migrations app at wave 0 enough? | no — all v2 pods Ready **+12 s**, migrations app still running until +140 s (app-level waves are decorative across generated apps) |

### Comparison — migrations layer + runtime gate (`layout: appsets`, rejected in favour of the design)

| # | What it asks | Observed |
|---|---|---|
| 3 / 3a | success path, failed migration, revert | no v2 pod Ready before the marker (+84 s ≤ +86 s); failure: marker unchanged, v3 never Ready, v2 served, revert 36 s |
| 4 | same-DB hook-wave serialization | subgraph-a started 6.5 s after backend finished; own-DB job overlapped 20 s |
| 5 | does the gate block scale-out / restarts? | no — 3 replicas Ready +11 s after the commit |
| 6 | gate timeout shorter than the migration | init crash-loops, apps Degraded, v1 serves, self-completes +138 s |
| 7 | release superseded mid-migration | in-flight sync not preempted; r72 landed +201 s; no unsafe pod |
| 8 | backend-only release | subgraphs still roll + gate; 60 s |
| 9 | rollback pointer with a completed-set marker | stable pods Ready +19 s, before hooks re-ran |

Things worth knowing that came out of the runs:

- ArgoCD automated syncs retry **5× by default** even with no `retry` block;
  every retry re-creates all PreSync hooks (`BeforeHookCreation`), so hook
  Jobs must be idempotent and a failed release reaches terminal `Failed` after
  ~6 min.
- `kubectl scale` on an automated+selfHeal app is reverted within seconds —
  scale through git or an HPA.
- A new commit does not preempt an in-flight sync operation.
- Pruning a parent Application cascade-deletes its children (finalizer) —
  relevant for any cutover between layouts (and for the AppSet → parent cutover).
- `helm.fileParameters` accepts `$values/...` refs (multi-source) on 3.4.5,
  and inline `helm.values` take precedence over `valueFiles`.
- A custom `Application` health check must treat `Synced + Healthy` as
  Healthy even when the last operation failed, or a parent stalls after a
  revert whose manifests are unchanged.

## Layout of the repo

```
bootstrap/   cluster/ArgoCD install, repo secret, root app template, status/teardown
gitops/      what ArgoCD reads: root chart + AppSets, charts, values, tenants.yaml
  charts/tenant-parent/          the working demo (fake services, runs in the lab)
  charts/tenant-parent-harmony/  the deliverable: the chart + ApplicationSet as they
                                 would ship to harmony, with the real per-service
                                 values copied in (AWS account ids redacted)
scripts/     run.sh (driver), assert.sh, seed.sh, lint.sh, lib/ (env, kube, git, release, sampler)
runs/        evidence per scenario (gitignored)
```
