# ROADMAP — belo-infrabase-k3d

Stack completo de CI/CD y deployment strategies sobre k3d (Kubernetes local), con el mismo modelo operativo que una implementación cloud real y sin dependencias externas.

Este documento resume las **capacidades implementadas**, las **limitaciones conocidas** y el **trabajo futuro**.

---

## Capacidades implementadas

### Cluster local
- Cluster k3d: 1 server + 3 agents con roles `statefulls`, `stateless` y `cicd`.
- Node labels y taints para segregar cargas por tipo.
- Volumen Docker persistente para el stack stateful (`belo-statefull-data`).
- hostPort mapping `8888 → 80` para acceso local vía nginx.

### Infraestructura de servicios
- nginx-ingress (NodePort, hostPort 8888 → 80).
- metrics-server (incluido en k3s).
- ArgoCD — controller GitOps, expuesto en `argocd.localhost`.
- Argo Rollouts — controller de BlueGreen / Canary / RollingUpdate.
- Tekton Pipelines + Triggers + Dashboard, instalados desde los releases oficiales.

### Observabilidad
- kube-prometheus-stack (Prometheus + Grafana) en `grafana.localhost`.
- EFK (Elasticsearch + Fluent-bit + Kibana) en `kibana.localhost`.
- Headlamp como dashboard general de Kubernetes en `headlamp.localhost`.
- ServiceMonitors para ambas APIs, Tekton y Argo Rollouts.
- 4 dashboards de Grafana provisionados vía ConfigMaps (sidecar auto-load).

### Apps y deployment strategies
- `webserver-api01` y `webserver-api02` — FastAPI con structured logging (structlog) y métricas Prometheus.
- Helm chart maestro `pythonapps` que soporta `bluegreen`, `canary` y `rollingupdate`.
- Topología invariante: los services e ingresses `stable` y `preview` existen siempre, en las tres estrategias.

### Release pipeline (6 stages)
1. `git-clone-app` — clone exacto en la ref del tag.
2. `kaniko-build-push` — build sin Docker daemon + push a Docker Hub.
3. `bump-gitops-image` — actualiza `image.tag` vía yq + git push autenticado; emite el `commit-sha`.
4. `wait-argocd-sync` — force-refresh de ArgoCD, espera el commit correcto y el Rollout en el estado esperado según strategy + modo.
5. `run-load-test` — k6 in-cluster; en modo legacy valida (gated por el flag `loadtest`), en modo enterprise genera tráfico para el `AnalysisRun`.
6. `promote-or-rollback` — en modo legacy patchea promote/abort según el outcome; en modo enterprise solo observa.

### Burn pipeline (capacity test, on-demand)
- Pipeline separado del release (`pythonapps-burn-pipeline`, 2 stages).
- Sidecar k6 genera carga sostenida; el step principal monitorea el scale-up del HPA.
- Se dispara con tag `refs/tags/burn/<env>` o con `make burn-test`.

### Triggers automáticos
- EventListener con interceptor CEL: dos triggers, `release/<ver>/<envs>[/loadtest=<bool>]` y `burn/<env>`.
- TriggerBinding + TriggerTemplate generan el PipelineRun con SA, tolerations y URLs computadas.
- Ingress `tekton-webhook.localhost` para recibir webhooks de GitHub.
- RBAC mínimo por ServiceAccount.

### GitOps (apps-of-apps)
- ArgoCD apps-of-apps con bootstrap desde este repo.
- Application CRs por app y por env, en namespaces dedicados `<app>-<env>`.
- Auto-sync con `selfHeal` y `prune`.

### Modelo enterprise — AnalysisTemplate + promoción automática
- `AnalysisTemplate` con dos métricas Prometheus: `success-rate` (≥99%) y `latency-p95` (<1s).
- Rollout BG enterprise: `prePromotionAnalysis` + `postPromotionAnalysis`, con `scaleDownDelaySeconds` que cubre la ventana de rollback automático.
- Rollout Canary enterprise: `analysis` en cada `setWeight` (5/25/50/100) — canary genuinamente gradual.
- El pipeline detecta el modo por introspección del Rollout vivo, sin params extra.
- El modelo legacy se preserva como default del chart (`analysis.enabled: false`).

