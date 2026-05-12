# Arquitectura — belo-infrabase-k3d

Este documento tiene tres diagramas: la **topología del cluster k3d**, los **componentes internos**, y el **flujo CI/CD completo**. GitHub renderiza Mermaid nativamente.

---

## 1. Topología del cluster k3d

```mermaid
flowchart TB
    Dev[/Desarrollador/]
    GH[GitHub<br/>app repo]
    DH[Docker Hub]

    Dev -->|"git tag dev/bluegreen/v1.0.0<br/>git push origin --tags"| GH

    subgraph HOST["Host Windows — Docker Desktop"]
        PORT["localhost:8888 → nginx:80<br/>(k3d hostPort mapping)"]

        subgraph K3D["k3d Cluster — belo-challenge"]
            SRV["server-0<br/>k3s control plane"]

            subgraph AG0["agent-0 — role=statefulls (tainted)"]
                ES["Elasticsearch<br/>StatefulSet"]
                PR["Prometheus<br/>StatefulSet"]
                KB["Kibana"]
                GR["Grafana"]
            end

            subgraph AG1["agent-1 — role=stateless"]
                NGX["nginx-ingress<br/>NodePort :80"]
                AR["Argo Rollouts<br/>controller"]
                AC["ArgoCD"]
                HL["Headlamp"]
                API01["webserver-api01<br/>Rollout"]
                API02["webserver-api02<br/>Rollout"]
            end

            subgraph AG2["agent-2 — role=cicd (tainted)"]
                TK["Tekton Pipelines<br/>+ Triggers"]
                EL["EventListener<br/>github-tag-listener"]
                PR_RUNS["PipelineRuns<br/>(pods efímeros)"]
            end
        end
    end

    PORT --> NGX
    GH -->|"webhook POST /push"| PORT
    GH -.->|"git clone (Stage 1)"| PR_RUNS
    DH -.->|"push image (Stage 2)"| PR_RUNS
    GH -.->|"git push bump (Stage 3)"| PR_RUNS

    classDef statefulls fill:#dbeafe,stroke:#3b82f6,color:#000
    classDef stateless fill:#dcfce7,stroke:#16a34a,color:#000
    classDef cicd fill:#fef9c3,stroke:#ca8a04,color:#000
    classDef external fill:#f3f4f6,stroke:#6b7280,color:#000

    class AG0,ES,PR,KB,GR statefulls
    class AG1,NGX,AR,AC,HL,API01,API02 stateless
    class AG2,TK,EL,PR_RUNS cicd
    class Dev,GH,DH,HOST external
```

### Mapa de cargas por nodo

| Nodo | Label | Taint | Cargas |
|------|-------|-------|--------|
| `server-0` | — | — | k3s control plane (etcd, API server) |
| `agent-0` | `role=statefulls` | `workload=statefulls:NoSchedule` | Elasticsearch, Prometheus, Kibana, Grafana |
| `agent-1` | `role=stateless` | — | nginx-ingress, ArgoCD, ArgoRollouts, api01, api02, Headlamp |
| `agent-2` | `role=cicd` | `workload=cicd:NoSchedule` | Tekton controller, EventListener, PipelineRuns (pods efímeros) |

> Los nodos con taint solo aceptan pods que declaren la toleration correspondiente.
> Los PipelineRuns llevan `toleration: workload=cicd` y `nodeSelector: role=cicd` en el TriggerTemplate.

---

## 2. Componentes internos del cluster

```mermaid
flowchart LR
    subgraph ns_sys["kube-system / ingress-nginx"]
        NGX[nginx-ingress<br/>NodePort :80]
        MS[metrics-server]
    end

    subgraph ns_argo["argocd"]
        AC[ArgoCD<br/>server]
    end

    subgraph ns_rollouts["argo-rollouts"]
        AR[Argo Rollouts<br/>controller]
    end

    subgraph ns_tekton["tekton-pipelines (nodo cicd)"]
        TK[Tekton<br/>Pipelines]
        EL[EventListener<br/>CEL filter]
    end

    subgraph ns_dev["namespace: dev"]
        A1_S["webserver-api01<br/>-stable svc"]
        A1_P["webserver-api01<br/>-preview svc"]
        A2_S["webserver-api02<br/>-stable svc"]
        A2_P["webserver-api02<br/>-preview svc"]
    end

    subgraph ns_log["logging (nodo statefulls)"]
        ES[(Elasticsearch)]
        FB[Fluent-bit<br/>DaemonSet]
        KB[Kibana]
    end

    subgraph ns_mon["monitoring (nodo statefulls)"]
        PROM[(Prometheus)]
        GR[Grafana]
    end

    NGX --> A1_S
    NGX --> A1_P
    NGX --> A2_S
    NGX --> A2_P
    AC -->|sync Rollout| A1_S
    AC -->|sync Rollout| A2_S
    AR -->|traffic split| A1_S
    AR -->|traffic split| A2_S
    EL --> TK
    FB -->|logs| ES
    KB --- ES
    PROM -->|scrape /metrics| A1_S
    PROM -->|scrape /metrics| A2_S
    GR --- PROM
```

