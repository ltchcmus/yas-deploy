{{/*
Chart name
*/}}
{{- define "yas.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fullname
*/}}
{{- define "yas.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "yas.labels" -}}
helm.sh/chart: {{ include "yas.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels for a specific service
*/}}
{{- define "yas.selectorLabels" -}}
app: {{ . }}
{{- end }}

{{/*
Image name for a service
Usage: {{ include "yas.imageName" (dict "global" .Values.global "name" $name "svc" $svc) }}
*/}}
{{- define "yas.imageName" -}}
{{- if .svc.image -}}
{{ .svc.image }}:{{ .svc.tag }}
{{- else -}}
{{ .global.registry }}/yas-{{ .name }}:{{ .svc.tag }}
{{- end -}}
{{- end }}
