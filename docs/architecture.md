# Arquitectura — belo-infrabase-k3d

Este documento contiene cuatro diagramas: la **topología del cluster k3d**, los **componentes internos**, el **flujo CI/CD completo end-to-end** (con la fix del race condition), y el **modelo de promote-rollback**. GitHub renderiza Mermaid nativamente.

---

## 1. Topología del cluster k3d

```mermaid
flowchart TB
    Dev[/Desarrollador/]
    GH[GitHub<br/>app repo + gitops repo]
    DH[Docker Hub]

    Dev -->|"git tag release/v1.0.0/dev<br/>git push origin --tags"| GH

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
                API01["webserver-api01<br/>Rollout (BG)"]
                API02["webserver-api02<br/>Rollout (Canary)"]
            end

            subgraph AG2["agent-2 — role=cicd (tainted)"]
                TK["Tekton Pipelines<br/>+ Triggers"]
                TD["Tekton Dashboard<br/>(UI tree view)"]
                EL["EventListener<br/>github-tag-listener"]
                PR_RUNS["PipelineRuns<br/>(pods efímeros)"]
            end
        end
    end

    PORT --> NGX
    GH -->|"webhook POST<br/>(via ngrok tunnel)"| PORT
    GH -.->|"git clone (Stage 1)"| PR_RUNS
    DH -.->|"push image (Stage 2)"| PR_RUNS
    GH -.->|"git push bump (Stage 3)"| PR_RUNS

    classDef statefulls fill:#dbeafe,stroke:#3b82f6,color:#000
    classDef stateless fill:#dcfce7,stroke:#16a34a,color:#000
    classDef cicd fill:#fef9c3,stroke:#ca8a04,color:#000
    classDef external fill:#f3f4f6,stroke:#6b7280,color:#000

    class AG0,ES,PR,KB,GR statefulls
    class AG1,NGX,AR,AC,HL,API01,API02 stateless
    class AG2,TK,TD,EL,PR_RUNS cicd
    class Dev,GH,DH,HOST external
```

### Mapa de cargas por nodo

| Nodo | Label | Taint | Cargas |
|------|-------|-------|--------|
| `server-0` | — | — | k3s control plane (etcd, API server) |
| `agent-0` | `role=statefulls` | `workload=statefulls:NoSchedule` | Elasticsearch, Prometheus, Kibana, Grafana |
| `agent-1` | `role=stateless` | — | nginx-ingress, ArgoCD, ArgoRollouts, api01, api02, Headlamp |
| `agent-2` | `role=cicd` | `workload=cicd:NoSchedule` | Tekton controller, Tekton Dashboard, EventListener, PipelineRuns (pods efímeros) |

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
        TD[Tekton Dashboard<br/>:9097]
    end

    subgraph ns_api01["namespace: webserver-api01-dev"]
        A1_S["webserver-api01-dev<br/>-stable svc"]
        A1_P["webserver-api01-dev<br/>-preview svc"]
    end

    subgraph ns_api02["namespace: webserver-api02-dev"]
        A2_S["webserver-api02-dev<br/>-stable svc"]
        A2_P["webserver-api02-dev<br/>-preview svc"]
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
    NGX --> TD
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
| Service | `<app>-<env>-stable` | Tráfico productivo; objetivo del Ingress principal |
| Service | `<app>-<env>-preview` | Nueva versión antes del promote; objetivo del Ingress preview |
| Ingress | `<app>-<env>-stable` | `api01.localhost` → stable svc |
| Ingress | `<app>-<env>-preview` | `preview-api01.localhost` → preview svc |

Esto garantiza que las URLs de load test (`http://<app>-<env>-stable.<namespace>.svc.cluster.local:8000`) sean accesibles independientemente de la estrategia activa.

### Namespaces

