{{- define "voice.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- define "voice.labels" -}}
helm.sh/chart: {{ include "voice.chart" .root }}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/part-of: voice
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
{{- end }}
{{- define "voice.selectorLabels" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
{{- end }}
{{- define "voice.aliases" -}}
{{- $out := list }}{{- range $k, $v := . }}{{- $out = append $out (printf "%s:%s" $k $v) }}{{- end }}{{- join "," $out }}
{{- end }}
