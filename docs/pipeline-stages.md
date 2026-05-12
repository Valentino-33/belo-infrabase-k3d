# Pipeline — cómo cada stage garantiza un despliegue correcto

Este documento responde a tres preguntas concretas:

1. **¿Qué hace cada stage del pipeline?**
2. **¿Cómo se garantiza que el load test corra sobre la versión NUEVA y no contra la vieja?**
3. **¿Qué garantiza que el circuito (orden + transiciones de estado) sea correcto para Blue/Green y Canary?**

Para detalles de implementación (imágenes, comandos exactos, RBAC) ver [pipeline-internals.md](pipeline-internals.md).

---

## Visión general

El pipeline `pythonapps-pipeline` tiene **7 stages**:

```
┌─────────┐  ┌─────────────┐  ┌────────────┐  ┌──────────────┐  ┌───────────┐  ┌──────────────┐  ┌──────────────┐
│ 1.Clone │→ │ 2.Build/Push│→ │ 3.Bump GO  │→ │4.Wait ArgoCD │→ │5.LoadTest │→ │6.Promote/RB  │→ │7.Burn-to-scl │
└─────────┘  └─────────────┘  └────────────┘  └──────────────┘  └───────────┘  └──────────────┘  └──────────────┘
   git           Kaniko          yq + push       polling state    k6 funcional    kubectl patch    k6 carga + HPA
   clone         a DockerHub     a gitops repo   ArgoCD+Rollout   contra preview   subresource     polling replicas
```

Cada stage **bloquea** los siguientes hasta cumplir su contrato. Si cualquiera falla, el pipeline se corta y el Stage 6 hace `abort` (rollback automático) para las strategies que lo soportan.

| # | Task | Imagen | Sobre qué actúa | Output |
|---|------|--------|-----------------|--------|
| 1 | `git-clone-app` | `alpine/git` | repo de la app (en GitHub) | tree en `/workspace/source/src/` |
| 2 | `kaniko-build-push` | `kaniko-project/executor` | imagen Docker | imagen pusheada a Docker Hub con tag `<semver>` |
| 3 | `bump-gitops-image` | `alpine/git` + `mikefarah/yq` | gitops repo (`values.yaml` de cada env) | commit pusheado + result `commit-sha` |
| 4 | `wait-argocd-sync` | `bitnami/kubectl` | ArgoCD Application + Rollout (cluster) | Rollout en `Paused` con `image-tag` correcto + result `strategy` |
| 5 | `run-load-test` | `grafana/k6` | preview svc (BG/Canary) o stable svc (Rolling) | result `outcome` ∈ {passed, failed} |
| 6 | `promote-or-rollback` | `bitnami/kubectl` | Rollout (patch subresource) | Rollout `Healthy` (promote) o `Degraded` (abort) |
| 7 | `run-burn-to-scale` | sidecar `k6` + step `kubectl` | stable svc (versión recién promovida) + HPA | result `outcome` + `baseline/max-replicas` |

---

## Stage 1 — Clone

**Qué hace**: clona el repo de la app **exactamente en el commit del tag pushado**. El TriggerBinding extrae `git_revision = body.ref` (e.g. `refs/tags/release/v1.2.0/dev`) y se lo pasa al Task.

**Sobre qué actúa**: `loadtest/`, `Dockerfile`, `app/` del repo de la app.

**Por qué importa para los stages siguientes**:
- Stage 2 (build) usa el Dockerfile que clonó este stage → la imagen sale del **mismo commit** que disparó el pipeline.
- Stage 5 (load-test) usa los scripts en `/workspace/source/src/loadtest/` que clonó este stage → los tests que corren son los del **mismo commit** que se está desplegando. Si la versión nueva trae cambios en el contrato (nuevos endpoints, schema de response), los scripts actualizados los validan.

> **Single source of truth**: los scripts k6 viven en el repo de la app, no en este repo. Así no se desincronizan con la app.

---

## Stage 2 — Build & Push

**Qué hace**: `kaniko build` desde el contexto clonado en Stage 1 → push a `docker.io/<user>/<app>:<tag>`.

**Sobre qué actúa**: Docker Hub.

**Garantía**: la imagen `valentinobruno/webserver-api01:v1.2.0` que se publica es **bit-exacta** del código en `refs/tags/release/v1.2.0/...`. No hay forma de que Stage 5 pruebe otra imagen distinta a la que se acaba de buildear — el tag de la imagen está atado al tag de git.

---

## Stage 3 — Bump GitOps

