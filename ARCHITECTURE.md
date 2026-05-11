# Architecture — belo-infrabase-k3d

## Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                         k3d Cluster                                 │
│                                                                     │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐             │
│  │  agent-0     │  │  agent-1     │  │  agent-2     │             │
│  │  statefulls  │  │  stateless   │  │  cicd        │             │
│  │  (tainted)   │  │              │  │  (tainted)   │             │
│  │              │  │  api01 pods  │  │  tekton pods │             │
│  │  ES + Kibana │  │  api02 pods  │  │              │             │
│  │  Prometheus  │  │  argocd      │  │              │             │
│  └──────────────┘  └──────────────┘  └──────────────┘             │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  nginx-ingress (NodePort :8888)                             │   │
│  │  api01.localhost → webserver-api01-stable   (BlueGreen)    │   │
│  │  api02.localhost → webserver-api02-stable   (Canary)       │   │
│  │  argocd.localhost → ArgoCD UI                               │   │
│  │  grafana.localhost → Grafana                                │   │
│  │  kibana.localhost → Kibana                                  │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

## CI/CD Flow

```
GitHub (tag push v1.x.x)
        │
        ▼
EventListener (Tekton Triggers)
  └── CEL: refs/tags/*
        │
        ▼
TriggerTemplate → PipelineRun (en nodo cicd)
        │
        ├─ Task: git-clone-app
        ├─ Task: kaniko-build-push  → DockerHub (docker.io/valentinobruno/api01:v1.x.x)
        ├─ Task: run-load-test      → k6 smoke.js | load-bluegreen.js | load-canary.js
        └─ Task: bump-gitops-image  → git commit: charts/pythonapps/apps/.../values.yaml
                                             image.tag: v1.x.x
                                                 │
                                                 ▼
                                         ArgoCD detecta cambio
                                                 │
                                                 ▼
                                         Rollout actualizado
```

## BlueGreen (api01)

```
               ANTES DEL PROMOTE
                      │
        ┌─────────────┴─────────────┐
        │                           │
   active-svc                 preview-svc
  (Blue: v1.0)               (Green: v1.1)
        │                           │
   100% tráfico              0% tráfico (load test aquí)
                                    │
                         k6 load-bluegreen.js pasa
                                    │
                                    ▼
                         kubectl argo rollouts promote api01
                                    │
               DESPUÉS DEL PROMOTE
                      │
        ┌─────────────┴─────────────┐
        │                           │
   active-svc                 preview-svc
  (Green: v1.1)              (Blue: v1.0, scale-down 30s)
        │
   100% tráfico
```

## Canary (api02)

```
           stable-svc           canary-svc
            (v1.0)               (v1.1)
               │                    │
              95%                   5%    ← step 1 (pause manual)
               │                    │
              75%                  25%    ← step 2 (pause manual)
               │                    │
              50%                  50%    ← step 3 (pause manual)
               │                    │
               └────────────────────┘
                        0%
                    (v1.1 promueve a stable, 100%)
```

## Repo Layout

```
belo-infrabase-k3d/
├── apps/               ← código fuente de las apps Python
│   ├── webserver-api01/
│   └── webserver-api02/
├── charts/
│   └── pythonapps/     ← Helm chart maestro (Rollout + Service + Ingress + Tekton Tasks + Pipeline)
├── gitops/             ← ArgoCD Application CRs
│   ├── apps-of-apps.yaml
│   └── gitops-core-dev/
├── helm/addons/        ← values para cada addon de infra
├── k3d/config.yaml     ← config del cluster k3d
├── manifests/
│   ├── argocd/         ← bootstrap root Application
│   └── tekton/         ← ejemplos de secrets + PipelineRun manual
└── Makefile            ← entrada principal para todo
```

## Namespaces

| Namespace | Contenido |
|-----------|-----------|
| `kube-system` | metrics-server, nginx-ingress |
| `argocd` | ArgoCD server + application controller |
| `argo-rollouts` | Rollouts controller |
| `tekton-pipelines` | Tekton + Triggers + EventListener |
| `dev` | webserver-api01, webserver-api02 |
| `logging` | Elasticsearch, Fluent-bit, Kibana |
| `monitoring` | Prometheus, Grafana |
