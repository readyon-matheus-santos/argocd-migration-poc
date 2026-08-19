{{- define "tp.svc" -}}
{{- /* returns parsed tenant file for a service as YAML dict */ -}}
{{- $raw := index .Values.tenantFiles .svc | default "" -}}
{{- $raw | fromYaml | toJson -}}
{{- end -}}