**Qué hace**: clona el repo de infra, ejecuta `yq e '.image.tag = "v1.2.0"'` sobre el `values.yaml` de cada env del param `environments`, commitea y pushea.

**Sobre qué actúa**: `gitops/` y `charts/pythonapps/apps/<app>/<env>/values.yaml` del repo de infra (este repo).

**Output crítico**: emite el `result commit-sha` con el full SHA del commit pusheado. **Este SHA es lo que el Stage 4 va a esperar que ArgoCD reporte como `app.status.sync.revision`** — es el ancla anti-race-condition.

---

## Stage 4 — Wait ArgoCD (el stage clave para correctness)

Este stage es **el que garantiza que el load test corra sobre la versión nueva**, no la vieja. Vale la pena detallar exactamente cómo lo hace.

### 4.1 Polling de ArgoCD: "¿el commit del Stage 3 ya fue aplicado?"

```sh
# Forzar refresh inmediato (sin esto, ArgoCD podría tardar hasta 3min en notar el commit)
kubectl annotate application $APP_CR -n argocd \
  argocd.argoproj.io/refresh=normal --overwrite

while [ $ELAPSED -lt $TIMEOUT ]; do
  REVISION=$(kubectl get application $APP_CR -n argocd \
    -o jsonpath='{.status.sync.revision}')

  if [ "$SYNC" = "Synced" ] && [ "$REVISION" = "$EXPECTED_SHA" ]; then
    # ✅ ArgoCD reportó que aplicó EL commit del Stage 3
    break
  fi
  sleep 5
done
```

**Garantía 1**: hasta que `app.status.sync.revision == commit-sha del Stage 3`, no se avanza. Si ArgoCD aplicó un commit más viejo (porque el polling todavía no detectó el bump), el stage sigue esperando. **Sin esto** habría una race condition: Stage 5 podría correr cuando ArgoCD todavía tiene la versión vieja.

### 4.2 Polling del Rollout: "¿la spec ya tiene el image-tag nuevo Y está paused?"

```sh
while [ $ELAPSED -lt $TIMEOUT ]; do
  PHASE=$(kubectl get rollout $ROLLOUT -n $NS -o jsonpath='{.status.phase}')
  SPEC_TAG=$(kubectl get rollout $ROLLOUT -n $NS \
    -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's|.*:||')

  # La spec DEBE reflejar el image-tag nuevo
  if [ "$SPEC_TAG" != "$IMAGE_TAG" ]; then
    continue
  fi

  case "$STRATEGY" in
    bluegreen|canary)
      # Para BG/Canary requerimos Paused — green/canary RS está ready
      # esperando promote. Si estuviera Healthy sería estado stale.
      [ "$PHASE" = "Paused" ] && exit 0
      ;;
    rollingupdate)
      [ "$PHASE" = "Healthy" ] && exit 0
      ;;
  esac
done
```

**Garantía 2**: `rollout.spec.template.spec.containers[0].image` debe terminar con el `image-tag` del pipeline run. Esto verifica que el Rollout objeto en el cluster **ya está apuntando a la imagen recién buildeada** — no a una vieja.

**Garantía 3 (BG/Canary)**: el Rollout tiene que estar en `Paused`. Esto significa que:
- Argo Rollouts creó un nuevo ReplicaSet con la imagen nueva
- Ese RS está atado al **preview** service (BG) o al **canary** service (Canary)
- El traffic switch o el `setWeight` NO se aplicó todavía (autoPromotionEnabled: false / `pause: {}` en steps)
- Stage 5 puede pegarle al preview/canary URL y va a hablar **exclusivamente con el RS nuevo**

**Garantía 4 (RollingUpdate)**: tiene que estar `Healthy`. Como rollingupdate no tiene preview, el load test va contra el stable directo — pero recién después de que todos los pods fueron actualizados.

### 4.3 Auto-detección de strategy

El task lee la spec del Rollout vivo y deriva la strategy:

```sh
if kubectl get rollout $ROLLOUT -n $NS \
    -o jsonpath='{.spec.strategy.blueGreen.activeService}' | grep -q .; then
  STRATEGY="bluegreen"
elif kubectl get rollout $ROLLOUT -n $NS \
    -o jsonpath='{.spec.strategy.canary.steps}' | grep -q .; then
  STRATEGY="canary"
else
  STRATEGY="rollingupdate"
fi
```

Esto emite el result `strategy` que consume Stage 5 (para elegir script y URL) y Stage 6 (para elegir patch). **La strategy no se pasa por el tag git** — se infiere del estado del Rollout, lo que evita que un developer empuje un tag con la strategy equivocada.

---

