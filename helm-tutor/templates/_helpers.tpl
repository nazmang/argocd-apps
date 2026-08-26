{{- define "tutor.imagePullSecrets" -}}
imagePullSecrets:
  - name: ghcr-tutor
{{- end -}}

{{- define "tutor.securityContext" -}}
runAsNonRoot: true
runAsUser: 1000  # kubelet не резолвит именованный USER tutor из образа — только числовой uid
readOnlyRootFilesystem: true
allowPrivilegeEscalation: false
capabilities:
  drop: [ALL]
seccompProfile:
  type: RuntimeDefault
{{- end -}}
