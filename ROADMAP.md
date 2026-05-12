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

### Fase 5 — CI/CD Pipeline (6 stages)
- [x] Stage 1: `git-clone-app` — clone exacto en la ref del tag
- [x] Stage 2: `kaniko-build-push` — build sin Docker daemon + push a Docker Hub
- [x] Stage 3: `bump-gitops-image` — actualiza `image.tag` via yq + git push autenticado
- [x] Stage 4: `wait-argocd-sync` — poll hasta Synced y Rollout Paused/Healthy
- [x] Stage 5: `run-load-test` — k6 in-cluster, siempre exits 0, emite result `outcome`
- [x] Stage 6: `promote-rollback` — actúa sobre `outcome`: promote o abort según strategy

### Fase 6 — Triggers automáticos
- [x] EventListener con CEL interceptor (filtro: `refs/tags/release/<sha>/<envs>`)
- [x] TriggerBinding — extrae repo-url, app-name, image-tag, environments, revision
- [x] TriggerTemplate — genera PipelineRun con SA, tolerations y computed URLs
- [x] Ingress `tekton-webhook.localhost` para recibir webhooks de GitHub
- [x] RBAC mínimo: SA `tekton-triggers-sa` (crear/listar PipelineRuns) + SA `tekton-pipeline-runner` (Rollouts + Applications)

### Fase 7 — GitOps (apps-of-apps)
- [x] ArgoCD apps-of-apps (bootstrap desde este repo)
- [x] Application CRs por app (api01, api02) en namespaces dedicados `<app>-<env>`
- [x] Auto-sync con selfHeal y prune
- [x] bump-gitops actualiza `image.tag` → ArgoCD redespliega el Rollout

### Fase 8 — Load testing completo
- [x] `smoke.js` para api01 y api02 (baseline health + latencia)
- [x] `load-bluegreen.js` para api01 y api02 (contra preview service)
- [x] `load-canary.js` para api01 y api02 (contra stable con canary activo)

### Fase 9 — Documentación
- [x] `docs/architecture.md` — diagramas Mermaid de topología, componentes, flujo CI/CD profesional y modelo de promote-rollback
- [x] `docs/pipeline-internals.md` — detalle técnico de cada Task del pipeline
- [x] `docs/security-and-rbac.md` — PodSecurity Standards, securityContext, ClusterRoles
- [x] `docs/troubleshooting.md` — gotchas detallados con causa raíz y fix
- [x] `docs/demo-guide.md` — guía paso a paso para cada estrategia
- [x] `docs/webhook-setup.md` — configuración de webhook GitHub → Tekton (ngrok, smee, HMAC)
- [x] `README.md` — entregable final profesional con quick start completo
- [x] `MAKEFILE_GUIDE.md` — referencia de todos los targets y variables

### Fase 10 — Hardening profesional del pipeline (nuevo)

Esta fase resolvió todos los problemas que aparecieron al intentar validar el flujo end-to-end completo. Cada uno tiene su writeup detallado en `docs/troubleshooting.md`.

- [x] **PodSecurity Admission resuelto** — namespace `tekton-pipelines` en `enforce=baseline` (necesario para kaniko que requiere root). Las 5 Tasks no-kaniko declaran su propio `stepTemplate.securityContext` compliant con `restricted` (defense in depth).
- [x] **Tasks corren como nonroot (UID 65532)** — clone, bump, wait, load-test, promote. `HOME=/tekton/home` para permitir git config y similares.
- [x] **Token-en-URL doble fix** — `task-bump-gitops` ahora computa la push URL desde `$(params.gitops-repo-url)` (pristine) en vez de `git remote get-url origin` (que tiene token embebido del clone). Soluciona el `URL rejected: Port number was not a decimal number`.
- [x] **Token whitespace normalization** — `TOKEN=$(tr -d '[:space:]' < ...)` cubre todos los whitespace (no solo `\n\r`).
- [x] **Plugin promote → kubectl patch directo** — eliminado el download del plugin `kubectl-argo-rollouts`; el `promote-or-rollback` Task usa los mismos patches que el plugin emite internamente (`status.pauseConditions=null` para BG, `status.promoteFull=true` para canary, `spec.abort=true` para abort). Persistente, sin descarga externa, ~15s más rápido por run.
- [x] **PATH override scoped** — el override de `PATH` para `$HOME/bin` está solo dentro del script que lo necesita (no en el `stepTemplate` global). Esto era el bug que rompía `kubectl` en la imagen `bitnami/kubectl` (cuya bin vive en `/opt/bitnami/kubectl/bin`).
- [x] **Race condition ArgoCD ↔ Pipeline resuelto** — el bug más sutil. La fix:
  - `task-bump-gitops` emite el SHA del commit como Task result `commit-sha`
  - `task-wait-argocd` recibe ese SHA como param y hace `kubectl annotate app ... argocd.argoproj.io/refresh=normal` para forzar polling inmediato de ArgoCD (sin esperar 3min default)
  - El step espera `.status.sync.revision == commit-sha` (no cualquier "Synced" viejo)
  - Step 2 además verifica que el Rollout spec ya tenga el `image-tag` esperado Y `phase=Paused` (BG/Canary)