### Topología invariante (stable + preview siempre existen)

Para **las tres estrategias** (BlueGreen, Canary, RollingUpdate) se crean siempre los mismos recursos:

| Recurso | Nombre | Propósito |
|---------|--------|-----------|
| Service | `<app>-stable` | Tráfico productivo; objetivo del Ingress principal |
| Service | `<app>-preview` | Nueva versión antes del promote; objetivo del Ingress preview |
| Ingress | `<app>-stable` | `api01.localhost` → stable svc |
| Ingress | `<app>-preview` | `preview-api01.localhost` → preview svc |

Esto garantiza que las URLs de load test (`http://<app>-stable.<env>.svc.cluster.local:8000`) sean accesibles independientemente de la estrategia activa.

---

## 3. Flujo CI/CD completo

```mermaid
sequenceDiagram
    autonumber
    actor Dev
    participant GH as GitHub<br/>(repo de la app)
    participant EL as Tekton EventListener<br/>(CEL interceptor)
    participant TR as PipelineRun<br/>(nodo cicd)
    participant DH as Docker Hub
    participant GR as belo-infrabase-k3d<br/>(GitOps repo)
    participant AC as ArgoCD
    participant AR as Argo Rollouts
    participant K6 as k6 task<br/>(in-cluster)

    Dev->>GH: git tag dev/bluegreen/v1.2.0
    Dev->>GH: git push origin --tags
    GH->>EL: webhook POST (X-Github-Event: push)
    EL->>EL: CEL filter:<br/>refs/tags/<env>/<strategy>/<semver>
    Note over EL: environment=dev<br/>strategy=bluegreen<br/>image_tag=v1.2.0<br/>app-name=webserver-api01
    EL->>TR: crea PipelineRun con params

    Note over TR: Stage 1 — clone
    TR->>GH: git clone --depth 1 (tag ref)

    Note over TR: Stage 2 — build-push
    TR->>TR: Kaniko build (src/Dockerfile)
    TR->>DH: docker push valentinobruno/webserver-api01:v1.2.0

    Note over TR: Stage 3 — bump-gitops
    TR->>GR: git clone (github-token secret)
    TR->>GR: yq: image.tag=v1.2.0 / rollout.strategy=bluegreen
    TR->>GR: git commit + push

    Note over TR: Stage 4 — wait-argocd
    GR->>AC: ArgoCD detecta commit (polling/webhook)
    AC->>AR: aplica Rollout actualizado (strategy=bluegreen)
    AR->>AR: levanta pods preview (Green)
    TR->>TR: poll ArgoCD: Synced+Healthy<br/>poll Rollout: fase=Paused

    Note over TR: Stage 5 — load-test
    TR->>K6: k6 run load-bluegreen.js
    K6->>AR: HTTP → webserver-api01-preview.dev.svc:8000
    K6-->>TR: result outcome=passed|failed

    Note over TR: Stage 6 — promote-rollback
    alt outcome = passed
        TR->>AR: kubectl argo rollouts promote webserver-api01
        AR->>AR: switch tráfico → Green (ahora stable)
        AR->>AR: scale-down Blue (30s delay)
    else outcome = failed
        TR->>AR: kubectl argo rollouts abort webserver-api01
        AR->>AR: destruye Green, Blue (stable) intacto
    end
```

### Convención de tag

```
refs/tags/<env>/<strategy>/<semver>
```

El interceptor CEL filtra tags que cumplan exactamente esta forma (5 segmentos). Tags con otro formato no disparan ningún pipeline.

