{{/*
Nombre base — usa el Release.Name como identificador.
*/}}
{{- define "pythonapps.fullname" -}}
{{- .Release.Name }}
{{- end }}

{{/*
Labels estándar aplicados a todos los recursos.
*/}}
{{- define "pythonapps.labels" -}}
app.kubernetes.io/name: {{ .Release.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{/*
Selector labels — usado en matchLabels y spec.selector.
*/}}
{{- define "pythonapps.selectorLabels" -}}
app.kubernetes.io/name: {{ .Release.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
