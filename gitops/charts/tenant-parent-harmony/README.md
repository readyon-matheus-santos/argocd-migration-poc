# tenant-parent-harmony

What ships to `readyon-harmony` / `readyon-harmony-charts` for the app-of-apps
solution, written against harmony's real shapes rather than the lab's fake
services. Published as `readyon-helm-charts/tenant-parent`; consumed by
`applicationsets/<env>/tenant-parent.yaml` (see `applicationset-prod.yaml`).

Not wired into this lab's `gitops/root` — the lab exercises the *mechanism* with
fake services; this folder is the deliverable.

## What it renders

```
tenant-<tenant>-<region>            Application, destination: platform cluster / argocd
│                                   (renders Application objects and nothing else)
│
├─ PreSync ──► Application  tenant-migrations-backend-<tenant>-<region>     one per schema owner
│                 destination: <tenant cluster> / <tenant namespace>
│                 source: readyon-helm-charts/backend — the SAME chart, valueFiles and inline
│                         values as the backend child, plus migrationsOnly=true and the tag pin
│                 └─ Job  backend-migrations-<hash>   (plain resource, named per release)
│                    ExternalSecret backend-migrations-db-secrets
│
└─ Sync ─────► child Applications, destination: <tenant cluster> / <tenant namespace>
                  wave 2  backend, backend-crons
                  wave 3  notifications-orchestrator
                  wave 4  the six `main` subgraphs, monitoring-cronjobs
                  wave 5  apollo-router
```

A release is unchanged: the bot bumps `image.tag` in
`values/_tenants/<tenant>/*-tenant.yaml`. The children do **not** move on that
commit — their tag is pinned by the parent via `helm.parameters`, which outranks
`valueFiles`. The parent does move, runs the migration, then re-pins the
children. That is the whole ordering guarantee.

## The migration Job stays in the service's own chart

The hook Application does not carry a Job template of its own. It points at the
migrating service's chart (`readyon-helm-charts/backend`) with the exact value
layers the backend child uses, and sets `migrationsOnly=true` — a switch in the
backend chart (readyon-harmony-charts, 1.11.0) that renders only the migration
Job and its ExternalSecret, with the Job as a plain resource named per release
instead of a PreSync hook. One Job template, owned by the service that owns the
schema; a migration-only change (A7 TLS env, backoffLimit) lands the moment the
tenant's value layer changes, because it changes the hash in the Job name.

Why not a wrapper chart with backend as a dependency: harmony's value layers are
four `$values/...` files at the top level of backend's values, and ArgoCD cannot
nest a `valueFiles` entry under a subchart key — so a wrapper would need its own
copy of every value. Pointing the hook at the service chart keeps the layering
byte-identical to the child's.

A second schema owner (an own-DB subgraph joining the parent) is one more entry
in `migrations.services`; same-database services get a later `wave`.

## Two things that are not optional

