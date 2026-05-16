# Pipeline internals

Detalle técnico de cada Task de los pipelines de Tekton y cómo se cablean entre sí. Esta doc complementa el [overview de stages](pipeline-stages.md); se enfoca en **decisiones de diseño no obvias** y comandos exactos.

Hay **dos pipelines** que comparten Tasks:

- `pythonapps-pipeline` (release, 6 stages) — clonado → build → bump → wait → load test → promote
- `pythonapps-burn-pipeline` (HPA capacity, 2 stages, on-demand) — clonado → burn-to-scale

Todos los archivos viven en `charts/pythonapps/templates/pipeline-templates/`.

---

## Stack de imágenes por Task

| Task | Usado por | Image | Usuario | Notas |
|------|-----------|-------|---------|-------|
| `git-clone-app` | release + burn | `alpine/git:latest` | UID 65532 (nonroot) | HOME=/tekton/home para `git config` |
| `kaniko-build-push` | release | `gcr.io/kaniko-project/executor:latest` | **root** (UID 0) | Único Task que necesita root → el NS está en PSA `baseline` |
| `bump-gitops-image` | release | `alpine/git:latest` + `mikefarah/yq:latest` | UID 65532 | 3 steps: clone-gitops, bump-all-envs (yq), commit-and-push |
| `wait-argocd-sync` | release | `bitnami/kubectl:latest` | UID 65532 | 2 steps: wait-argocd, detect-strategy-and-wait-rollout (detecta strategy + modo) |
| `run-load-test` | release | `bitnami/kubectl:latest` + `grafana/k6:latest` | UID 65532 | 2 steps: detect-mode (kubectl), run-k6. Scripts en `loadtest/` del repo de la app |
| `promote-or-rollback` | release | `bitnami/kubectl:latest` | UID 65532 | Legacy: patches directos al Rollout. Enterprise: solo observa phase |
| `run-burn-to-scale` | burn | sidecar `grafana/k6:latest` + step `bitnami/kubectl:latest` | UID 65532 | Sidecar genera carga, step monitorea HPA replicas |

> **Nota PSA**: el namespace `tekton-pipelines` está labeleado `pod-security.kubernetes.io/enforce=baseline` (no `restricted`) porque kaniko no puede correr restricted. Las Tasks no-kaniko declaran su propio `stepTemplate.securityContext` compliant con `restricted` (defense in depth). Ver [security-and-rbac.md](security-and-rbac.md).

---

## 1. `git-clone-app`

**Archivo**: `task-clone.yaml`

**Params**:
| Name | Type | Default | Descripción |
|------|------|---------|-------------|
| `url` | string | — | URL del repo de la app (lo pasa el TriggerBinding desde `body.repository.clone_url`) |
| `revision` | string | `main` | Ref a clonar. El TriggerBinding lo setea a `refs/tags/release/<ver>/<envs>[/loadtest=<bool>]` |

**Workspaces**: `output` (compartido con `kaniko-build-push`).

**Comando real (script)**:
```sh
DEST="$(workspaces.output.path)/src"
git clone --depth 1 "$(params.url)" "$DEST" 2>/dev/null || true
cd "$DEST"
git fetch --depth 1 origin "$(params.revision)" 2>/dev/null || \
  git fetch origin "$(params.revision)"
git checkout "$(params.revision)"
```

**Por qué `--depth 1` + `git fetch` separado**:
- Algunos servidores no permiten `clone --depth 1 --branch <tag-ref>` directamente (especialmente para tag refs con `/` adentro)
- El flujo "clone → fetch tag → checkout" funciona en todos los casos

**Por qué `HOME=/tekton/home`**:
- Por default Alpine corre con HOME=/root
- Como nonroot (UID 65532), git no puede escribir `~/.gitconfig` en /root
- Tekton monta /tekton/home como writable para cualquier UID

---

## 2. `kaniko-build-push`

**Archivo**: `task-build-kaniko.yaml`

**Params**:
| Name | Type | Default | Descripción |
|------|------|---------|-------------|
| `image` | string | — | Imagen destino: `docker.io/<user>/<app>:<tag>` |
| `context` | string | `src` | Subdir del workspace donde está el Dockerfile |

