{{- define "legacy-web.name" -}}{{ .Release.Name }}-{{ .Chart.Name }}{{- end -}}
{{- define "legacy-web.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end -}}
{{- define "legacy-web.selector" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
{{- define "legacy-web.sa" -}}
{{- if .Values.serviceAccount.create }}{{ default (include "legacy-web.name" .) .Values.serviceAccount.name }}{{ else }}{{ default "default" .Values.serviceAccount.name }}{{ end -}}
{{- end -}}
{{- define "legacy-web.secretName" -}}
{{ default (include "legacy-web.name" .) .Values.secret.existingSecret }}
{{- end -}}
