# tenant-parent-harmony

What ships to `readyon-harmony` / `readyon-harmony-charts` for the app-of-apps
solution, written against harmony's real shapes rather than the lab's fake
services. Published as `readyon-helm-charts/tenant-parent`; consumed by
`applicationsets/<env>/tenant-parent.yaml` (see `applicationset-example.yaml`).

Not wired into this lab's `gitops/root` — the lab exercises the *mechanism* with
fake services; this folder is the deliverable.

## What it renders

```
tenant-<tenant>-<region>            Application, destination: platform cluster / argocd
│
├─ PreSync ──► Application  tenant-migrations-<tenant>-<region>
│                 destination: <tenant cluster> / <tenant namespace>
│                 └─ same chart, mode=migrations:
│                      Job  backend-migrations        (PreSync hook)
│                      CM   backend-migration-state   (the non-hook resource)
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

## One chart, two roles

`mode: parent` renders the hook Application and the children; `mode: migrations`
renders the Job and the state ConfigMap. The hook Application points back at
this same chart with `mode=migrations`.

Two roles rather than two charts, so there is no second copy of backend's
migration Job template to keep in sync. The alternative — point the hook at
`charts/backend` with a new `migrationsOnly` flag — is equally valid and avoids
even this copy; it needs a state ConfigMap adding to that chart. Open decision.

## Three things that are not optional

**1. The migration must be an Application, not a Job.**
Hook resources are resources of the Application, and every resource lands on its
single `spec.destination`. The parent has to live where Application CRs exist —
the platform cluster — so a Job hook runs *there*: no tenant database, no tenant
secrets, wrong AWS account. Proven in this lab: a PreSync Job with an explicit
tenant namespace ran on the parent's cluster even though the same namespace
existed on the workload cluster. ArgoCD has no per-resource destination
(argo-cd#8944 is still an open feature request), so only an Application — which
carries its own destination — reaches the tenant.

**2. The state ConfigMap.**
An Application whose content is only hooks manages nothing, so ArgoCD reports it
`Synced/Healthy` on creation and never runs a sync: the Job never fires, and the
parent's PreSync "succeeds" with nothing migrated. Demonstrated here — children
rolled, `migration_log` untouched, every Application green. The ConfigMap also
makes a *failed* migration visible: app health is computed over non-hook
resources, so with the ConfigMap unapplied the app is not Synced and the health
customization returns Degraded, failing the parent's PreSync.

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
| No finalizer on the hook Application | `BeforeHookCreation` deletes it every sync; a finalizer would cascade into the running Job |
| `image.tag` via `helm.parameters` | `--set` outranks inline values and `valueFiles`, so only the parent moves a child |
| Hook gated on `role == active` **and** `databaseRole == primary` | a standby→active commit that lands before the Aurora failover would otherwise migrate a read replica |
| `retryLimit: 0` on the hook app, `retry.limit: 3` on the parent | one parent retry = exactly one fresh migration attempt, instead of retries multiplying |
| Explicit `hasKey` boolean tests | `x \| default true` swallows `false`, which silently disables every `enabled: false` escape hatch |
| Fail-loud only on the migrating service's tag | a missing tenant file for another service must not stop the whole tenant deploying |
| `migrationsHash` in the state ConfigMap | migration-only edits (A7 TLS toggles, backoffLimit) would otherwise take effect only at the next tag bump |
| The other `main` readers included | `backend-crons`, `notifications-orchestrator`, `monitoring-cronjobs` read `main_<env>` today; leaving them out breaks the stated guarantee |

## Rendering it

```bash
helm lint  gitops/charts/tenant-parent-harmony --set mode=parent
helm template t gitops/charts/tenant-parent-harmony -f ci/armk-prod-use2-values.yaml          # the parent role
helm template t gitops/charts/tenant-parent-harmony -f ci/armk-prod-use2-values.yaml \
  --set mode=migrations --set migrations.job.image=<tag>                                       # what lands on the tenant
helm template t gitops/charts/tenant-parent-harmony -f ci/armk-prod-use2-values.yaml \
  --set region.role=standby | grep -c tenant-migrations    # → 0, no migration in the DR region
```

Before this is trusted in harmony, the rendered children must be diffed
byte-for-byte against the live Applications the per-service ApplicationSets
generate today; the only differences may be the `image.tag` parameter and
`migrations.enabled=false` on backend.

## Still to settle

- Point the hook at this chart (`mode=migrations`) or at `charts/backend` with a
  `migrationsOnly` flag.
- `apollo-router` as a child (wave 5, keeps "router after subgraphs") or left in
  its own ApplicationSet.
- The cutover itself: harmony's 8 live Applications per tenant each carry
  `resources-finalizer` today, so the hand-over — not this chart — is where the
  outage risk lives.