**Workspaces**: `source` (mismo PVC que `output` del clone, montado read-only conceptualmente).

**Volumes**:
- `docker-config` ← secret `dockerhub-credentials` mapeado a `/kaniko/.docker/config.json`

**Comando real**:
```
/kaniko/executor \
  --dockerfile=$(workspaces.source.path)/$(params.context)/Dockerfile \
  --context=$(workspaces.source.path)/$(params.context) \
  --destination=$(params.image) \
  --cache=true \
  --cache-ttl=24h
```

**Por qué corre como root**:
- Kaniko escribe en `/` durante el build (snapshots del rootfs)
- No existe oficial rootless kaniko image
- Tradeoff aceptado: bajar el NS a PSA=baseline (permite root) en lugar de migrar a BuildKit rootless

---

## 3. `bump-gitops-image`

**Archivo**: `task-bump-gitops.yaml`

**Params**:
| Name | Type | Default | Descripción |
|------|------|---------|-------------|
| `gitops-repo-url` | string | — | URL pristine del repo gitops (este repo) |
| `app-name` | string | — | `webserver-api01` etc. |
| `environments` | string | `dev` | Lista comma-separated: `dev`, `dev,staging`, etc. |
| `image-tag` | string | — | Tag a escribir en `image.tag` del values.yaml |
| `git-user-name` | string | `tekton-bot` | Para el commit |
| `git-user-email` | string | `tekton@belo-challenge.dev` | Para el commit |

**Results**:
| Name | Descripción |
|------|-------------|
| `commit-sha` | Full SHA del bump commit (empty string si no hubo cambios) |

**Workspaces**: `gitops` (PVC dedicado, no compartido con clone/build).

**Volumes**:
- `git-token` ← secret `github-token` montado en `/workspace/git-token` read-only

**Steps**:

### Step 3.1 — `clone-gitops`
```sh
TOKEN=$(tr -d '[:space:]' < /workspace/git-token/token)
AUTH_URL=$(echo "$(params.gitops-repo-url)" | \
  sed "s|https://|https://x-access-token:${TOKEN}@|")
git clone "$AUTH_URL" "$(workspaces.gitops.path)/gitops"
```

> `tr -d '[:space:]'` cubre `\n`, `\r`, tab, vertical tab, form feed, espacios. Necesario porque algunos secrets se crean con trailing newline.

### Step 3.2 — `bump-all-envs` (image: `mikefarah/yq`)

```sh
echo "$ENVIRONMENTS" | tr ',' '\n' | while read ENV; do
  VALUES_FILE="$(workspaces.gitops.path)/gitops/charts/pythonapps/apps/${APP_NAME}/${ENV}/values.yaml"
  yq e '.image.tag = strenv(IMAGE_TAG)' -i "$VALUES_FILE"
done
```

> **`strenv(IMAGE_TAG)` no `env(IMAGE_TAG)`**: `strenv` interpreta el valor como string siempre. Sin esto, `v0.4.0` se interpreta como flotante y se serializa como `0.4`.

### Step 3.3 — `commit-and-push`

```sh
TOKEN=$(tr -d '[:space:]' < /workspace/git-token/token)
cd "$(workspaces.gitops.path)/gitops"
git config user.name "tekton-bot"
git config user.email "tekton@belo-challenge.dev"
git add .
if git diff --staged --quiet; then
  echo "Sin cambios que commitear"
  printf "" > "$(results.commit-sha.path)"   # <-- result vacío
  exit 0
fi
git commit -m "bump $(params.app-name) a $(params.image-tag) en [${ENVS_LABEL}]"
# IMPORTANTE: usar params.gitops-repo-url (pristine, sin token) — NO git remote get-url
PUSH_URL=$(echo "$(params.gitops-repo-url)" | \
  sed "s|https://|https://x-access-token:${TOKEN}@|")
git push "$PUSH_URL" main
SHA=$(git rev-parse HEAD)
printf "%s" "$SHA" > "$(results.commit-sha.path)"
```

**Por qué el push URL se construye desde el param y no desde el remote del clone**:

El step `clone-gitops` deja el remote `origin` con el token embebido (`https://x-access-token:TOKEN@github.com/...`). Si `commit-and-push` reusara ese remote y le volviera a inyectar el token, la URL resultante tendría dos `@` y `curl` la rechazaría (`URL rejected: Port number was not a decimal number`). Por eso el push URL se computa desde `$(params.gitops-repo-url)` — la URL pristine del Pipeline param, sin auth — y se le inyecta el token una sola vez.

---

## 4. `wait-argocd-sync`

**Archivo**: `task-wait-argocd.yaml`

**Params**:
| Name | Type | Default | Descripción |
|------|------|---------|-------------|
| `app-name` | string | — | Para construir `${app}-${env}` (= ArgoCD app name = Rollout name = namespace) |
| `environments` | string | `dev` | Toma el primer env como PRIMARY_ENV |
| `timeout-seconds` | string | `600` | Timeout total por step |
| `expected-commit-sha` | string | `""` | Si no-vacío, espera que `app.status.sync.revision == este SHA` |
| `image-tag` | string | `""` | Si no-vacío, espera que `rollout.spec.template.spec.containers[0].image` termine con este tag |

**Results**:
| Name | Descripción |
|------|-------------|
| `primary-env` | Primer env de la lista (`dev` si `environments=dev,staging`) |
| `strategy` | Auto-detectado del live Rollout: `bluegreen`, `canary`, o `rollingupdate` |

**Steps**:

### Step 4.1 — `wait-argocd`

```sh
APP_CR="${APP}-${PRIMARY_ENV}"   # ej: webserver-api01-dev

# Force refresh — sin esto, ArgoCD podría tardar hasta 3min en detectar el commit
if [ -n "$EXPECTED_SHA" ]; then
  kubectl annotate application "$APP_CR" -n argocd \
    argocd.argoproj.io/refresh=normal --overwrite
fi

while [ $ELAPSED -lt $TIMEOUT ]; do
  STATUS=$(kubectl get application "$APP_CR" -n argocd \
    -o jsonpath='{.status.sync.status},{.status.health.status},{.status.sync.revision}')
  SYNC=$(...)
  REVISION=$(...)

  if [ "$SYNC" = "Synced" ]; then
    if [ -z "$EXPECTED_SHA" ] || [ "$REVISION" = "$EXPECTED_SHA" ]; then
      break  # Synced en el commit correcto
    fi
    echo "  (synced pero en revision vieja, esperando $EXPECTED_SHA)"
  fi
  sleep 5
done
```

**Por qué no esperar `health=Healthy`**: BlueGreen/Canary Rollouts reportan `health=Progressing` mientras están `Paused`. Esperar `Healthy` haría timeout siempre en BG/Canary.

### Step 4.2 — `detect-strategy-and-wait-rollout`

Auto-detección de strategy:

```sh
if kubectl get rollout "$ROLLOUT" -n "$NS" \
    -o jsonpath='{.spec.strategy.blueGreen.activeService}' | grep -q .; then
  STRATEGY="bluegreen"
elif kubectl get rollout "$ROLLOUT" -n "$NS" \
    -o jsonpath='{.spec.strategy.canary.steps}' | grep -q .; then
  STRATEGY="canary"
else
  STRATEGY="rollingupdate"
fi
```

Después de detectar la strategy, detecta el **modo** (¿el Rollout tiene `prePromotionAnalysis` / `steps[*].analysis`?) y espera la condición correspondiente:

```sh
while [ $ELAPSED -lt $TIMEOUT ]; do
  PHASE=$(kubectl get rollout ... -o jsonpath='{.status.phase}')
  SPEC_TAG=$(kubectl get rollout ... image | sed 's|.*:||')
  UPDATED=$(kubectl get rollout ... -o jsonpath='{.status.updatedReplicas}')

  [ "$SPEC_TAG" != "$IMAGE_TAG" ] && { sleep 5; continue; }   # spec DEBE reflejar el bump

  case "${STRATEGY}/${MODE}" in
    rollingupdate/*)  [ "$PHASE" = "Healthy" ] && exit 0 ;;
    */legacy)         [ "$PHASE" = "Paused" ]  && exit 0 ;;   # RS nuevo ready esperando promote del pipeline
    */enterprise)     [ "$UPDATED" -ge 1 ]     && exit 0 ;;   # RS nuevo ready; Argo ya corre el AnalysisRun
  esac
  sleep 5
done
```

