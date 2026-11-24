{{/* Component names, derived from the release. */}}
{{- define "quickstart.atryum" -}}{{ .Release.Name }}-atryum{{- end -}}
{{- define "quickstart.postgres" -}}{{ .Release.Name }}-postgres{{- end -}}
{{- define "quickstart.demo" -}}{{ .Release.Name }}-demos{{- end -}}
{{- define "quickstart.gateway" -}}{{ .Release.Name }}-mcp{{- end -}}

{{/* Gateway mode uses the verified demo client and its bundled Python environment. */}}
{{- define "quickstart.demoImage" -}}
{{- $digest := .Values.demo.image.digest -}}
{{- if and .Values.mcpGateway.enabled (not $digest) (eq .Values.demo.image.repository "validmind/atryum-finance-demo") (eq .Values.demo.image.tag "latest") -}}
{{- $digest = "sha256:13fa226e82619813f31ae952475d1792cb087745603bd2cded8aae7fad0de6d0" -}}
{{- end -}}
{{- if $digest -}}
{{- printf "%s@%s" .Values.demo.image.repository $digest -}}
{{- else -}}
{{- printf "%s:%s" .Values.demo.image.repository .Values.demo.image.tag -}}
{{- end -}}
{{- end -}}

{{- define "quickstart.gatewayHost" -}}
{{- printf "%s-%s.%s.svc.cluster.local" (include "quickstart.gateway" .) .Values.mcpGateway.gatewayClassName .Release.Namespace -}}
{{- end -}}

{{/* Common labels */}}
{{- define "quickstart.labels" -}}
app.kubernetes.io/part-of: approve-agent-tools-with-atryum
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Model endpoint, normalized: no trailing slash and no trailing /v1 (Atryum's
judge and the chart's model-access test both append /v1/... themselves).
Empty when using OpenAI directly.
*/}}
{{- define "quickstart.modelEndpoint" -}}
{{- .Values.model.endpoint | trimSuffix "/" | trimSuffix "/v1" | trimSuffix "/" -}}
{{- end -}}

{{/* Judge provider: explicit override, else derived from the endpoint. */}}
{{- define "quickstart.modelProvider" -}}
{{- if .Values.model.provider -}}
{{- .Values.model.provider -}}
{{- else if (include "quickstart.modelEndpoint" .) -}}
openai_compatible
{{- else -}}
openai
{{- end -}}
{{- end -}}

{{/*
Postgres password: reuse the existing secret's value across upgrades so the
database keeps working; generate a fresh one on first install unless pinned
via .Values.postgres.password.

The generated value is memoized in .Values for the duration of the render —
randAlphaNum returns a DIFFERENT value on every call, and this helper is
included from both the postgres Secret and Atryum's config; without the memo
the two get different passwords and Atryum can never authenticate.
*/}}
{{- define "quickstart.postgresPassword" -}}
{{- if .Values.postgres.password -}}
{{- .Values.postgres.password -}}
{{- else -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace (include "quickstart.postgres" .) -}}
{{- if and $existing $existing.data (hasKey $existing.data "database-password") -}}
{{- index $existing.data "database-password" | b64dec -}}
{{- else -}}
{{- $gen := get .Values "_generatedPostgresPassword" | default (randAlphaNum 24) -}}
{{- $_ := set .Values "_generatedPostgresPassword" $gen -}}
{{- $gen -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Route host for a component ("" lets OpenShift assign one). */}}
{{- define "quickstart.atryumHost" -}}
{{- if .Values.atryum.route.host -}}
{{- .Values.atryum.route.host -}}
{{- else if .Values.clusterDomain -}}
{{- printf "%s-%s.%s" (include "quickstart.atryum" .) .Release.Namespace .Values.clusterDomain -}}
{{- end -}}
{{- end -}}

{{- define "quickstart.demoHost" -}}
{{- if .Values.demo.route.host -}}
{{- .Values.demo.route.host -}}
{{- else if .Values.clusterDomain -}}
{{- printf "%s-%s.%s" (include "quickstart.demo" .) .Release.Namespace .Values.clusterDomain -}}
{{- end -}}
{{- end -}}

{{/* Atryum's public base URL: explicit value > computed route host > in-cluster service. */}}
{{- define "quickstart.atryumPublicURL" -}}
{{- if .Values.atryum.publicBaseUrl -}}
{{- .Values.atryum.publicBaseUrl -}}
{{- else if (include "quickstart.atryumHost" .) -}}
{{- printf "https://%s" (include "quickstart.atryumHost" .) -}}
{{- else -}}
{{- printf "http://%s:8080" (include "quickstart.atryum" .) -}}
{{- end -}}
{{- end -}}