**1. The migration must be an Application, not a Job.**
Hook resources are resources of the Application, and every resource lands on its
single `spec.destination`. The parent has to live where Application CRs exist —
the platform cluster — so a Job hook runs *there*: no tenant database, no tenant
secrets, wrong AWS account. Proven in this lab: a PreSync Job with an explicit
tenant namespace ran on the parent's cluster even though the same namespace
existed on the workload cluster. ArgoCD has no per-resource destination
(argo-cd#8944 is still an open feature request), so only an Application — which
carries its own destination — reaches the tenant.

**2. The migration Job must be a plain resource of the hook Application, not a hook inside it.**
(`migrationsOnly=true` in the service chart is what makes it one.)
Hooks are excluded from the sync comparison and from app health, so an
Application whose contents are all hooks manages nothing: ArgoCD reports it
Synced/Healthy on creation, never runs a sync, the Job never fires, and the
parent's PreSync "succeeds" with nothing migrated. Measured here — children
rolled, `migration_log` untouched, every Application green. As a plain resource
the Job *is* the app's managed state, so ArgoCD's built-in Job health does the
gating: Progressing while migrating, Healthy on success, Degraded on failure.
Measured: hook app Progressing → Degraded on a failed migration, zero new pods
throughout, parent PreSync `Failed`. A Job spec is immutable, so the name carries
a hash of everything that shapes the spec — every change is a create, never an
in-place mutation. (`Replace=true` was tried first and fails: the API server adds
`spec.selector` at create time and both it and the template are immutable.)

**3. The `argocd-cm` Application health customization.**
Without it an `Application` used as a hook has no health check, ArgoCD treats it
as instantly succeeded, and the children roll un-migrated — silently. It must
also return Healthy for a `Synced + Healthy` app whose *last operation* failed,
or a parent stalls forever after a revert. Scope it by label so it stays a no-op
for the four existing app-of-apps roots — 17 of their 148 children are not
Synced+Healthy at any given moment, several at wave −1, and gating them would
stall nonprod, platform and prod deployment roots on the first sync.

## Decisions already folded in

| | |
|---|---|
| No `resources-finalizer` on children | with `prune: true`, a child that stops rendering would otherwise cascade-delete live workload |
| No `resources-finalizer` on the parent template | an explicit finalizer survives `preserveResourcesOnDeletion`, making un-flag a cascading delete |
| No finalizer on the hook Application | it is deleted and recreated on each parent sync; a finalizer would cascade into the running Job |
| `image.tag` via `helm.parameters` | `--set` outranks inline values and `valueFiles`, so only the parent moves a child |
| Hook gated on `role == active` **and** `databaseRole == primary` | a standby→active commit that lands before the Aurora failover would otherwise migrate a read replica |
| `retryLimit: 0` on the hook app, `retry.limit: 3` on the parent | one parent retry = exactly one fresh migration attempt, instead of retries multiplying |
| Explicit `hasKey` boolean tests | `x \| default true` swallows `false`, which silently disables every `enabled: false` escape hatch |
| Fail-loud only on the migrating service's tag | a missing tenant file for another service must not stop the whole tenant deploying |
| Job as a plain resource, name hashed from its spec | no marker ConfigMap needed; migration-only edits (A7 TLS toggles, backoffLimit) produce a new Job name, so they run immediately instead of wedging on an immutable field |
| Hook points at the service chart (`migrationsOnly`), not a copy of its Job | one Job template, owned by the schema owner; value layering byte-identical to the child |
| The other `main` readers included | `backend-crons`, `notifications-orchestrator`, `monitoring-cronjobs` read `main_<env>` today; leaving them out breaks the stated guarantee |

## What is in this folder

| File | What |
|---|---|
| `applicationset-prod.yaml` | the real `applicationsets/prod/tenant-parent.yaml`. Every child's `valueFiles` and inline `values` are copied **verbatim** from that service's current ApplicationSet at `origin/main` |
| `ci/armk-prod-use2-values.yaml` | the same content with the generator's vars resolved for armk-prod/use2, so the chart can be rendered and diffed |
| `ci/rendered-armk-prod-use2.yaml` | the rendered output: 11 child Applications + the migration hook, ready to diff against the live apps |
| `templates/`, `values.yaml` | the chart itself |

**Redaction.** This repo is public, so AWS account IDs are replaced with
`<PLATFORM_ACCOUNT_ID>` / `<PROD_ACCOUNT_ID>` / `<NONPROD_ACCOUNT_ID>` (30
occurrences). Nothing else was altered — no credentials appear in harmony's
ApplicationSets in the first place (secrets come from ExternalSecrets at runtime).
Restore them with a `sed` before using any of this in harmony.

## Rendering it

```bash
helm lint  gitops/charts/tenant-parent-harmony -f ci/armk-prod-use2-values.yaml
helm template t gitops/charts/tenant-parent-harmony -f ci/armk-prod-use2-values.yaml          # 11 children + the hook app
helm template t gitops/charts/tenant-parent-harmony -f ci/armk-prod-use2-values.yaml \
  --set region.role=standby | grep -c tenant-migrations    # → 0, no migration in the DR region
```

Before this is trusted in harmony, the rendered children must be diffed
byte-for-byte against the live Applications the per-service ApplicationSets
generate today; the only differences may be the `image.tag` parameter and
`migrations.enabled=false` on backend.

## Still to settle

- `apollo-router` as a child (wave 5, keeps "router after subgraphs") or left in
  its own ApplicationSet.
- The cutover itself: harmony's 8 live Applications per tenant each carry
  `resources-finalizer` today, so the hand-over — not this chart — is where the
  outage risk lives.
