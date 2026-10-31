{{/*
_helpers.tpl - named templates shared by every file in templates/.
Files whose names begin with an underscore never produce objects.
Every name starts with "task-tracker." because named templates are global.
*/}}

{{/* task-tracker.name: the chart name, or nameOverride. */}}
{{- define "task-tracker.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
task-tracker.fullname: the base name of every object, limited to 63 characters.
A release called "task-tracker" gives "task-tracker", not "task-tracker-task-tracker".
*/}}
{{- define "task-tracker.fullname" -}}
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

{{/* task-tracker.chart: "<name>-<version>" for the helm.sh/chart label. */}}
{{- define "task-tracker.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* task-tracker.environment: stops rendering when no environment is chosen. */}}
{{- define "task-tracker.environment" -}}
{{- required "environment must be set to dev or prod (use -f environments/<env>.yaml)" .Values.environment }}
{{- end }}

{{/* Object names for each tier. Used by the objects AND by the ConfigMap. */}}
{{- define "task-tracker.dbName" -}}
{{- printf "%s-db" (include "task-tracker.fullname" .) }}
{{- end }}
{{- define "task-tracker.backendName" -}}
{{- printf "%s-backend" (include "task-tracker.fullname" .) }}
{{- end }}
{{- define "task-tracker.frontendName" -}}
{{- printf "%s-frontend" (include "task-tracker.fullname" .) }}
{{- end }}

{{/* task-tracker.secretName: the chart's own Secret, or an existing one. */}}
{{- define "task-tracker.secretName" -}}
{{- if .Values.credentials.existingSecret }}
{{- .Values.credentials.existingSecret }}
{{- else }}
{{- printf "%s-secret" (include "task-tracker.fullname" .) }}
{{- end }}
{{- end }}

{{/*
task-tracker.image: "<repository>:<tag>". Called with (dict "ctx" $ "image" .Values.<tier>.image).
Tag order: per-tier tag, then image.tag, then appVersion.
*/}}
{{- define "task-tracker.image" -}}
{{- $tag := .image.tag | default .ctx.Values.image.tag | default .ctx.Chart.AppVersion }}
{{- printf "%s:%s" .image.repository $tag }}
{{- end }}

{{/*
task-tracker.selectorLabels: the small, stable set that selectors use.
Called with (dict "ctx" $ "tier" "backend"). Never changes after install,
because Deployment.spec.selector is immutable.
*/}}
{{- define "task-tracker.selectorLabels" -}}
app.kubernetes.io/name: {{ include "task-tracker.name" .ctx }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
tier: {{ .tier }}
{{- end }}

{{/* task-tracker.labels: the full label set for an object of one tier. */}}
{{- define "task-tracker.labels" -}}
helm.sh/chart: {{ include "task-tracker.chart" .ctx }}
{{ include "task-tracker.selectorLabels" . }}
app.kubernetes.io/component: {{ .tier }}
app.kubernetes.io/part-of: task-tracker
app.kubernetes.io/version: {{ .ctx.Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .ctx.Release.Service }}
app.kubernetes.io/environment: {{ include "task-tracker.environment" .ctx | quote }}
{{- end }}

{{/* task-tracker.commonLabels: labels for objects that belong to no tier. */}}
{{- define "task-tracker.commonLabels" -}}
helm.sh/chart: {{ include "task-tracker.chart" . }}
app.kubernetes.io/name: {{ include "task-tracker.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: task-tracker
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/environment: {{ include "task-tracker.environment" . | quote }}
{{- end }}
