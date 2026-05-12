# ROADMAP — belo-infrabase-k3d

Stack completo de CI/CD y deployment strategies sobre k3d (Kubernetes local). Mismo nivel de madurez que una implementación cloud real, sin dependencias externas.

---

## Fases completadas

### Fase 1 — Cluster local
- [x] k3d config (1 server + 3 agents: statefulls, stateless, cicd)
- [x] Node labels y taints (segregación de cargas por tipo)
- [x] Volumen Docker persistente para stack stateful (`belo-statefull-data`)
- [x] hostPort mapping `8888 → 80` para acceso local vía nginx

### Fase 2 — Infraestructura de servicios
- [x] nginx-ingress (NodePort, hostPort 8888 → 80, hostNetwork)
- [x] metrics-server (--kubelet-insecure-tls para k3d)
- [x] ArgoCD (GitOps controller, ingress en argocd.localhost)
- [x] Argo Rollouts (BlueGreen + Canary + RollingUpdate controller)
- [x] Tekton Pipelines + Triggers (CI/CD, instalado desde releases oficiales)

### Fase 3 — Observabilidad
- [x] kube-prometheus-stack (Prometheus + Grafana, grafana.localhost)
- [x] Elasticsearch + Fluent-bit + Kibana (EFK logging, kibana.localhost)
- [x] Headlamp (Kubernetes dashboard, headlamp.localhost)
- [x] ServiceMonitors para ambas APIs (scraping automático de /metrics)

### Fase 4 — Apps y deployment strategies
- [x] webserver-api01 (FastAPI, BlueGreen por defecto)
- [x] webserver-api02 (FastAPI, Canary por defecto)
- [x] Helm chart maestro `pythonapps` (soporta bluegreen/canary/rollingupdate)
- [x] **Topología invariante**: stable + preview services e ingresses existen siempre
- [x] Structured logging (structlog JSON) → EFK
- [x] Prometheus metrics → Grafana
- [x] **Strategy-per-deploy**: tag encoda la estrategia → se escribe en values → ArgoCD la aplica

### Fase 5 — CI/CD Pipeline (6 stages)
- [x] Stage 1: `git-clone-app` — clone exacto en la ref del tag
- [x] Stage 2: `kaniko-build-push` — build sin Docker daemon + push a Docker Hub
- [x] Stage 3: `bump-gitops-image` — actualiza `image.tag` Y `rollout.strategy` via yq + git push autenticado
- [x] Stage 4: `wait-argocd-sync` — poll hasta ArgoCD Synced+Healthy y Rollout Paused/Healthy
- [x] Stage 5: `run-load-test` — k6 in-cluster, siempre exits 0, emite Tekton result `outcome`
- [x] Stage 6: `promote-rollback` — actúa sobre `outcome`: promote o abort/undo según strategy

### Fase 6 — Triggers automáticos
- [x] EventListener con CEL interceptor (filtro: `refs/tags/<env>/<strategy>/<semver>`)
- [x] TriggerBinding — extrae repo-url, app-name, environment, strategy, image-tag, revision
- [x] TriggerTemplate — genera PipelineRun con SA, tolerations y computed URLs
- [x] Ingress `tekton-webhook.localhost` para recibir webhooks de GitHub
- [x] RBAC mínimo: SA `tekton-triggers-sa` (crear/listar PipelineRuns) + SA `tekton-pipeline-runner` (Rollouts + Applications)

### Fase 7 — GitOps (apps-of-apps)
- [x] ArgoCD apps-of-apps (bootstrap desde este repo)
- [x] Application CRs por app (api01, api02) en namespace `dev`
- [x] Auto-sync con selfHeal y prune
- [x] bump-gitops actualiza `image.tag` + `rollout.strategy` → ArgoCD redespliega el Rollout

### Fase 8 — Load testing completo
- [x] `smoke.js` para api01 y api02 (baseline health + latencia)
- [x] `load-bluegreen.js` para api01 y api02 (contra preview service)
- [x] `load-canary.js` para api01 y api02 (contra stable con canary activo)

### Fase 9 — Documentación
- [x] `docs/architecture.md` — diagramas Mermaid de topología, componentes y flujo CI/CD
- [x] `docs/demo-guide.md` — guía paso a paso para cada estrategia
- [x] `docs/webhook-setup.md` — configuración de webhook GitHub → Tekton (ngrok, smee, HMAC)
- [x] `README.md` — entregable final profesional con quick start completo
- [x] `MAKEFILE_GUIDE.md` — referencia de todos los targets y variables

---

## Deuda técnica conocida

Vale más documentarla que esconderla:

| Ítem | Descripción | Prioridad para producción |
|------|-------------|--------------------------|
| **Sin TLS local** | nginx usa HTTP plano. Para HTTPS se puede usar cert-manager + mkcert | Media |
| **GitHub PAT en Secret** | El token de push gitops vive en K8s Secret. Migrar a External Secrets Operator + vault | Alta |
| **Kaniko sin caché persistente** | Cada build descarga las capas base. Agregar `--cache=true` + registry local | Baja |
| **Single-node statefulls** | Elasticsearch y Prometheus sin HA. Para producción: replicas + anti-affinity | Media |
| **Sin AnalysisTemplate** | Los Rollouts usan pauses + pipeline para decisión. Automatizar con Prometheus AnalysisTemplate | Media |
| **Sin imagen base hardened** | Las apps usan `python:3.12-slim`. Para producción: imagen distroless o Chainguard | Media |
| **Sin multi-namespace** | Solo existe el namespace `dev`. Agregar `staging` y `prod` con sus Application CRs | Baja |
| **Sin webhook HMAC** | El EventListener no valida la firma HMAC del webhook de GitHub | Media |

---

## Stack de tecnologías

| Capa | Tecnología | Versión |
|------|-----------|---------|
| Kubernetes local | k3d (k3s en Docker) | v5.6+ |
| Deployment strategies | Argo Rollouts | latest |
| GitOps | ArgoCD | latest (helm chart argo/argo-cd) |
| CI/CD | Tekton Pipelines + Triggers | latest release |
| Build | Kaniko | gcr.io/kaniko-project/executor:latest |
| Ingress | nginx-ingress | kubernetes.github.io/ingress-nginx |
| Logging | EFK (Elasticsearch + Fluent-bit + Kibana) | elastic/elastic (helm) |
| Monitoring | kube-prometheus-stack | prometheus-community (helm) |
| Dashboard | Headlamp | kubernetes-sigs/headlamp (helm) |
| Load testing | k6 | grafana/k6:latest |
| Apps | Python FastAPI + structlog + prometheus-client | Python 3.12 |
| Packaging | Helm (chart maestro `pythonapps`) | v3.14+ |
| Storage | local-path provisioner | nativo k3s |