| Tag (lo que pusheás) | `environment` | `strategy` | `image_tag` |
|----------------------|---------------|------------|-------------|
| `dev/bluegreen/v1.2.0` | `dev` | `bluegreen` | `v1.2.0` |
| `dev/canary/v1.2.0` | `dev` | `canary` | `v1.2.0` |
| `dev/rollingupdate/v1.2.0` | `dev` | `rollingupdate` | `v1.2.0` |

> El `app-name` lo extrae el TriggerBinding de `body.repository.name` (nombre del repo de GitHub). Por eso el repo de la app **debe llamarse igual que el app-name** en el values de ArgoCD (`webserver-api01` / `webserver-api02`).

### Stages del pipeline

| # | Task Tekton | Qué hace |
|---|-------------|----------|
| 1 | `git-clone-app` | `git clone --depth 1` del repo de la app al workspace `source` |
| 2 | `kaniko-build-push` | Build de `src/Dockerfile` + push a Docker Hub |
| 3 | `bump-gitops-image` | yq: actualiza `image.tag` y `rollout.strategy` en values; commit + push al repo gitops |
| 4 | `wait-argocd-sync` | Poll hasta `ArgoCD Synced+Healthy` y Rollout en fase `Paused` (BG/Canary) o `Healthy` (Rolling) |
| 5 | `run-load-test` | k6 contra el endpoint correcto según strategy; emite result `outcome=passed\|failed`; siempre exits 0 |
| 6 | `promote-rollback` | BG: promote/abort; Canary: promote-full/abort; RollingUpdate: no-op/undo |

---

## 4. Estrategias de deployment

### Blue/Green — webserver-api01

```
         ANTES DEL PROMOTE
                │
    ┌───────────┴───────────┐
    │                       │
 stable-svc             preview-svc
 (Blue: v1.1)           (Green: v1.2)   ← k6 load-bluegreen.js
    │                       │
 100% tráfico           0% tráfico
                            │
               outcome=passed → promote
                            │
         DESPUÉS DEL PROMOTE
                │
    ┌───────────┴───────────┐
    │                       │
 stable-svc             preview-svc
 (Green: v1.2)          (Blue: v1.1 → scale-down 30s)
    │
 100% tráfico
```

### Canary — webserver-api02

```
           stable-svc              preview-svc
            (v1.1)                  (v1.2)
               │                       │
              95%        5%    ← step 1 (Paused — k6 corre)
              75%       25%    ← step 2 (Paused — k6 corre)
              50%       50%    ← step 3 (Paused — k6 corre)
               │               outcome=passed → promote --full
               └───────────────────────┘
                       100% (v1.2 es stable)
```

### RollingUpdate

```
 Rollout actualiza pods uno a uno (maxSurge 1, maxUnavailable 0).
 Completa directamente → fase Healthy (no Paused).
 Stage 5: k6 smoke.js contra el stable service.
 Stage 6: outcome=failed → kubectl rollout undo; outcome=passed → no-op.
```

---

## 5. Namespaces y distribución

| Namespace | Contenido | Nodo |
|-----------|-----------|------|
| `kube-system` | metrics-server, nginx-ingress, Headlamp | agent-1 |
| `argocd` | ArgoCD server + controller | agent-1 |
| `argo-rollouts` | Rollouts controller | agent-1 |
| `tekton-pipelines` | Tekton + Triggers + EventListener | agent-2 |
| `dev` | webserver-api01, webserver-api02 | agent-1 |
| `logging` | Elasticsearch, Fluent-bit, Kibana | agent-0 |
| `monitoring` | Prometheus, Grafana | agent-0 |

---

## 6. Deuda técnica conocida

- **Sin TLS local** — nginx usa HTTP. Para HTTPS local se puede usar cert-manager con un self-signed CA o mkcert.
- **GitHub PAT en Secret** — el token de push al repo gitops vive en un `Secret` de Kubernetes. En producción migrar a External Secrets Operator + vault/AWS Secrets Manager.
- **Single-node statefulls** — Elasticsearch y Prometheus sin HA. Suficiente para POC; para producción añadir replicas y anti-affinity.
- **Kaniko sin caché persistente** — cada build baja las capas base de nuevo. Agregar `--cache=true` con un registry local (e.g. `registry:2`) acelera builds en ~60%.
- **Sin análisis de métricas en rollout** — los Rollouts usan pauses manuales/pipeline. La siguiente mejora es añadir `AnalysisTemplate` con Prometheus para automatizar la decisión.