| Namespace | Contenido | Nodo |
|-----------|-----------|------|
| `kube-system` | metrics-server, nginx-ingress, Headlamp | agent-1 |
| `argocd` | ArgoCD server + controller | agent-1 |
| `argo-rollouts` | Rollouts controller | agent-1 |
| `tekton-pipelines` | Tekton + Triggers + EventListener + Dashboard | agent-2 |
| `webserver-api01-dev` | Rollout, services, pods de api01 | agent-1 |
| `webserver-api02-dev` | Rollout, services, pods de api02 | agent-1 |
| `logging` | Elasticsearch, Fluent-bit, Kibana | agent-0 |
| `monitoring` | Prometheus, Grafana | agent-0 |

---

## 3. Flujo CI/CD completo (con race-condition fix)

Este diagrama refleja la implementación **actual** del pipeline profesional, incluyendo la fix del race condition ArgoCD ↔ Pipeline y el promote vía `kubectl patch` directo en lugar del plugin.

```mermaid
sequenceDiagram
    autonumber
    actor Dev
    participant GH as GitHub<br/>(repo de la app)
    participant NGR as ngrok tunnel<br/>(make tunnel)
    participant EL as Tekton EventListener<br/>(CEL interceptor)
    participant TR as PipelineRun<br/>(nodo cicd)
    participant DH as Docker Hub
    participant GR as belo-infrabase-k3d<br/>(GitOps repo)
    participant AC as ArgoCD
    participant ARO as Argo Rollouts<br/>controller
    participant K6 as k6 task<br/>(in-cluster)

    Dev->>GH: git tag release/v1.2.0/dev
    Dev->>GH: git push origin --tags
    GH->>NGR: webhook POST<br/>(X-Github-Event: push)
    NGR->>EL: forward con<br/>Host: tekton-webhook.localhost
    EL->>EL: CEL filter:<br/>refs/tags/release/<sha>/<envs>
    Note over EL: image_tag=v1.2.0<br/>environments=dev<br/>app-name=webserver-api01<br/>(de body.repository.name)
    EL->>TR: crea PipelineRun<br/>name=webserver-api01-pipelinerun-v1.2.0<br/>(determinístico — re-push falla con AlreadyExists)

    rect rgb(220,252,231)
    Note over TR: Stage 1 — clone (10s)
    TR->>GH: git clone --depth 1<br/>refs/tags/release/v1.2.0/dev
    end

    rect rgb(220,252,231)
    Note over TR: Stage 2 — build-push (~30s)
    TR->>TR: Kaniko build<br/>(src/Dockerfile)
    TR->>DH: docker push<br/>valentinobruno/webserver-api01:v1.2.0
    end

    rect rgb(220,252,231)
    Note over TR: Stage 3 — bump-gitops (~10s)
    TR->>GR: git clone (con token<br/>de secret github-token)
    TR->>GR: yq: .image.tag = v1.2.0<br/>en values.yaml de cada env
    TR->>GR: git commit + push
    Note over TR: 🔑 emite result:<br/>commit-sha = <full SHA>
    end

    rect rgb(254,243,199)
    Note over TR: Stage 4 — wait-argocd (~20s)<br/>RACE-CONDITION FIX
    TR->>AC: kubectl annotate app<br/>argocd.argoproj.io/refresh=normal
    Note over AC: ArgoCD fuerza re-fetch<br/>del gitops (sin esperar polling 3min)
    AC->>GR: git fetch
    AC->>ARO: kubectl apply Rollout<br/>(image.tag=v1.2.0)
    ARO->>ARO: crea green RS<br/>+ pause BlueGreenPause
    loop polling each 5s
        TR->>AC: get app.status.sync.revision
        Note over TR: ¿== commit-sha del Stage 3?
    end
    loop polling each 5s
        TR->>ARO: get rollout.spec.image-tag<br/>+ rollout.status.phase
        Note over TR: ¿spec.image-tag = v1.2.0<br/>Y phase = Paused?
    end
    end

    rect rgb(220,252,231)
    Note over TR: Stage 5 — load-test (~60-90s)
    Note over TR: Lee script desde el repo de la app:<br/>/workspace/source/src/loadtest/<script>.js<br/>(fail-fast si no existe — no se permite verde sin tests)
    TR->>K6: k6 run load-bluegreen.js<br/>(o canary/smoke según strategy)
    K6->>ARO: HTTP → preview svc (BG)<br/>o stable svc (Canary/Rolling)
    K6-->>TR: result outcome=passed|failed
    end

    rect rgb(254,243,199)
    Note over TR: Stage 6 — promote-rollback (~10s)<br/>SIN PLUGIN — kubectl patch directo
    alt outcome=passed AND strategy=bluegreen
        TR->>ARO: kubectl patch rollout<br/>--subresource=status<br/>{"status":{"pauseConditions":null}}
        ARO->>ARO: switch active svc → green<br/>+ scaleDown blue (30s delay)
    else outcome=passed AND strategy=canary
        TR->>ARO: kubectl patch rollout<br/>--subresource=status<br/>{"status":{"promoteFull":true}}
        ARO->>ARO: skipea steps restantes<br/>→ 100% canary
    else outcome=failed (cualquier strategy)
        TR->>ARO: kubectl patch rollout<br/>{"spec":{"abort":true}}
        ARO->>ARO: destruye green/canary<br/>stable intacto
    end
    loop polling each 5s
        TR->>ARO: get rollout.status.phase
        Note over TR: ¿== Healthy (passed)<br/>o Degraded (failed)?
    end
    end

    Note over Dev,K6: ✅ ~2-3 min end-to-end<br/>desde push del tag hasta nueva versión sirviendo 100% del tráfico
```