## Stage 5 — Load Test (¿contra qué endpoint actúa?)

```sh
BASE_URL="http://${RELEASE}-stable.${NS}.svc.cluster.local:8080"
PREVIEW_URL="http://${RELEASE}-preview.${NS}.svc.cluster.local:8080"

case "$STRATEGY" in
  bluegreen)
    SCRIPT="load-bluegreen.js"
    EXTRA="-e PREVIEW_URL=$PREVIEW_URL"   # ← apunta al preview (green RS)
    ;;
  canary)
    SCRIPT="load-canary.js"
    EXTRA="-e BASE_URL=$BASE_URL"         # ← apunta al stable (recibe split de tráfico)
    ;;
  *)
    SCRIPT="smoke.js"
    EXTRA="-e BASE_URL=$BASE_URL"
    ;;
esac

k6 run $EXTRA "/workspace/source/src/loadtest/$SCRIPT"
```

### Endpoint exacto por estrategia

| Strategy | URL del load test | Por qué |
|----------|-------------------|---------|
| **bluegreen** | `http://<app>-<env>-preview.<ns>.svc.cluster.local:8080` | El svc preview enrutea **100% al green RS** (versión nueva). Pegarle al stable testería la versión vieja. |
| **canary** | `http://<app>-<env>-stable.<ns>.svc.cluster.local:8080` | El traffic split del argo-rollouts envía 5/25/50% al canary RS. Pegarle al stable **simula tráfico real** durante el canary. |
| **rollingupdate** | `http://<app>-<env>-stable.<ns>.svc.cluster.local:8080` | No hay preview separado — el RS nuevo reemplazó al viejo en el stable svc. |

### Cadena de garantías que aseguran que el k6 corre contra la versión nueva

```
Stage 1: clone @ <tag>
   │  Trae loadtest/*.js del commit que se va a desplegar.
   ▼
Stage 2: build @ <tag>
   │  Imagen valentinobruno/webserver-api01:<tag> contiene el código de ese commit.
   ▼
Stage 3: bump values.yaml → image.tag = <tag>
   │  Commit en gitops repo. Emite commit-sha.
   ▼
Stage 4: poll ArgoCD hasta que sync.revision == commit-sha
   │  Garantía 1: ArgoCD aplicó EL commit del Stage 3 (no uno más viejo).
   ▼
Stage 4: poll Rollout hasta que spec.image tag == <tag> Y phase == Paused
   │  Garantía 2: el Rollout vivo apunta a la imagen recién buildeada.
   │  Garantía 3: el preview/canary RS está listo y el switch NO ocurrió.
   ▼
Stage 5: k6 run --env URL=preview-svc
        │
        ▼   Stage 4 garantizó que el preview-svc enrutea al RS con image=<tag>
        El k6 está hablando con la versión NUEVA.
```

### Fail-fast si el script no existe

```sh
if [ ! -f "$SCRIPT_PATH" ]; then
  echo "ERROR: $SCRIPT no existe en el repo de la app"
  printf "failed" > "$(results.outcome.path)"
  exit 1
fi
```

Si el repo de la app cambió de strategy (e.g. de bluegreen a canary) pero olvidó agregar el script (`loadtest/load-canary.js`), el pipeline **rompe ruidosamente** en lugar de marcar verde silencioso. No hay deploy posible sin tests.

---

## Stage 6 — Promote o Rollback

Comportamiento según `outcome` (de Stage 5) × `strategy` (de Stage 4):

| Strategy | Outcome | Acción | Patch |
|----------|---------|--------|-------|
| **bluegreen** | passed | promote → switch tráfico al green | `kubectl patch rollout $R --subresource=status -p '{"status":{"pauseConditions":null}}'` |
| **bluegreen** | failed | abort → mantener stable (blue), destruir green | `kubectl patch rollout $R -p '{"spec":{"abort":true}}'` |
| **canary** | passed | promote completo → 100% canary, skip steps restantes | `kubectl patch rollout $R --subresource=status -p '{"status":{"promoteFull":true}}'` |
| **canary** | failed | abort → vuelve todo al stable | `kubectl patch rollout $R -p '{"spec":{"abort":true}}'` |
| **rollingupdate** | passed | no-op (rollout completa solo) | — |
| **rollingupdate** | failed | abort | `kubectl patch rollout $R -p '{"spec":{"abort":true}}'` |

### Verificación post-patch

Después de patchear, el Task espera con timeout 180s la fase esperada:

```sh
wait_phase() {
  EXPECTED="$1"   # "Healthy" si promote, "Degraded" si abort
  while [ $ELAPSED -lt 180 ]; do
    PHASE=$(kubectl get rollout $R -n $NS -o jsonpath='{.status.phase}')
    [ "$PHASE" = "$EXPECTED" ] && return 0
    sleep 5
  done
  return 1
}
```

Si la fase no se alcanza en 180s, el stage falla → el PipelineRun queda Failed → el dashboard de Tekton lo muestra rojo.

### Production gate

Si `PRIMARY_ENV == production`, el stage **no patchea nada**. En su lugar agrega una annotation a la ArgoCD application:

```yaml
metadata:
  annotations:
    belo/pending-promote: "true"
    belo/promote-reason: "load-test-passed"
```

Y exit OK. Un humano debe promover manualmente. Ver detalle en [pipeline-internals.md → promote-or-rollback](pipeline-internals.md#6-promote-or-rollback).

---

## Stage 7 — Burn-to-scale (NUEVO)

**Qué hace**: valida que el HPA escala el Rollout al cruzar el `targetCPUUtilization`. Es ortogonal a la validación funcional del Stage 5 — acá medimos **capacidad**, no latencia.

**Diseño con sidecar de Tekton**:

```yaml
sidecars:
- name: loadgen           # corre k6 burn-to-scale.js EN PARALELO al step principal
  image: grafana/k6:latest
  script: |
    sleep 10               # darle tiempo al step para capturar baseline
    k6 run -e TARGET_URL=$STABLE_URL /workspace/source/src/loadtest/burn-to-scale.js
    sleep 600              # mantener vivo hasta que el step termine

steps:
- name: monitor-hpa       # corre kubectl polling
  image: bitnami/kubectl:latest
  script: |
    BASELINE=$(kubectl get rollout $R -o jsonpath='{.status.replicas}')
    MAX_SEEN=$BASELINE
    ELAPSED=0
    while [ $ELAPSED -lt 180 ]; do
      R=$(kubectl get rollout $R -o jsonpath='{.status.replicas}')
      [ "$R" -gt "$MAX_SEEN" ] && MAX_SEEN=$R
      sleep 10
      ELAPSED=$((ELAPSED+10))
    done
    if [ "$MAX_SEEN" -gt "$BASELINE" ]; then echo passed; else echo failed; fi
```

**Por qué un Task separado y no parte de Stage 5**:
- **Separación de preocupaciones**: Stage 5 valida que la app responda correctamente (200s, schema, latencia). Stage 7 valida que la app escala bajo carga. Si las mezcláramos, una falla de capacidad (CPU insuficiente) marcaría `outcome=failed` y abortaría el rollout — pero la app puede estar funcionalmente perfecta.
- **Diferentes éxito-criteria**: Stage 5 usa thresholds de k6 (p95/p99/error_rate); Stage 7 valida `replicas > baseline`.
- **Diferentes targets**: Stage 5 corre contra preview/canary (versión NO promovida); Stage 7 corre contra stable (ya promovido) porque queremos validar la versión que ahora sirve tráfico productivo.
- **Trazabilidad**: dos TaskRuns separados, logs separados, results separados — debugging más limpio.

**When-clause**:

```yaml
when:
- input: "$(tasks.load-test.results.outcome)"
  operator: in
  values: ["passed"]
```

Si Stage 5 falló (Stage 6 ya hizo rollback), Stage 7 ni siquiera arranca — no tiene sentido validar capacidad de algo que volvió a la versión vieja.

**Skip en production**: el step principal hace `if [ "$PRIMARY_ENV" = "production" ]; then exit 0; fi`. No quemamos CPU del entorno productivo.

**Condición de éxito**: `MAX_REPLICAS > BASELINE_REPLICAS` durante la ventana de monitoreo (180s default). Si el HPA escaló de 1 → 2 (o más) replicas **al menos una vez**, pasa. El test no exige que se mantenga escalado al final (la HPA tiene stabilization windows largas para scale-down, ~5min default).

---

## Garantías del circuito completo

| Garantía | Cómo se logra |
|----------|---------------|
| **El load test corre sobre la versión nueva** | Stage 4 espera que `rollout.spec.image-tag == <tag-del-pipeline>` Y `phase == Paused` antes de avanzar. El preview svc enrutea solo al RS con esa imagen. |
| **No se promueve nada sin tests** | Stage 5 falla con `exit 1` si el script no existe. Stage 6 lee `outcome` y aborta si fue `failed`. |
| **No se prueba una versión vieja por race condition** | Stage 4 espera `app.status.sync.revision == commit-sha del Stage 3`. El force-refresh saca el polling de 3min default a ~5s. |
| **Rollback automático si los tests fallan** | Stage 6 emite `kubectl patch spec.abort=true` para BG/Canary/Rolling. Argo Rollouts destruye el RS nuevo, mantiene stable. |
| **Production no se auto-promueve** | Stage 6 detecta `PRIMARY_ENV=production` y solo annota — promote manual obligatorio. |
| **Capacidad se valida después de promote** | Stage 7 valida HPA scale-up cuando el RS nuevo ya es stable. Si HPA no funciona, el equipo lo nota antes del siguiente release. |
| **Re-pushear el mismo tag falla limpio** | TriggerTemplate usa `name: <app>-pipelinerun-<tag>` determinístico. Re-push → `AlreadyExists` en lugar de re-ejecutar silencioso. |
| **PipelineRun queda trazable por release** | Naming determinístico permite `kubectl get pipelinerun webserver-api01-pipelinerun-v1.2.0 -o yaml` y ver todo el detalle del deploy. |

---

## Mapa de results entre tasks

```
Stage 3 bump-gitops.results.commit-sha    ──→  Stage 4 wait-argocd.params.expected-commit-sha
params.image-tag                          ──→  Stage 4 wait-argocd.params.image-tag

Stage 4 wait-argocd.results.strategy      ──→  Stage 5 load-test.params.strategy
                                          ──→  Stage 6 promote-rollback.params.strategy
                                          ──→  Stage 7 burn-to-scale.params.strategy

Stage 5 load-test.results.outcome         ──→  Stage 6 promote-rollback.params.outcome
                                          ──→  Stage 7 burn-to-scale.when (skip if not passed)

Stage 7 burn-to-scale.results.outcome     ──→  (visible vía tkn / Tekton Dashboard, no consumido)
Stage 7 burn-to-scale.results.max-replicas ──→ (visible para auditoria)
```

---

## ¿Y si quiero saltarme stages?

El pipeline `pythonapps-pipeline` está cableado en orden estricto vía `runAfter:` — no hay forma de saltarse stages para un tag puntual. Decisión consciente: si necesitás un deploy sin test (hotfix p1), corré el comando equivalente manualmente:

```bash
# Ejemplo: hotfix sin load test
# 1. Bumpear values.yaml a mano y pushear
# 2. ArgoCD detecta y aplica
# 3. Promover manualmente:
kubectl argo rollouts promote webserver-api01-dev -n webserver-api01-dev
```

Eso queda **fuera** del pipeline y deja un rastro claro de que no fue un deploy normal.

---

## Diagrama de flujo end-to-end (todos los stages)

```mermaid
flowchart TB
    START([Push tag<br/>refs/tags/release/v1.2.0/dev])
    EL[EventListener<br/>CEL filter]
    TR[PipelineRun creado]

    START --> EL --> TR

    TR --> S1[1. Clone<br/>repo@tag]
    S1 --> S2[2. Build+Push<br/>Kaniko → Docker Hub]
    S2 --> S3[3. Bump GitOps<br/>commit-sha emitido]
    S3 --> S4{4. Wait ArgoCD}

    S4 -->|sync@commit-sha<br/>rollout.spec@image-tag<br/>phase=Paused| S5[5. Load Test<br/>k6 vs preview/canary]
    S4 -->|timeout| FAIL1[Pipeline FAILED]

    S5 -->|outcome=passed| S6_OK{6. Promote}
    S5 -->|outcome=failed| S6_KO{6. Rollback}

    S6_OK -->|BG: patch pauseConditions=null| HEALTHY1[Rollout Healthy]
    S6_OK -->|Canary: patch promoteFull=true| HEALTHY1
    S6_OK -->|Rolling: no-op| HEALTHY1

    S6_KO -->|abort=true| DEGRADED[Rollout Degraded<br/>stable intacto]

    HEALTHY1 --> S7{7. Burn-to-scale}
    DEGRADED --> END_KO([Pipeline OK<br/>rollback efectivo])

    S7 -->|sidecar k6 + monitor HPA<br/>replicas > baseline| END_OK([Pipeline OK<br/>capacidad validada])
    S7 -->|no scale-up en 180s| END_PARTIAL([Pipeline OK<br/>WARN: HPA no escaló])

    classDef ok fill:#dcfce7,stroke:#16a34a
    classDef fail fill:#fee2e2,stroke:#dc2626
    classDef gate fill:#fef9c3,stroke:#ca8a04

    class HEALTHY1,END_OK,END_KO,END_PARTIAL ok
    class FAIL1 fail
    class S4,S6_OK,S6_KO,S7 gate
```
