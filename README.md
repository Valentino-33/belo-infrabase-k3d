# belo-infrabase-k3d

Stack completo de CI/CD y deployment strategies sobre Kubernetes local con **k3d**.
Demuestra BlueGreen y Canary con ArgoRollouts, GitOps con ArgoCD, y pipelines automatizados con Tekton — sin dependencias de nube.

## Quick Start

```bash
# 1. Pre-requisitos: Docker, k3d, kubectl, helm (ver sección Prereqs)
make cluster-up          # cluster k3d + todos los addons (~10 min)

# 2. Crear secretos para el pipeline (DockerHub + GitHub)
make secrets             # muestra instrucciones
make secrets-apply DOCKERHUB_USER=<tu_user> DOCKERHUB_TOKEN=<token> GITHUB_TOKEN=<token>

# 3. Bootstrap GitOps (requiere que el repo esté en GitHub y sea accesible)
make bootstrap           # aplica ArgoCD root app + Tekton pipeline manifests

# 4. Ver que todo sincronizó
make cluster-status

# 5. Ver demos interactivas
make demo-bluegreen
make demo-canary
```

**Acceso a UIs** (tras `make port-forward` o directo via `*.localhost:8888`):

| Servicio | URL |
|----------|-----|
| ArgoCD | http://argocd.localhost:8888 |
| Grafana | http://grafana.localhost:8888 (admin / belo-challenge) |
| Kibana | http://kibana.localhost:8888 |
| Headlamp | http://headlamp.localhost:8888 |
| api01 | http://api01.localhost:8888/api01/hello |
| api02 | http://api02.localhost:8888/api02/hello |
| Webhook Tekton | http://tekton-webhook.localhost:8888 |

> Para que los hostnames `.localhost` funcionen, agregá al `/etc/hosts`:
> `127.0.0.1 argocd.localhost grafana.localhost kibana.localhost headlamp.localhost api01.localhost api02.localhost preview-api01.localhost tekton-webhook.localhost`

---

## Arquitectura

```
k3d Cluster (4 nodos: 1 server + 3 agents)
┌──────────────────────────────────────────────────────────────────┐
│ agent-0 [statefulls, tainted]   Elasticsearch, Prometheus        │
│ agent-1 [stateless]             api01, api02, ArgoCD, Grafana    │
│ agent-2 [cicd, tainted]         Tekton PipelineRuns              │
│ server-0                        k3s control plane                │
├──────────────────────────────────────────────────────────────────┤
│ nginx-ingress (NodePort :8888→80) — todos los hostnames *.localhost │
└──────────────────────────────────────────────────────────────────┘

CI/CD Flow:
  git push tag v1.x.x
    → GitHub webhook → EventListener (Tekton Triggers)
    → CEL filter: refs/tags/*
    → PipelineRun en nodo cicd:
        clone → kaniko build+push → k6 load test → bump image.tag en este repo
    → ArgoCD detecta commit → actualiza Rollout
    → BlueGreen/Canary avanza según strategy
```

## Pre-requisitos

| Herramienta | Versión mínima | Instalación |
|-------------|----------------|-------------|
| Docker | 24+ | https://docs.docker.com/get-docker/ |
| k3d | v5.6+ | `brew install k3d` / https://k3d.io |
| kubectl | 1.28+ | https://kubernetes.io/docs/tasks/tools/ |
| helm | v3.14+ | `brew install helm` |
| k6 (opcional) | v0.50+ | `brew install k6` (solo para load tests locales) |
| tkn (opcional) | latest | `brew install tektoncd-cli` (para monitorear pipelines) |

> **Recursos mínimos**: 8 GB RAM, 4 CPU cores, 20 GB disco libre.

---

## Deployment Strategies

### Blue/Green — webserver-api01

La nueva versión (green) corre en paralelo al stable (blue). El tráfico no se redirige hasta que:
1. La nueva versión pase el health check
2. Se corra el load test `load-bluegreen.js` contra el preview service
3. El operador ejecute `kubectl argo rollouts promote webserver-api01 -n dev`

```bash
# Ver estado en tiempo real
kubectl argo rollouts get rollout webserver-api01 -n dev --watch

# Guía interactiva completa
make demo-bluegreen

# Disparar nueva versión
make pipeline-run APP=webserver-api01 TAG=v1.1.0

# Promover cuando estés listo
make rollout-promote APP=webserver-api01

# Rollback si algo falla
make rollout-abort APP=webserver-api01
```

**Verificar que el preview sirve la nueva versión antes de promover:**
```bash
curl http://preview-api01.localhost:8888/version
```

### Canary — webserver-api02