### Convención de tag (real)

```
refs/tags/release/<semver>/<envs>
```

| Segmento | Ejemplo | Cómo se usa |
|----------|---------|-------------|
| `refs/tags/release/` | literal | filtro del CEL interceptor |
| `<semver>` | `v1.2.0` | extraído a `image_tag` (Tekton param) — usado como Docker tag y como `image.tag` del values.yaml |
| `<envs>` | `dev` o `dev,staging` | extraído a `environments` — el bump escribe en el `values.yaml` de cada env listado |

| Tag pusheado | `image_tag` | `environments` | Dispara |
|--------------|-------------|----------------|---------|
| `release/v1.2.0/dev` | `v1.2.0` | `dev` | ✅ |
| `release/v1.2.0/dev,staging` | `v1.2.0` | `dev,staging` | ✅ |
| `v1.2.0` | — | — | ❌ |
| `release/v1.2.0` | — | — | ❌ falta env |

> **Importante**: el `app-name` lo extrae el TriggerBinding de `body.repository.name`. El repo de la app **debe llamarse igual que el app-name** en values de ArgoCD (`webserver-api01` / `webserver-api02`).
>
> La **strategy** (bluegreen / canary / rollingupdate) **NO** se pasa por el tag — viene fija del `rollout.strategy` del chart Helm de la app. El pipeline la auto-detecta inspeccionando el live Rollout.

### Stages del pipeline (resumen)

| # | Task Tekton | Image | Output principal |
|---|-------------|-------|------------------|
| 1 | `git-clone-app` | `alpine/git` | repo en `/workspace/source/src` |
| 2 | `kaniko-build-push` | `gcr.io/kaniko-project/executor` | imagen en Docker Hub |
| 3 | `bump-gitops-image` | `alpine/git` + `mikefarah/yq` | commit pusheado + **result `commit-sha`** |
| 4 | `wait-argocd-sync` | `bitnami/kubectl` | sync.revision verificado + Rollout en `Paused` con el image-tag correcto |
| 5 | `run-load-test` | `grafana/k6` | **result `outcome` = passed/failed** (1000 VUs, p95/p99 thresholds) |
| 6 | `promote-or-rollback` | `bitnami/kubectl` | Rollout `phase=Healthy` o `Degraded` (verificado) |
| 7 | `run-burn-to-scale` | sidecar `k6` + step `bitnami/kubectl` | **result `outcome` + `max-replicas`** — valida HPA scale-up |