- [x] **wait-argocd no espera Healthy** — un Rollout BG/Canary Paused reporta `health=Progressing` (nunca llega a Healthy hasta el promote). El step ahora solo espera `Sync=Synced` y el commit correcto, no Health.
- [x] **wait-argocd espera Paused (no Paused-OR-Healthy)** — para BG/Canary, requerir `Paused` específicamente evita que el step exit OK sobre un Rollout `Healthy` stale (de un deploy previo).
- [x] **Verificación en promote-rollback** — después de patchear, espera y verifica `phase=Healthy` (passed) o `phase=Degraded` (failed) con timeout 180s. Falla ruidosamente si no transitiona.
- [x] **Permiso `patch` sobre `applications`** — la SA `tekton-pipeline-runner` necesita patch para el refresh annotation. Agregado al ClusterRole.
- [x] **Makefile fixes**:
  - `pipeline-run` usa `kubectl create -f -` (no `apply` — necesario para `generateName`)
  - `tunnel` usa `ngrok http --host-header=tekton-webhook.localhost 8888`
  - `manifests/tekton/pipelinerun-manual.yaml` moviendo `podTemplate` bajo `taskRunTemplate` (Tekton v1 strict decoding)

### Fase 11 — Visualización tipo OpenShift Pipelines (nuevo)
- [x] **Tekton Dashboard** instalado y expuesto en `tekton.localhost:8888`
- [x] Ingress dedicado en `manifests/tekton/dashboard-ingress.yaml`
- [x] Tree/DAG view de las 6 stages con logs streaming por step — equivalente a la sección "Pipelines / PipelineRuns" de OpenShift Console (que es Tekton bajo el capó)

### Fase 12 — Naming determinístico de PipelineRuns (nuevo)
- [x] **TriggerTemplate** ahora usa `metadata.name: $(tt.params.app-name)-pipelinerun-$(tt.params.image-tag)` (en lugar de `generateName: <app>-run-`)
- [x] **PipelineRun manual** (`manifests/tekton/pipelinerun-manual.yaml`) usa el mismo patrón: `name: ${APP}-pipelinerun-${TAG}`
- [x] TaskRuns y pods derivados **heredan el prefix automáticamente**: `webserver-api01-pipelinerun-v1.2.0-build-push`, `...-build-push-pod`, etc.
- [x] Re-pushear el mismo tag falla con `AlreadyExists` — comportamiento intencional para forzar disciplina de semver
- [x] Identificación visual instantánea en `kubectl get pipelinerun`, en el Tekton Dashboard, en logs y events — el deploy correspondiente a cada run es obvio sin necesidad de inspeccionar params

### Fase 13 — Source-of-truth de loadtest scripts + fail-fast (nuevo)
- [x] **Eliminado** `belo-infrabase-k3d/apps/<app>/loadtest/` (era una copia inerte que el pipeline NO usaba — solo confundía)
- [x] Los scripts k6 ahora viven **únicamente en el repo de cada app** (`loadtest/` en la raíz del repo)
- [x] **`make load-test-*` actualizado** para clonar el repo de la app a `/tmp/belo-loadtest/` y correr k6 desde ahí. Override-able vía `APP_REPO_BASE` (default `https://github.com/Valentino-33`)
- [x] **task-load-test ahora hace fail-fast**: si el script para la strategy auto-detectada no existe en el repo de la app, emite `outcome=failed` + `exit 1`. Antes silenciosamente emitía `outcome=passed` — un rollout podía promoverse sin haber sido testeado.
- [x] **Fallback URLs corregidas** en los .js de los repos de las apps:
  - Antes: `webserver-api0X-stable.apps.svc.cluster.local:8000` (namespace y puerto incorrectos)
  - Ahora: `webserver-api0X-dev-stable.webserver-api0X-dev.svc.cluster.local:8080`
  - Esto solo afecta corridas locales sin env var; el pipeline siempre pasa la URL correcta via `-e BASE_URL=...`