El tráfico se mueve gradualmente al canary: **5% → 25% → 50% → 100%**. Cada step requiere una promoción manual o se puede automatizar con análisis de métricas.

```bash
# Guía interactiva completa
make demo-canary

# Disparar nueva versión
make pipeline-run APP=webserver-api02 TAG=v1.1.0

# Avanzar steps (ejecutar 3 veces para llegar al 100%)
make rollout-promote APP=webserver-api02

# Ver distribución de tráfico en vivo
kubectl argo rollouts get rollout webserver-api02 -n dev --watch
```

---

## Tekton CI/CD Pipeline

### Trigger automático (webhook GitHub)

Cada push de tag al repo dispara el pipeline automáticamente:

```bash
git tag v1.2.0
git push origin v1.2.0
# → webhook → EventListener → PipelineRun
```

**Configurar el webhook en GitHub:**
1. Settings → Webhooks → Add webhook
2. Payload URL: `http://tekton-webhook.localhost:8888` (o la IP pública del cluster si es accesible)
3. Content type: `application/json`
4. Events: `Push`

### Trigger manual (sin webhook)

```bash
make pipeline-run APP=webserver-api01 TAG=v0.2.0

# Monitorear con tkn CLI
tkn pipelinerun logs -n tekton-pipelines --last -f

# O con kubectl
kubectl -n tekton-pipelines get pipelineruns
kubectl -n tekton-pipelines logs -l tekton.dev/pipelineRun=<name> -f
```

### Flujo del pipeline

```
Task 1: git-clone-app
  └── clone del repo a /workspace/source/src

Task 2: kaniko-build-push
  └── build Dockerfile → push docker.io/<user>/<app>:<tag>
  └── requiere secret: dockerhub-credentials

Task 3: run-load-test
  └── k6 smoke.js | load-bluegreen.js | load-canary.js (según strategy)
  └── WARN y continúa si no existen los scripts

Task 4: bump-gitops-image
  └── git clone este repo
  └── yq: .image.tag = "<tag>" en charts/pythonapps/apps/<app>/dev/values-*.yaml
  └── git commit + push
  └── requiere secret: github-token
```

---

## Observabilidad

### Logs (Kibana)
- Fluent-bit recolecta logs de todos los pods → Elasticsearch
- Acceder a `http://kibana.localhost:8888`
- Index pattern: `k8s-*`
- Los logs de las apps son JSON estructurado (structlog)

### Métricas (Grafana)
- Prometheus scrapeía las apps via ServiceMonitor
- Acceder a `http://grafana.localhost:8888` (admin / belo-challenge)
- Métricas disponibles: `api01_requests_total`, `api01_request_duration_seconds`, etc.

### Load testing
```bash
# Smoke test
make load-test-smoke APP=webserver-api01

# BlueGreen (contra preview)
make load-test-bluegreen

# Canary (contra stable con canary activo)
make load-test-canary
```

---

## Estructura del repo

```
belo-infrabase-k3d/
├── apps/
│   ├── webserver-api01/        ← FastAPI app (BlueGreen), Dockerfile, k6 scripts
│   └── webserver-api02/        ← FastAPI app (Canary), Dockerfile, k6 scripts
├── charts/
│   └── pythonapps/             ← Helm chart: Rollout + Service + Ingress + Tekton Tasks + Pipeline
│       └── apps/               ← values por app y ambiente
├── gitops/
│   ├── apps-of-apps.yaml       ← Root Applications de ArgoCD
│   └── gitops-core-dev/        ← Application CRs para namespace dev
├── helm/addons/                ← Values de cada addon (nginx, argocd, elk, prometheus...)
├── k3d/config.yaml             ← Definición del cluster k3d
├── manifests/
│   ├── argocd/bootstrap.yaml   ← Root Application (make bootstrap)
│   └── tekton/                 ← Ejemplos de secrets + PipelineRun manual
└── Makefile                    ← Entrada principal
```

---

## Comandos útiles

```bash
make help                                    # ver todos los targets
make cluster-status                          # estado del cluster
make argocd-password                         # password de ArgoCD
make rollout-status APP=webserver-api01      # estado del rollout en vivo
make rollout-promote APP=webserver-api01     # promover blue→green
make rollout-abort APP=webserver-api01       # rollback
make build APP=webserver-api01 TAG=v0.1.0   # build imagen local
make build-push APP=webserver-api01 TAG=v0.1.0  # build + push
make cluster-down                            # destruir todo
```

---

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
| Dashboard | Headlamp |
| Load testing | k6 |
| Apps | Python FastAPI + structlog + prometheus-client |
| Packaging | Helm (chart maestro `pythonapps`) |
| Storage | local-path (provisioner nativo de k3s) |