> Ver detalle stage-por-stage y garantías de correctness en [docs/pipeline-stages.md](pipeline-stages.md).

### Naming convention del PipelineRun

Tanto el TriggerTemplate (webhook) como el manifest manual usan un nombre **determinístico**:

```
<app-name>-pipelinerun-<image-tag>
```

| Trigger | Nombre del PipelineRun |
|---------|------------------------|
| Webhook: push `release/v1.2.0/dev` desde repo `webserver-api01` | `webserver-api01-pipelinerun-v1.2.0` |
| Manual: `make pipeline-run APP=webserver-api01 TAG=v1.2.0` | `webserver-api01-pipelinerun-v1.2.0` |

Los TaskRuns generados por ese PipelineRun heredan el prefix automáticamente: `webserver-api01-pipelinerun-v1.2.0-clone`, `...-build-push`, `...-bump-gitops`, etc. Los pods de cada TaskRun también: `webserver-api01-pipelinerun-v1.2.0-build-push-pod`.

**Trade-off**: re-pushear el mismo tag falla con `AlreadyExists`. Esto es **intencional** — fuerza disciplina de semver (cada deploy un tag nuevo) y evita que un re-push silencioso sobrescriba el historial del pipeline. Para limpiar:

```bash
kubectl delete pipelinerun webserver-api01-pipelinerun-v1.2.0 -n tekton-pipelines
```

---

## 4. Modelo de promote-rollback (sin plugin)

Comparativa de los tres caminos del Stage 6 según strategy + outcome.

```mermaid
flowchart TB
    START[Stage 5 termina<br/>outcome = passed o failed]

    START --> STRAT{strategy?}

    STRAT -->|bluegreen| BG_O{outcome?}
    STRAT -->|canary| C_O{outcome?}
    STRAT -->|rollingupdate| R_O{outcome?}

    BG_O -->|passed| BG_P["kubectl patch rollout NAME<br/>--subresource=status --type=merge<br/>-p '{\"status\":{\"pauseConditions\":null}}'"]
    BG_O -->|failed| BG_F["kubectl patch rollout NAME<br/>--type=merge<br/>-p '{\"spec\":{\"abort\":true}}'"]

    C_O -->|passed| C_P["kubectl patch rollout NAME<br/>--subresource=status --type=merge<br/>-p '{\"status\":{\"promoteFull\":true}}'"]
    C_O -->|failed| C_F["kubectl patch rollout NAME<br/>--type=merge<br/>-p '{\"spec\":{\"abort\":true}}'"]

    R_O -->|passed| R_P[no-op<br/>RollingUpdate completa solo]
    R_O -->|failed| R_F["kubectl patch rollout NAME<br/>--type=merge<br/>-p '{\"spec\":{\"abort\":true}}'"]

    BG_P --> VERIFY_OK[verifica phase=Healthy<br/>timeout 180s]
    C_P --> VERIFY_OK
    R_P --> VERIFY_OK

    BG_F --> VERIFY_KO[verifica phase=Degraded<br/>timeout 180s]
    C_F --> VERIFY_KO
    R_F --> VERIFY_KO

    VERIFY_OK --> END_OK[Pipeline ✅]
    VERIFY_KO --> END_KO[Pipeline ✅<br/>rollback efectivo]

    classDef patch fill:#fef9c3,stroke:#ca8a04
    classDef ok fill:#dcfce7,stroke:#16a34a
    classDef ko fill:#fee2e2,stroke:#dc2626

    class BG_P,C_P,R_P,BG_F,C_F,R_F patch
    class END_OK,VERIFY_OK ok
    class END_KO,VERIFY_KO ko
```

### Por qué patches directos en lugar del plugin