- [x] **Contrato documentado** en README, pipeline-internals, architecture, demo-guide, y troubleshooting: cada `rollout.strategy` necesita su script correspondiente en `loadtest/`

---

## Validación end-to-end

**Run referencia** (PipelineRun `webserver-api01-pipelinerun-v0.4.7`) — desde `git push tag` hasta nueva versión sirviendo 100% del tráfico:

| Stage | Tiempo | Resultado |
|-------|--------|-----------|
| 1. clone | 10s | ✓ |
| 2. build-push (kaniko) | 31s | ✓ imagen pusheada a Docker Hub |
| 3. bump-gitops | 11s | ✓ commit pusheado + result `commit-sha` |
| 4. wait-argocd | 23s | ✓ refresh + esperó commit + esperó `phase=Paused` con image-tag |
| 5. load-test (k6) | 68s | ✓ outcome=passed |
| 6. promote-rollback | 11s | ✓ patch status + esperó `phase=Healthy` |
| **Total** | **2m 34s** | **Rollout active=stable=v0.4.7, RS viejo scaled down a 0** |

> Run subsiguiente (`webserver-api01-pipelinerun-v0.4.8`) — con la nueva naming convention y kaniko cache caliente — tomó solo **~13s** end-to-end. La fase de kaniko se acelera drásticamente cuando las capas base ya están cacheadas en el registry remoto.

---

## Deuda técnica conocida

Vale más documentarla que esconderla:

| Ítem | Descripción | Prioridad para producción |
|------|-------------|--------------------------|
| **Sin TLS local** | nginx usa HTTP plano. Para HTTPS se puede usar cert-manager + mkcert | Media |
| **GitHub PAT en Secret** | El token de push gitops vive en K8s Secret. Migrar a External Secrets Operator + Vault | Alta |
| **Kaniko sin caché persistente** | Cada build descarga las capas base. Agregar `--cache=true` + registry local | Baja |
| **Single-node statefulls** | Elasticsearch y Prometheus sin HA. Para producción: replicas + anti-affinity | Media |
| **Sin AnalysisTemplate** | Los Rollouts usan pauses + pipeline para decisión. Automatizar con Prometheus AnalysisTemplate | Media |
| **Sin imagen base hardened** | Las apps usan `python:3.12-slim`. Para producción: imagen distroless o Chainguard | Media |
| **Sin multi-namespace pipeline trigger** | El bump solo escribe al primer env de la lista. Para multi-env real (e.g., `dev,staging`) habría que crear N PipelineRuns o N branches en el bump | Media |
| **Sin webhook HMAC** | El EventListener no valida la firma HMAC del webhook de GitHub. Documentado en webhook-setup.md | Media |
| **Sin NetworkPolicies** | El namespace `tekton-pipelines` puede hablar con cualquiera. Para producción: egress restringido a github.com, docker.io, argocd | Media |
| **Sin image signing** | Las imágenes no se firman ni se verifican con cosign/notary | Media |
| **Canary `--full` salta steps intermedios** | El patch `promoteFull=true` lleva el canary directo a 100% si k6 pasa. Para una demo gradual usar `kubectl argo rollouts promote` por step (sin `--full`) — o cambiar el Stage 6 para promote step-by-step esperando análisis | Baja |

---

## Stack de tecnologías

| Capa | Tecnología | Versión |
|------|-----------|---------|
| Kubernetes local | k3d (k3s en Docker) | v5.6+ |
| Deployment strategies | Argo Rollouts | latest |
| GitOps | ArgoCD | latest (helm chart argo/argo-cd) |
| CI/CD | Tekton Pipelines + Triggers | latest release |
| **CI/CD UI** | **Tekton Dashboard** | latest release |
| Build | Kaniko | gcr.io/kaniko-project/executor:latest |
| Ingress | nginx-ingress | kubernetes.github.io/ingress-nginx |
| Logging | EFK (Elasticsearch + Fluent-bit + Kibana) | elastic/elastic (helm) |
| Monitoring | kube-prometheus-stack | prometheus-community (helm) |
| Dashboard general | Headlamp | kubernetes-sigs/headlamp (helm) |
| Load testing | k6 | grafana/k6:latest |
| Apps | Python FastAPI + structlog + prometheus-client | Python 3.12 |
| Packaging | Helm (chart maestro `pythonapps`) | v3.14+ |
| Storage | local-path provisioner | nativo k3s |
| Tunnel para webhook | ngrok | **≥ 3.20.0** (requisito de cuenta free) |
