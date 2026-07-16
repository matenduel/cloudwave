{{/*
릴리스마다 리소스 이름이 겹치지 않도록 "릴리스이름-차트이름" 형태의 이름을 만듭니다.
예: helm install demo ./webapp → demo-webapp
*/}}
{{- define "webapp.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Service와 Deployment가 같은 파드를 가리키게 하는 셀렉터 라벨 묶음입니다.
*/}}
{{- define "webapp.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
셀렉터 외에 붙이는 공통 라벨(관리 도구 표시 등)입니다.
*/}}
{{- define "webapp.labels" -}}
{{ include "webapp.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}