El plugin `kubectl-argo-rollouts promote` reportaba `rollout 'X' promoted` pero el Rollout volvía a `BlueGreenPause` ~10s después — el switchover no se persistía. Los **mismos patches que el plugin emite internamente** ([código fuente](https://github.com/argoproj/argo-rollouts/blob/master/cmd/kubectl-argo-rollouts/commands/promote.go)) aplicados directo vía `kubectl` sí persisten:

| Acción | Patch | Subresource |
|--------|-------|-------------|
| BG promote | `{"status":{"pauseConditions":null}}` | `status` |
| Canary promote-full | `{"status":{"promoteFull":true}}` | `status` |
| Abort (cualquier strategy) | `{"spec":{"abort":true}}` | (default) |

Ventajas adicionales:
- Sin descarga de binarios externos (~15s ahorrados por run)
- Sin manipular PATH (que rompía `kubectl` en la imagen `bitnami/kubectl`)
- Sin dependencias adicionales en la SA — solo `patch` sobre `rollouts` y `rollouts/status` (que ya tenía)

---

## 5. Estrategias de deployment

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
               outcome=passed → kubectl patch
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
           stable-svc              canary-svc
            (v1.1)                  (v1.2)
               │                       │
              95%        5%    ← step 1 (Paused — k6 corre)
              75%       25%    ← step 2 (Paused — k6 corre)
              50%       50%    ← step 3 (Paused — k6 corre)
               │               outcome=passed → patch promoteFull=true
               └───────────────────────┘
                       100% (v1.2 es stable)
```

### RollingUpdate

```
 Rollout actualiza pods uno a uno (maxSurge 1, maxUnavailable 0).
 Completa directamente → fase Healthy (no Paused).
 Stage 5: k6 smoke.js contra el stable service.
 Stage 6: outcome=failed → patch spec.abort=true; outcome=passed → no-op.
```

---

## 6. Seguridad — PodSecurity Standards

Ver [docs/security-and-rbac.md](security-and-rbac.md) para detalles completos.

| Namespace | Enforce | Razón |
|-----------|---------|-------|
| `tekton-pipelines` | **`baseline`** | Kaniko necesita root para escribir en `/` durante el build de imagen. Baseline permite root pero bloquea hostPath, hostNetwork, privileged, etc. |
| Las 5 Tasks no-kaniko | (en `stepTemplate.securityContext`) compliant con **`restricted`** | Defense in depth: aunque el namespace permita root, los steps de clone/bump/wait/load/promote corren como UID 65532, drop=["ALL"], seccompProfile=RuntimeDefault. |

> **Importante**: si reinstalás Tekton con el `release.yaml` oficial, el label vuelve a `restricted` y kaniko falla con `PodAdmissionFailed`. Re-aplicá `kubectl label namespace tekton-pipelines pod-security.kubernetes.io/enforce=baseline --overwrite`.

---

## 7. Deuda técnica conocida

- **Sin TLS local** — nginx usa HTTP. Para HTTPS local usar cert-manager con self-signed CA o mkcert.
- **GitHub PAT en Secret** — el token de push al repo gitops vive en un `Secret` de Kubernetes. En producción migrar a External Secrets Operator + Vault / AWS Secrets Manager.
- **Single-node statefulls** — Elasticsearch y Prometheus sin HA. Suficiente para POC.
- **Kaniko sin caché persistente** — cada build baja las capas base de nuevo. Agregar `--cache=true` con un registry local (e.g. `registry:2`).
- **Sin análisis de métricas en rollout** — usa pauses manuales/pipeline. Next step: `AnalysisTemplate` con Prometheus.
- **Sin webhook HMAC** — el EventListener no valida la firma. Ver [docs/webhook-setup.md → HMAC](webhook-setup.md#hmac-opcional--validar-origen-del-webhook).
- **Promote-full canary salta steps intermedios** — el patch `promoteFull=true` lleva el canary directo a 100%. Para una demo gradual usar `kubectl argo rollouts promote` por step (sin `--full`).
