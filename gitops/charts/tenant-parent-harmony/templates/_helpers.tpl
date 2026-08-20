{{/*
Image tag for a service, read out of the raw values/_tenants/<tenant>/<svc>-tenant.yaml
that the ApplicationSet injected via helm.fileParameters.

Fail loudly for the service that owns the migration (a wrong tag there migrates
the wrong schema). Other services return "" and are simply left unpinned, so one
missing tenant file cannot stop the whole tenant from deploying — board D16.
*/}}
{{- define "tp.tag" -}}
{{- $raw := index .root.Values.tenantFiles .key | default "" -}}
{{- $tag := "" -}}
{{- if $raw -}}
{{- $tag = (($raw | fromYaml).image | default dict).tag | default "" -}}
{{- end -}}
{{- if and (not $tag) .required -}}
{{- fail (printf "tenant-parent: tenantFiles.%s has no image.tag (tenant=%s region=%s)" .key .root.Values.tenant .root.Values.region.shortName) -}}
{{- end -}}
{{- $tag -}}
{{- end -}}

{{/* <appName>-<tenant>-<region>, matching every Application name in harmony today. */}}
{{- define "tp.childName" -}}
{{- printf "%s-%s-%s" .cfg.appName .root.Values.tenant .root.Values.region.shortName -}}
{{- end -}}

{{/*
Explicit boolean test. `$x | default true` swallows an intentional false
(Sprig treats false as empty), which silently disables every escape hatch — board D7.
*/}}
{{- define "tp.enabled" -}}
{{- if hasKey .cfg "enabled" -}}{{- .cfg.enabled -}}{{- else -}}true{{- end -}}
{{- end -}}

{{/* Standard harmony labels; `tenant` is the short client code, never <client>-<env>. */}}
{{- define "tp.labels" -}}
app: {{ .cfg.appName }}
tenant: {{ .root.Values.client | quote }}
env: {{ .root.Values.env | quote }}
region: {{ .root.Values.region.shortName | quote }}
{{- end -}}

{{/*
Does the shared-DB migration run in this region?
Only where traffic is active AND the database is the writer. `databaseRole` is
metadata a human flips after the Aurora failover, so gating on it stops a
standby→active commit that lands early from migrating a read replica — board D10.
*/}}
{{- define "tp.migrationsActive" -}}
{{- $m := .Values.migrations | default dict -}}
{{- $on := true -}}{{- if hasKey $m "enabled" -}}{{- $on = $m.enabled -}}{{- end -}}
{{- if and $on (eq (.Values.region.role | default "active") "active") (eq (.Values.region.databaseRole | default "primary") "primary") -}}
true
{{- end -}}
{{- end -}}