**Modo legacy — por qué `Paused` y no `Paused OR Healthy`**: si el Rollout ya está `Healthy` con la versión nueva (run previo promovió), no hay green RS para testear. Más limpio fallar fast si la spec aún no refleja el bump.

**Modo enterprise — por qué NO `Paused`**: con `autoPromotionEnabled=true` + análisis, el Rollout no pausa — arranca el `AnalysisRun` apenas el RS nuevo está ready y promueve solo. Esperar `Paused` colgaría el Stage 4. Se espera `updatedReplicas>=1` y el Stage 5 genera tráfico en paralelo con el análisis.

---

## 5. `run-load-test`

**Archivo**: `task-load-test.yaml`

**Params**:
| Name | Type | Default | Descripción |
|------|------|---------|-------------|
| `app-name` | string | — | Para construir endpoints |
| `environments` | string | `dev` | Toma primer env |
| `strategy` | string | `""` | Auto-detectado de wait-argocd |
| `enabled` | string | `"false"` | Derivado del flag `loadtest=true|false` del tag. En modo legacy gobierna si el k6 corre; en modo enterprise se ignora (ver abajo) |

**Results**:
| Name | Descripción |
|------|-------------|
| `outcome` | `passed` o `failed` |

**Workspaces**: `source` (compartido con `git-clone-app`, contiene el repo de la app clonado en Stage 1).

**Steps**: el task tiene **dos steps**:
1. `detect-mode` (`bitnami/kubectl`) — introspecciona el Rollout: ¿tiene `prePromotionAnalysis` (BG) o `steps[*].analysis` (Canary)? Escribe `legacy` o `enterprise` a `$(workspaces.source.path)/.rollout-mode`.
2. `run-k6` (`grafana/k6`) — lee `.rollout-mode` y decide.

### Doble rol del k6 según el modo

- **Modo LEGACY**: el k6 **valida**. Si `enabled != "true"` (flag `loadtest` no presente), skipea k6 y emite `outcome=passed`. Si `enabled == "true"`, corre k6 y el `outcome` refleja los thresholds.
- **Modo ENTERPRISE**: el k6 **genera tráfico** para el `AnalysisRun` de Argo Rollouts. Corre **siempre** — el script fuerza `enabled=true` ignorando el flag del tag, porque sin tráfico las queries Prometheus dan `NaN` y el Rollout queda `Degraded`. El `outcome` que emite es irrelevante (el Stage 6 enterprise no lo mira).

### Source of truth de los scripts k6

Los scripts viven en el **repo de la app** (e.g. `github.com/Valentino-33/webserver-api01`), en el directorio `loadtest/` de la raíz:

```
webserver-api01/        (repo de GitHub)
├── Dockerfile
├── app/
├── loadtest/           ← ACÁ
│   ├── smoke.js
│   └── load-bluegreen.js
└── pyproject.toml
```

Cuando Stage 1 (`git-clone-app`) cloneó el repo a `/workspace/source/src/`, el directorio `loadtest/` quedó en `/workspace/source/src/loadtest/`. El task lo lee desde ahí:

```sh
SCRIPT_PATH="$(workspaces.source.path)/src/loadtest/$SCRIPT"
```

> **Importante**: el `src/` en el path es solo el `$DEST` del clone (`git clone <repo> /workspace/source/src`), **no** un subdirectorio dentro del repo de la app. El repo se clona "como está" bajo ese directorio.

| Strategy detectada | Script esperado en `loadtest/` |
|--------------------|--------------------------------|
| `bluegreen` | `load-bluegreen.js` |
| `canary` | `load-canary.js` |
| `rollingupdate` o desconocida | `smoke.js` |

Selección de script y URL según strategy:

