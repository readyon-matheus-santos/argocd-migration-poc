{{- define "fake-service.name" -}}
{{- required "name is required (set in gitops/values/_base/<svc>.yaml)" .Values.name -}}
{{- end -}}

{{- define "fake-service.labels" -}}
app.kubernetes.io/name: {{ include "fake-service.name" . }}
version: {{ .Values.version | quote }}
release-id: {{ .Values.releaseId | quote }}
{{- end -}}

{{- define "fake-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "fake-service.name" . }}
{{- end -}}
