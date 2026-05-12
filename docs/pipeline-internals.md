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
| `wait-argocd-sync` | release | `bitnami/kubectl:latest` | UID 65532 | 2 steps: wait-argocd, detect-strategy-and-wait-rollout |
| `run-load-test` | release | `grafana/k6:latest` | UID 65532 | Llama scripts en `loadtest/` del repo de la app |
| `promote-or-rollback` | release | `bitnami/kubectl:latest` | UID 65532 | Patches directos al Rollout (sin plugin) |
| `run-burn-to-scale` | burn | sidecar `grafana/k6:latest` + step `bitnami/kubectl:latest` | UID 65532 | Sidecar genera carga, step monitorea HPA replicas |

> **Nota PSA**: el namespace `tekton-pipelines` está labeleado `pod-security.kubernetes.io/enforce=baseline` (no `restricted`) porque kaniko no puede correr restricted. Las Tasks no-kaniko declaran su propio `stepTemplate.securityContext` compliant con `restricted` (defense in depth). Ver [security-and-rbac.md](security-and-rbac.md).

---

## 1. `git-clone-app`

**Archivo**: `task-clone.yaml`

**Params**:
| Name | Type | Default | Descripción |
|------|------|---------|-------------|
| `url` | string | — | URL del repo de la app (lo pasa el TriggerBinding desde `body.repository.clone_url`) |
| `revision` | string | `main` | Ref a clonar. El TriggerBinding lo setea a `refs/tags/release/<sha>/<envs>` |

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

**Bug fixed: token doble en URL del remote**:

El step `clone-gitops` clona con `https://x-access-token:TOKEN@github.com/...` como URL del remote `origin`. La versión anterior del `commit-and-push` hacía:

```sh
# ANTERIOR (roto):
AUTH_URL=$(git remote get-url origin | sed "s|https://|https://x-access-token:${TOKEN}@|")
```

Eso produce `https://x-access-token:NEW@x-access-token:OLD@github.com/...` — dos `@`. curl parsea el **primer** `@` como fin de userinfo, entonces interpreta `x-access-token` como host y `OLD@github.com/...` como port → falla con `URL rejected: Port number was not a decimal number`.

Fix: construir el push URL desde `$(params.gitops-repo-url)` (que es la URL pristine del Pipeline param, sin auth).

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

# 🔑 Force refresh — sin esto, ArgoCD podría tardar hasta 3min en detectar el commit
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
      break  # ✅ Synced en el commit correcto
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

Espera del Rollout:

```sh
while [ $ELAPSED -lt $TIMEOUT ]; do
  PHASE=$(kubectl get rollout ... -o jsonpath='{.status.phase}')
  SPEC_TAG=$(kubectl get rollout ... \
    -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's|.*:||')

  # 🔑 La spec del Rollout DEBE reflejar el nuevo image-tag.
  if [ -n "$IMAGE_TAG" ] && [ "$SPEC_TAG" != "$IMAGE_TAG" ]; then
    sleep 5; continue
  fi

  case "$STRATEGY" in
    rollingupdate)
      [ "$PHASE" = "Healthy" ] && exit 0
      ;;
    bluegreen|canary)
      # Para BG/Canary requerimos Paused — green/canary RS ready esperando promote.
      # Healthy aquí sería estado stale de un deploy previo.
      [ "$PHASE" = "Paused" ] && exit 0
      ;;
  esac
  sleep 5
done
```

**Por qué `Paused` y no `Paused OR Healthy`**: si el Rollout ya está `Healthy` con la versión nueva (porque un run previo promovió), entonces no hay green RS para testear. Tomar el Stage 5 desde ahí correría load test contra el active (ya promovido) — válido pero confuso. Más limpio fallar fast si la spec aún no refleja el bump.

---

## 5. `run-load-test`

**Archivo**: `task-load-test.yaml`

**Params**:
| Name | Type | Default | Descripción |
|------|------|---------|-------------|
| `app-name` | string | — | Para construir endpoints |
| `environments` | string | `dev` | Toma primer env |
| `strategy` | string | `""` | Auto-detectado de wait-argocd |

**Results**:
| Name | Descripción |
|------|-------------|
| `outcome` | `passed` o `failed` |

**Workspaces**: `source` (compartido con `git-clone-app`, contiene el repo de la app clonado en Stage 1).

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
| `outcome` | string | `passed` | Del result de load-test |

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

**Por qué no usar el plugin `kubectl argo rollouts promote`**:

El plugin reportaba `rollout 'X' promoted` y exit 0, pero el Rollout volvía a `BlueGreenPause` ~10s después. Causa exacta no aislada (posiblemente race con ArgoCD reaplicando el spec; posiblemente el plugin patcheaba un campo distinto al subresource correcto).

Los patches directos al status subresource son los mismos que el plugin emite internamente (según [`promote.go` del repo argo-rollouts](https://github.com/argoproj/argo-rollouts/blob/master/cmd/kubectl-argo-rollouts/commands/promote.go)) y persisten correctamente.

Ventajas:
- Sin descarga de binarios externos (~15s ahorrados por run)
- Sin override del `PATH` (que rompía `kubectl` en la imagen `bitnami/kubectl` cuya bin está en `/opt/bitnami/kubectl/bin`)
- Menos superficie de fallo

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
    - { name: expected-commit-sha, value: $(tasks.bump-gitops.results.commit-sha) }  # 🔑
    - { name: image-tag, value: $(params.image-tag) }                                 # 🔑

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
        value: "header.match('X-Github-Event', 'push') && body.ref.startsWith('refs/tags/release/') && body.ref.split('/').size() >= 4"
      - name: overlays
        value:
        - key: image_tag
          expression: "body.ref.split('/')[3]"
        - key: environments
          expression: "body.ref.split('/').size() > 4 ? body.ref.split('/')[4] : 'dev'"
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
  - `apps/deployments`: `get, list, watch, patch` (legacy)