```sh
BASE_URL="http://${RELEASE}-stable.${NS}.svc.cluster.local:8080"
PREVIEW_URL="http://${RELEASE}-preview.${NS}.svc.cluster.local:8080"

case "$STRATEGY" in
  bluegreen)
    SCRIPT="load-bluegreen.js"
    EXTRA="-e PREVIEW_URL=$PREVIEW_URL"
    ;;
  canary)
    SCRIPT="load-canary.js"
    EXTRA="-e BASE_URL=$BASE_URL"
    ;;
  *)
    SCRIPT="smoke.js"
    EXTRA="-e BASE_URL=$BASE_URL"
    ;;
esac

k6 run $EXTRA "$(workspaces.source.path)/src/loadtest/$SCRIPT"
OUTCOME=$?

printf "%s" "$([ $OUTCOME -eq 0 ] && echo passed || echo failed)" > "$(results.outcome.path)"
```

**Fail fast si el script no existe**: el step termina con `exit 1` y `outcome=failed`. Comportamiento intencional: una strategy sin su script correspondiente (e.g. el chart se cambió a `canary` pero el repo de la app no tiene `loadtest/load-canary.js`) debe romper el pipeline ruidosamente, no reportar verde silencioso.

**Si el script existe, siempre exits 0** después de correr k6: si k6 falla los thresholds, el step sigue y emite `outcome=failed`. Eso permite al Stage 6 ver el outcome y decidir promote vs abort.

---

## 6. `promote-or-rollback`

**Archivo**: `task-promote-rollback.yaml`

**Params**:
| Name | Type | Default | Descripción |
|------|------|---------|-------------|
| `app-name` | string | — | |
| `environments` | string | `dev` | |
| `strategy` | string | `""` | Bluegreen, canary, o rollingupdate |
| `outcome` | string | `passed` | Del result de load-test (solo se usa en modo legacy) |
| `enterprise-timeout` | string | `"600"` | Timeout (s) para esperar fase terminal en modo enterprise — un canary multi-step puede tardar |

**Detección de modo**: el script arranca introspeccionando el Rollout. Si BG tiene `prePromotionAnalysis` o Canary tiene `steps[*].analysis` → `MODE=enterprise`, si no → `MODE=legacy`. No requiere params extra del pipeline.

### Modo ENTERPRISE — solo observa

Argo Rollouts ya está ejecutando los `AnalysisRun` (pre/post en BG, uno por step en canary) y decide promote/abort. El task hace `wait_terminal` — poll cada 10s hasta `phase=Healthy` (exit 0) o `phase=Degraded` (exit 1, e imprime los `AnalysisRun` fallidos via `kubectl get analysisrun`). No patchea nada.

### Modo LEGACY — patchea según `outcome`

**Producción gate**: si `PRIMARY_ENV=production`, NO promueve — solo annotates la ArgoCD app y exit OK. Requiere intervención manual para promover prod.

**Comandos por estrategia** (todos vía `kubectl patch`, sin plugin):

```sh
wait_phase() {
  EXPECTED="$1"
  while [ $ELAPSED -lt 180 ]; do
    PHASE=$(kubectl get rollout "$ROLLOUT" -n "$NS" -o jsonpath='{.status.phase}')
    [ "$PHASE" = "$EXPECTED" ] && return 0
    sleep 5
  done
  return 1
}

case "$STRATEGY" in
  bluegreen)
    if [ "$OUTCOME" = "failed" ]; then
      kubectl patch rollout "$ROLLOUT" -n "$NS" --type=merge \
        -p '{"spec":{"abort":true}}'
      wait_phase "Degraded" || exit 1
    else
      kubectl patch rollout "$ROLLOUT" -n "$NS" \
        --subresource=status --type=merge \
        -p '{"status":{"pauseConditions":null}}'
      wait_phase "Healthy" || exit 1
    fi
    ;;
  canary)
    if [ "$OUTCOME" = "failed" ]; then
      kubectl patch rollout "$ROLLOUT" -n "$NS" --type=merge \
        -p '{"spec":{"abort":true}}'
      wait_phase "Degraded" || exit 1
    else
      kubectl patch rollout "$ROLLOUT" -n "$NS" \
        --subresource=status --type=merge \
        -p '{"status":{"promoteFull":true}}'
      wait_phase "Healthy" || exit 1
    fi
    ;;
  rollingupdate)
    if [ "$OUTCOME" = "failed" ]; then
      kubectl patch rollout "$ROLLOUT" -n "$NS" --type=merge \
        -p '{"spec":{"abort":true}}'
      wait_phase "Degraded" || exit 1
    else
      wait_phase "Healthy" || exit 1
    fi
    ;;
esac
```