### Naming determinístico de PipelineRuns
- Los PipelineRuns se nombran `<app>-pipelinerun-<image-tag>`; los TaskRuns y pods heredan el prefijo.
- Re-pushear el mismo tag falla con `AlreadyExists` — fuerza disciplina de semver.

### Load testing
- Scripts k6 (`smoke.js`, `load-bluegreen.js`, `load-canary.js`, `burn-to-scale.js`) versionados en el repo de cada app.
- `task-load-test` hace fail-fast si el script de la strategy no existe en el repo de la app.

### Documentación
- `README.md` — quick start completo y referencia.
- `docs/architecture.md` — diagramas Mermaid de topología, componentes, flujo CI/CD y promote-rollback.
- `docs/pipeline-stages.md` y `docs/pipeline-internals.md` — stage-by-stage y detalle técnico por Task.
- `docs/deployment-strategies.md` — Blue/Green vs Canary, modelos legacy y enterprise.
- `docs/security-and-rbac.md`, `docs/troubleshooting.md`, `docs/demo-guide.md`, `docs/webhook-setup.md`, `docs/daily-ops.md`, `docs/logging-efk.md`, `docs/grafana-dashboards.md`.
- `MAKEFILE_GUIDE.md` — referencia de todos los targets y variables.

---

## Limitaciones conocidas

| Ítem | Descripción | Prioridad para producción |
|------|-------------|--------------------------|
| **Sin TLS local** | nginx usa HTTP plano. Para HTTPS se puede usar cert-manager + mkcert | Media |
| **GitHub PAT en Secret** | El token de push gitops vive en un K8s Secret. Migrar a External Secrets Operator + Vault | Alta |
| **Kaniko sin caché persistente** | Cada build descarga las capas base. Agregar un registry local para `--cache` | Baja |
| **Single-node statefulls** | Elasticsearch y Prometheus sin HA. Para producción: réplicas + anti-affinity | Media |
| **Sin imagen base hardened** | Las apps usan `python:3.12-slim`. Para producción: imagen distroless o Chainguard | Media |
| **Bump multi-env limitado** | El bump escribe en todos los envs del tag, pero el pipeline corre contra el primero. Multi-env real requiere N PipelineRuns | Media |
| **Sin webhook HMAC por default** | El EventListener no valida la firma HMAC. Documentado y opt-in en `webhook-setup.md` | Media |
| **Sin NetworkPolicies** | El namespace `tekton-pipelines` puede hablar con cualquiera. Para producción: egress restringido | Media |
| **Sin image signing** | Las imágenes no se firman ni se verifican con cosign/notary | Media |
| **Canary `promoteFull` en modo legacy** | El patch `promoteFull=true` lleva el canary directo a 100%. El modo enterprise sí avanza step a step | Baja |

---

## Trabajo futuro

- TLS local con cert-manager.
- External Secrets Operator + Vault para los tokens del pipeline.
- NetworkPolicies para aislar `tekton-pipelines` y los namespaces de apps.
- Image signing con cosign y verificación en admission.
- Caché persistente de kaniko con un registry local.
- HA para Elasticsearch y Prometheus.
- Validación HMAC del webhook activada por default.

---

## Stack de tecnologías

| Capa | Tecnología | Versión |
|------|-----------|---------|
| Kubernetes local | k3d (k3s en Docker) | v5.6+ |
| Deployment strategies | Argo Rollouts | latest |
| GitOps | ArgoCD | latest (helm chart argo/argo-cd) |
| CI/CD | Tekton Pipelines + Triggers | latest release |
| CI/CD UI | Tekton Dashboard | latest release |
| Build | Kaniko | gcr.io/kaniko-project/executor:latest |
| Ingress | nginx-ingress | kubernetes.github.io/ingress-nginx |
| Logging | EFK (Elasticsearch + Fluent-bit + Kibana) | elastic/elastic (helm) |
| Monitoring | kube-prometheus-stack | prometheus-community (helm) |
| Dashboard general | Headlamp | kubernetes-sigs/headlamp (helm) |
| Load testing | k6 | grafana/k6:latest |
| Apps | Python FastAPI + structlog + prometheus-client | Python 3.12 |
| Packaging | Helm (chart maestro `pythonapps`) | v3.14+ |
| Storage | local-path provisioner | nativo k3s |
| Tunnel para webhook | ngrok | ≥ 3.20.0 (requisito de cuenta free) |
