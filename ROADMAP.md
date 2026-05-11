# ROADMAP — belo-infrabase-k3d

Stack completo de deployment strategies sobre k3d (Kubernetes local). Mismo nivel de madurez que una implementación cloud real, sin dependencias externas.

## Fases

### Fase 1 — Cluster local
- [x] k3d config (1 server + 3 agents: statefulls, stateless, cicd)
- [x] Node labels y taints (segregación de cargas)
- [x] Volumen persistente para stack stateful

### Fase 2 — Infraestructura de servicios
- [x] nginx-ingress (NodePort, port 8888 → 80)
- [x] metrics-server (--kubelet-insecure-tls para k3d)
- [x] ArgoCD (GitOps controller)
- [x] Argo Rollouts (BlueGreen + Canary controller)
- [x] Tekton Pipelines + Triggers (CI/CD)

### Fase 3 — Observabilidad
- [x] kube-prometheus-stack (Prometheus + Grafana)
- [x] Elasticsearch + Fluent-bit + Kibana (EFK logging)
- [x] Headlamp (Kubernetes dashboard)
- [x] ServiceMonitors para ambas APIs

### Fase 4 — Apps y deployment strategies
- [x] webserver-api01 (FastAPI, BlueGreen via ArgoRollouts)
- [x] webserver-api02 (FastAPI, Canary via ArgoRollouts)
- [x] Helm chart maestro `pythonapps` (soporta bluegreen/canary/rollingupdate)
- [x] Structured logging (structlog JSON) → EFK
- [x] Prometheus metrics → Grafana dashboards

### Fase 5 — CI/CD Pipeline
- [x] Tekton Tasks: clone, build (Kaniko), load-test (k6), bump-gitops
- [x] Pipeline: clone → build+push → load-test → bump gitops tag
- [x] Triggers: EventListener + CEL filter (tag push en GitHub)
- [x] TriggerBinding + TriggerTemplate → PipelineRun automático
- [x] RBAC mínimo para el SA de Triggers

### Fase 6 — GitOps
- [x] ArgoCD apps-of-apps (bootstrap desde este repo)
- [x] Application CRs por app (api01, api02) en namespace `dev`
- [x] Auto-sync con selfHeal
- [x] bump-gitops actualiza `image.tag` → ArgoCD sincroniza el Rollout

### Fase 7 — Load testing
- [x] smoke.js (baseline health check)
- [x] load-bluegreen.js (contra preview service antes del promote)
- [x] load-canary.js (contra stable mientras el canary avanza)

## Stack de tecnologías

| Capa | Tecnología |
|------|-----------|
| Kubernetes local | k3d (k3s en Docker) |
| Deployment strategies | Argo Rollouts |
| GitOps | ArgoCD |
| CI/CD | Tekton Pipelines + Triggers |
| Build | Kaniko (sin Docker daemon) |
| Ingress | nginx-ingress (NodePort) |
| Logging | EFK (Elasticsearch + Fluent-bit + Kibana) |
| Monitoring | kube-prometheus-stack (Prometheus + Grafana) |
| Load testing | k6 |
| Apps | Python FastAPI + structlog + prometheus-client |
| Packaging | Helm (chart maestro `pythonapps`) |