**Por qué `kubectl patch` directo y no el plugin `kubectl argo rollouts promote`**:

El task aplica directamente al status subresource los mismos patches que el plugin emite internamente (según [`promote.go` del repo argo-rollouts](https://github.com/argoproj/argo-rollouts/blob/master/cmd/kubectl-argo-rollouts/commands/promote.go)). Ventajas:
- Sin descarga de binarios externos en runtime (~15s más rápido por run)
- Sin override del `PATH` de la imagen `bitnami/kubectl` (cuya bin vive en `/opt/bitnami/kubectl/bin`)
- Menos superficie de fallo y RBAC mínimo

---

## 7. `AnalysisTemplate` (modo enterprise)

**Archivo**: `charts/pythonapps/templates/analysis-template.yaml` — NO es una Task de Tekton, es un recurso de Argo Rollouts que el chart genera cuando `analysis.enabled: true`. Lo aplica ArgoCD junto al Rollout, no `make tekton-apply`.

**Args** (inyectados por el Rollout en cada `AnalysisRun`):
| Name | Valor en BG | Valor en Canary |
|------|-------------|-----------------|
| `service` | `<release>-preview` (prePromotion) / `<release>-stable` (postPromotion) | `<release>-preview` (steps 5/25/50) / `<release>-stable` (step 100) |
| `namespace` | `<app>-<env>` | `<app>-<env>` |

**Metrics** (ambas deben pasar — son ortogonales):

```yaml
- name: success-rate
  successCondition: result[0] >= 0.99       # 99% de requests sin 5xx
  query: |
    sum(rate(<prefix>_requests_total{namespace="{{args.namespace}}",service="{{args.service}}",status_code!~"5.."}[1m]))
    / (sum(rate(<prefix>_requests_total{namespace="{{args.namespace}}",service="{{args.service}}"}[1m])) > 0)
- name: latency-p95
  successCondition: result[0] < 1.0         # p95 < 1 segundo
  query: |
    histogram_quantile(0.95, sum(rate(<prefix>_request_duration_seconds_bucket{namespace="{{args.namespace}}",service="{{args.service}}"}[1m])) by (le))
```

- `<prefix>` lo interpola Helm desde `analysis.metricPrefix` (`api01`, `api02`). `{{args.*}}` lo interpola Argo Rollouts en runtime (escapado en el template con `` {{`{{args.x}}`}} ``).
- El `> 0` en el denominador de success-rate evita división por cero: sin tráfico el query da `NaN`, la condición falla, el Rollout queda `Degraded`. Es intencional — no se promueve algo que no se puede medir.

**Timing** (configurable desde `values.yaml`, calibrado para caber en la ventana del k6 del Stage 5):
| Param | Default | Rol |
|-------|---------|-----|
| `initialDelay` | `60s` | margen para que el Stage 5 levante el k6 (scheduling + image pull + ramp) antes del primer sample |
| `interval` | `15s` | entre samples |
| `count` | `2` | samples antes de declarar success — `60s + 2*15s ≈ 90s` por análisis |
| `failureLimit` | `1` | samples FAILED tolerados antes de abortar |
| `successRateThreshold` | `0.99` | umbral de la metric success-rate |
| `latencyP95Seconds` | `1.0` | umbral de la metric latency-p95 |

**Dónde lo referencia el Rollout**:
- BG → `spec.strategy.blueGreen.prePromotionAnalysis` + `postPromotionAnalysis`
- Canary → `spec.strategy.canary.steps[*].analysis` (uno tras cada `setWeight`, incluido el `100`). Canary **no** tiene `pre/postPromotionAnalysis` top-level — es exclusivo de BG.

---

## Cableado del Pipeline

**Archivo**: `pipeline-pythonapps.yaml`

```yaml
spec:
  params:
  - name: repo-url
  - name: revision
  - name: app-name
  - name: image-tag
  - name: image-full
  - name: environments
  - name: gitops-repo-url
  workspaces:
  - name: source
  - name: gitops
  tasks:
  - name: clone
    taskRef: { name: git-clone-app }
    workspaces: [{ name: output, workspace: source }]
    params:
    - { name: url, value: $(params.repo-url) }
    - { name: revision, value: $(params.revision) }

  - name: build-push
    taskRef: { name: kaniko-build-push }
    runAfter: [clone]
    workspaces: [{ name: source, workspace: source }]
    params:
    - { name: image, value: $(params.image-full) }
    - { name: context, value: src }

  - name: bump-gitops
    taskRef: { name: bump-gitops-image }
    runAfter: [build-push]
    workspaces: [{ name: gitops, workspace: gitops }]
    params:
    - { name: gitops-repo-url, value: $(params.gitops-repo-url) }
    - { name: app-name, value: $(params.app-name) }
    - { name: environments, value: $(params.environments) }
    - { name: image-tag, value: $(params.image-tag) }

  - name: wait-argocd
    taskRef: { name: wait-argocd-sync }
    runAfter: [bump-gitops]
    params:
    - { name: app-name, value: $(params.app-name) }
    - { name: environments, value: $(params.environments) }
    - { name: expected-commit-sha, value: $(tasks.bump-gitops.results.commit-sha) }
    - { name: image-tag, value: $(params.image-tag) }

  - name: load-test
    taskRef: { name: run-load-test }
    runAfter: [wait-argocd]
    workspaces: [{ name: source, workspace: source }]
    params:
    - { name: app-name, value: $(params.app-name) }
    - { name: environments, value: $(params.environments) }
    - { name: strategy, value: $(tasks.wait-argocd.results.strategy) }

  - name: promote-rollback
    taskRef: { name: promote-or-rollback }
    runAfter: [load-test]
    params:
    - { name: app-name, value: $(params.app-name) }
    - { name: environments, value: $(params.environments) }
    - { name: strategy, value: $(tasks.wait-argocd.results.strategy) }
    - { name: outcome, value: $(tasks.load-test.results.outcome) }
```

**Flujo de results entre Tasks**:

```
bump-gitops.results.commit-sha    ──→  wait-argocd.params.expected-commit-sha
params.image-tag                  ──→  wait-argocd.params.image-tag
wait-argocd.results.strategy      ──→  load-test.params.strategy
                                  ──→  promote-rollback.params.strategy
wait-argocd.results.primary-env   ──→  (no usado por otra task, queda como referencia)
load-test.results.outcome         ──→  promote-rollback.params.outcome
```

---

## Triggers (webhook → PipelineRun)

### EventListener (`event-listener.yaml`)

```yaml
spec:
  serviceAccountName: tekton-triggers-sa
  triggers:
  - name: github-tag-push
    interceptors:
    - ref: { name: cel, kind: ClusterInterceptor }
      params:
      - name: filter
        value: "header.match('X-Github-Event', 'push') && body.ref.startsWith('refs/tags/release/') && body.ref.split('/').size() >= 4 && body.ref.split('/').size() <= 6"
      - name: overlays
        value:
        - key: image_tag
          expression: "body.ref.split('/')[3]"
        - key: environments
          expression: "body.ref.split('/').size() > 4 ? body.ref.split('/')[4] : 'dev'"
        - key: run_load_test
          # 5º segmento opcional. Default 'false' fail-closed: cualquier string distinta
          # de exactamente "loadtest=true" → 'false'. Para activar k6 hay que ser explícito.
          expression: "body.ref.split('/').size() > 5 && body.ref.split('/')[5] == 'loadtest=true' ? 'true' : 'false'"
        - key: git_revision
          expression: "body.ref"
    bindings:
    - ref: github-tag-binding
    template:
      ref: pythonapps-trigger-template
```

### TriggerBinding (`trigger-binding.yaml`)

Extrae values del payload de GitHub:

```yaml
spec:
  params:
  - { name: repo-url, value: $(body.repository.clone_url) }
  - { name: app-name, value: $(body.repository.name) }        # ← debe coincidir con app-name ArgoCD
  - { name: image-tag, value: $(extensions.image_tag) }       # ← del CEL overlay
  - { name: environments, value: $(extensions.environments) } # ← del CEL overlay
  - { name: run-load-test, value: $(extensions.run_load_test) } # ← del CEL overlay (true/false)
  - { name: revision, value: $(extensions.git_revision) }     # ← refs/tags/release/...
```

### TriggerTemplate (`trigger-template.yaml`)

Convierte params en un `PipelineRun`. Setea SA, tolerations, nodeSelector (`role=cicd`), workspaces (PVCs efímeros con `volumeClaimTemplate`), y computa `image-full` = `docker.io/<user>/<app>:<tag>`.

**Nombre del PipelineRun (determinístico):**

```yaml
metadata:
  name: $(tt.params.app-name)-pipelinerun-$(tt.params.image-tag)
  namespace: tekton-pipelines
```

Pattern: `<app>-pipelinerun-<image-tag>`. Por ejemplo:
- Push `release/v1.2.0/dev` desde repo `webserver-api01` → run llamado `webserver-api01-pipelinerun-v1.2.0`
- Push `release/v2.0.0/dev,staging` desde repo `webserver-api02` → run llamado `webserver-api02-pipelinerun-v2.0.0`

Los TaskRuns derivados heredan el prefix:
- `webserver-api01-pipelinerun-v1.2.0-clone`
- `webserver-api01-pipelinerun-v1.2.0-build-push`
- `webserver-api01-pipelinerun-v1.2.0-bump-gitops`
- ...y los pods: `webserver-api01-pipelinerun-v1.2.0-build-push-pod`

**Por qué `name` y no `generateName`**:

| Aspecto | `generateName: <prefix>-` | `name: <full-name>` |
|---------|---------------------------|---------------------|
| Unicidad | sufijo random (5 chars) | dependiente del param `image-tag` |
| Identificación visual | `webserver-api01-run-rh9hq` (¿qué deploy era?) | `webserver-api01-pipelinerun-v1.2.0` (claro) |
| Re-push del mismo tag | crea otro run con sufijo distinto (potencialmente confuso) | falla con `AlreadyExists` (intencional — forzar semver nuevo) |
| `kubectl get pipelinerun` | orden cronológico, agrupado por prefix | igual + tag visible |

**Limpieza para re-correr un mismo tag**:

```bash
kubectl delete pipelinerun webserver-api01-pipelinerun-v1.2.0 -n tekton-pipelines
# luego re-pushear el tag (o re-correr make pipeline-run con el mismo TAG)
```

> El mismo formato lo usa `manifests/tekton/pipelinerun-manual.yaml` (flujo manual sin webhook), con `name: ${APP}-pipelinerun-${TAG}`. El Makefile usa `kubectl create -f -` (no `apply`) — con `name` fijo, `create` falla limpio si ya existe.

---

## ServiceAccounts y RBAC

Ver [security-and-rbac.md](security-and-rbac.md) para detalles.

Resumen:
- `tekton-triggers-sa` — la usa el EventListener para crear PipelineRuns
- `tekton-pipeline-runner` — la usa cada PipelineRun pod. Permisos:
  - `argoproj.io/rollouts` y `rollouts/status`: `get, list, watch, update, patch` (para promote/abort)
  - `argoproj.io/applications`: `get, list, watch, patch, update` (`patch` para el refresh annotation)
  - `argoproj.io/analysisruns, analysistemplates`: `get, list, watch` (modo enterprise — el Stage 6 lee los `AnalysisRun` para reportar cuál falló; la creación la hace el controller de Argo Rollouts)
  - `apps/deployments`: `get, list, watch, patch` (legacy)
  - `autoscaling/horizontalpodautoscalers`: `get, list, watch` (burn pipeline)
