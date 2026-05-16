# Estrategias de deployment — Blue/Green vs Canary

Cómo se aplica cada estrategia desde que pushás un tag hasta que la nueva versión sirve 100% del tráfico.

---

## Lo que es común a ambas estrategias

Las dos apps (api01 + api02) usan el **mismo chart Helm** (`charts/pythonapps`). Lo único que cambia entre estrategias es **un campo** en el `values.yaml` del env:

```yaml
rollout:
  strategy: bluegreen   # api01
  # strategy: canary    # api02
```

El chart **siempre** genera los mismos 4 objetos en el cluster, sea cual sea la estrategia:

```
1. Rollout (kind: argoproj.io/v1alpha1/Rollout)
   ↑ reemplaza al Deployment estándar; lo gestiona Argo Rollouts
2. Service <release>-stable    (port 8080 → app)
3. Service <release>-preview   (port 8080 → app)
4. Ingress  api01.localhost          → stable svc
   Ingress  preview-api01.localhost  → preview svc
```

**Topología invariante**: stable + preview existen siempre, en las dos estrategias. La diferencia es **a qué ReplicaSet (RS) apunta cada svc en cada momento**.

El **pipeline de release** también es el mismo (6 stages: clone → build-push → bump-gitops → wait-argocd → load-test → promote-rollback). El comportamiento por estrategia se concentra en dos stages:

- **Stage 4 (wait-argocd)** — auto-detecta la estrategia leyendo `rollout.spec.strategy.*` y espera el estado correcto antes de avanzar.
- **Stage 6 (promote-rollback)** — emite el patch correcto al Rollout según la estrategia.

### Sobre el flag `loadtest` en el tag

El comportamiento del **Stage 5 (load-test)** lo controla un flag opt-in en el tag de release: `release/<ver>/<env>/loadtest=true|false`. Default `false`.

- `loadtest=false` (o ausente) → Stage 5 corre pero skipea k6 internamente y emite `outcome=passed`. Stage 6 auto-promueve sin tráfico sintético. **Usar para releases rápidos**, hotfixes, o cuando el load-test no aporta valor sobre este release específico (e.g. solo cambió un texto).
- `loadtest=true` → Stage 5 ejecuta k6 contra el preview svc (BG) o stable svc (Canary), aplica thresholds, decide promote/abort según outcome. **Usar para releases que tocan código de hot-path** o cuando querés validar bajo carga antes del switchover.

Por qué el default es `false`: el k6 fuerza CPU → HPA scale durante el Rollout, lo que enmascara la dinámica natural de BG (2 RSes idle vs 2 RSes scaled) y Canary (split por setWeight). Para validar capacidad existe el [pipeline burn](pipeline-stages.md#pipeline-auxiliar--burn-to-scale-capacity-test) que es independiente del release.

---

## Dos modelos de promoción: legacy y enterprise

El chart soporta **dos modelos** para decidir si un release se promueve o se aborta. La diferencia es **quién toma la decisión**.

### Modelo LEGACY (`analysis.enabled: false` — default del chart)

El **pipeline es el dueño de la verdad**. El Stage 5 corre k6, emite `outcome=passed|failed`, y el Stage 6 hace `kubectl patch` directo sobre el Rollout (`pauseConditions=null` para promover, `spec.abort=true` para abortar). El Rollout BG usa `autoPromotionEnabled: false` y se queda en `Paused` esperando al pipeline.

Apropiado para apps sin métricas Prometheus, o entornos donde la simplicidad importa más que la rigurosidad.

### Modelo ENTERPRISE (`analysis.enabled: true` — opt-in por app+env)

**Argo Rollouts es el dueño de la verdad.** El Rollout tiene `AnalysisTemplate` configurados que consultan Prometheus:

- **success-rate**: `sum(rate(reqs sin 5xx)) / sum(rate(reqs total)) >= 0.99`
- **latency-p95**: `histogram_quantile(0.95, ...) < 1.0s`

El controller de Argo Rollouts ejecuta estos análisis (`AnalysisRun`), decide promote/abort, y hace **rollback automático** si fallan. El pipeline cambia de rol:

| Stage | Rol en modelo LEGACY | Rol en modelo ENTERPRISE |
|-------|----------------------|--------------------------|
| **Stage 4** (wait-argocd) | espera `phase=Paused` | espera que el RS nuevo esté ready (NO `Paused` — Argo no pausa con `autoPromotionEnabled=true`) |
| **Stage 5** (load-test) | k6 **valida** (emite outcome) | k6 **genera tráfico** para que el `AnalysisRun` tenga data en Prometheus — corre siempre, ignora el flag `loadtest` |
| **Stage 6** (promote-rollback) | hace los `kubectl patch` de promote/abort | solo **observa** `phase=Healthy` o `Degraded` — Argo ya decidió |

El Stage 6 detecta el modo por introspección del Rollout vivo (¿tiene `prePromotionAnalysis` / `steps[*].analysis`?), sin params extra en el pipeline.

**Por qué el k6 es obligatorio en modo enterprise**: el `AnalysisRun` consulta `rate(...[1m])` — sin tráfico, las queries dan `NaN` y el Rollout queda `Degraded`. El k6 del Stage 5 cumple el rol que en producción cumpliría el tráfico real. El timing del `AnalysisTemplate` (`initialDelay 60s`, `count 2`, `interval 15s` ≈ 90s por análisis) está calibrado para caber dentro de la ventana del k6 (~3min).

> En una infra con tráfico real sostenido (producción real, o un load-generator permanente en staging), el k6 del pipeline deja de ser necesario — el `AnalysisRun` usa el tráfico que ya existe. El acople k6↔análisis es una conveniencia para entornos sin tráfico, no parte del modelo.

Configuración (en `<app>/<env>/values.yaml`):

```yaml
analysis:
  enabled: true
  metricPrefix: api01   # prefijo de las métricas: api01_requests_total, etc.
```

Defaults (thresholds, timing, `prometheusAddress`) en `charts/pythonapps/values.yaml` — overridables por app.

---

## Blue/Green — api01

### Manifest generado por el chart (`templates/rollout.yaml`)

**Modo legacy** (`analysis.enabled: false`):

```yaml
spec:
  strategy:
    blueGreen:
      activeService:        webserver-api01-dev-stable    # ← donde el tráfico real
      previewService:       webserver-api01-dev-preview   # ← donde la nueva versión
      autoPromotionEnabled: false                          # ← gate manual del pipeline
      scaleDownDelaySeconds: 30                            # ← ventana de rollback
```

**Modo enterprise** (`analysis.enabled: true` — el que usa api01-dev):

```yaml
spec:
  strategy:
    blueGreen:
      activeService:        webserver-api01-dev-stable
      previewService:       webserver-api01-dev-preview
      autoPromotionEnabled: true                           # ← Argo decide (no el pipeline)
      scaleDownDelaySeconds: 120                           # ← 120s: da espacio al postPromotionAnalysis
      prePromotionAnalysis:                                # ← corre ANTES del switch, sobre preview svc
        templates: [{ templateName: webserver-api01-dev-app-health }]
        args: [{ name: service, value: ...-preview }, { name: namespace, value: ... }]
      postPromotionAnalysis:                               # ← corre DESPUÉS del switch, sobre stable svc
        templates: [{ templateName: webserver-api01-dev-app-health }]
        args: [{ name: service, value: ...-stable }, { name: namespace, value: ... }]
```

El `postPromotionAnalysis` es la pieza clave del rollback automático: corre durante los 120s de `scaleDownDelaySeconds`, **mientras el blue RS todavía está vivo**. Si las métricas del green (ya sirviendo tráfico real) fallan, Argo Rollouts aborta → el blue sigue ahí → rollback instantáneo, cero downtime, sin intervención humana.

### Flujo de un release — modo ENTERPRISE (api01-dev)

```
T=0     Estado inicial — solo blue (v0.10.0) está vivo
        stable svc → blue [3 pods] = 100% tráfico  ·  preview svc → blue

T+30s   Stage 3 bumpea image.tag a v0.11.0 → ArgoCD aplica → Argo crea green RS

T+1m    green RS (v0.11.0) con 3 pods ready.
        Stage 4 detecta updatedReplicas>=1 (NO espera Paused) → sale.
        autoPromotionEnabled=true → Argo arranca el prePromotionAnalysis.

T+1m    Stage 5 arranca k6 contra preview-api01.localhost → genera tráfico
        en el green RS. El AnalysisRun -pre consulta Prometheus (success-rate,
        latency-p95) sobre el preview svc usando ese tráfico.

T+2m30s prePromotionAnalysis → Successful.
        Argo Rollouts SWITCH automático: activeService → green RS.
        ┌──────────────────────────────────────────────────────┐
        │ stable svc → green (v0.11.0)  [3 pods]               │ ← 100% real
        │ blue (v0.10.0) [3 pods, scale-down en 120s]          │ ← ventana rollback
        └──────────────────────────────────────────────────────┘
        Argo arranca el postPromotionAnalysis sobre el stable svc.

T+4m    postPromotionAnalysis → Successful (el k6 sigue generando tráfico que
        ahora llega al green vía stable svc). Argo confirma phase=Healthy.
        Stage 6 — que solo observaba — ve Healthy y reporta OK.

T+4m    Pasados los 120s de scaleDownDelay, blue eliminado. Pipeline termina.
```

> **Timeline de ejemplo**: RS nuevo @T+75s · prePromotionAnalysis @T+90s · `Successful` + switch @T+165s · postPromotionAnalysis `Successful` @T+240s · pipeline `Succeeded` @T+285s.

### Si el análisis falla (modo enterprise)

```
prePromotionAnalysis → Failed:
       Argo NO switchea. green RS queda Degraded, blue sigue sirviendo 100%.
       El switch nunca ocurrió → cero impacto en usuarios.

postPromotionAnalysis → Failed (el switch YA ocurrió):
       Argo aborta automáticamente DENTRO de los 120s de scaleDownDelay.
       blue todavía está vivo → Argo revierte activeService → blue.
       Rollback instantáneo, sin pipeline, sin humano.

En ambos casos: Stage 6 ve phase=Degraded, imprime los AnalysisRuns que
fallaron (kubectl get analysisrun) y marca el pipeline como Failed.
```

### Flujo modo LEGACY (`analysis.enabled: false`)

Idéntico hasta el T+1m, pero el Rollout entra a `phase=Paused` (autoPromotionEnabled=false), el Stage 4 espera ese `Paused`, el Stage 5 k6 valida y emite `outcome`, y el Stage 6 hace el `kubectl patch status.pauseConditions=null` (promote) o `spec.abort=true` (rollback). `scaleDownDelaySeconds=30`.

---

## Canary — api02

### Manifest generado por el chart

**Modo legacy** (`analysis.enabled: false`) — `pause: {}` en cada step, el pipeline promueve con `promoteFull=true`:

```yaml
canary:
  steps:
  - setWeight: 5
  - pause: {}              # ← pipeline corre k6 y luego patcha promoteFull
  - setWeight: 25
  - pause: {}
  - setWeight: 50
  - pause: {}
```

**Modo enterprise** (`analysis.enabled: true` — el que usa api02-dev) — `analysis` en cada step, Argo avanza solo:

```yaml
canary:
  steps:
  - setWeight: 5
  - analysis: { templates: [{ templateName: webserver-api02-dev-app-health }], args: [...] }
  - setWeight: 25
  - analysis: { templates: [...], args: [...] }
  - setWeight: 50
  - analysis: { templates: [...], args: [...] }
  - setWeight: 100
  - analysis: { templates: [...], args: [...] }   # ← post-promotion: valida el RS al 100%
```

> Canary **no tiene** `prePromotionAnalysis`/`postPromotionAnalysis` como campos top-level (eso es exclusivo de BlueGreen — su switch es atómico). En canary el análisis va **inline en los steps**. El último `analysis` (tras `setWeight: 100`) cumple la función de post-promotion. Argo Rollouts avanza al siguiente step **solo si** el `AnalysisRun` del step anterior pasa; aborta automáticamente si falla.

### Flujo de un release — modo ENTERPRISE (api02-dev)

```
T=0     Solo stable (v1.3.0). canary RS no existe.

T+30s   Stage 3 bumpea image.tag=v1.4.0 → ArgoCD aplica → Argo crea canary RS.

T+45s   Step 1: setWeight 5%. nginx-ingress: 95% stable / 5% canary.
        AnalysisRun -1 (sobre canary svc) → Running. Stage 5 k6 generando tráfico.
T+1m45s AnalysisRun -1 → Successful → Argo avanza solo al Step siguiente.

T+2m    Step 3: setWeight 25%. AnalysisRun -3 → Running → Successful.
T+3m15s Step 5: setWeight 50%. AnalysisRun -5 → Running → Successful.
T+4m30s Step 7: setWeight 100%. AnalysisRun -7 (post-promotion, sobre stable
        svc que ya apunta al RS nuevo) → Running → Successful.

T+5m45s phase=Healthy. stable svc → canary RS (v1.4.0) = 100%.
        Stage 6 — que solo observaba — ve Healthy y reporta OK.
```

> **Timeline de ejemplo**: 4 AnalysisRuns (`-1`, `-3`, `-5`, `-7`), todos `Successful`, canary avanza 5%→25%→50%→100% sin intervención del pipeline. Pipeline `Succeeded` @T+345s.

Si **cualquier** `AnalysisRun` falla, Argo Rollouts aborta el canary automáticamente: el `canary RS` se destruye, el `stable RS` (versión vieja) sigue sirviendo 100%. El Stage 6 ve `phase=Degraded` y marca el pipeline `Failed`.

### Flujo modo LEGACY (`analysis.enabled: false`)

El canary se queda en `phase=Paused` en el primer `pause: {}` (Step 1, 5%). El Stage 5 k6 valida, el Stage 6 hace `kubectl patch status.promoteFull=true` que **salta** los steps 25%/50% y va directo a 100%. Es un canary "1 step de validación + promote-full" — más rápido pero menos gradual que el enterprise.

### Avance gradual sin promoteFull (manual, no usado por pipeline)

Si querés ver los steps uno por uno (5% → 25% → 50% → 100%):

```bash
kubectl argo rollouts promote webserver-api02-dev -n webserver-api02-dev
# Avanza UN solo step. Repetir 4 veces.
```

El pipeline usa `promoteFull=true` para ahorrar tiempo en la demo. En prod real querés los steps + AnalysisTemplate.

---

## Lado a lado

| Aspecto | Blue/Green (api01) | Canary (api02) |
|---|---|---|
| **Cuánta versión nueva ve tráfico real durante el rollout** | 0% hasta el switch | 5% → 25% → 50% (cada step paused) |
| **Cuándo k6 testea la nueva versión** | Contra **preview** svc (100% green, sin tráfico real) | Contra **stable** svc (split real entre stable+canary) |
| **Endpoint expuesto durante el rollout** | `preview-api01.localhost` = 100% green<br/>`api01.localhost` = 100% blue (aún) | `api02.localhost` = stable + N% canary (según step)<br/>`preview-api02.localhost` = 100% canary |
| **Cómo se promueve (legacy)** | `patch status.pauseConditions=null` | `patch status.promoteFull=true` (skip steps) |
| **Cómo se promueve (enterprise)** | Argo switchea solo si `prePromotionAnalysis` pasa | Argo avanza step a step si cada `AnalysisRun` pasa |
| **Cómo se rollbackea (enterprise)** | `postPromotionAnalysis` falla → abort automático, blue revive | `AnalysisRun` de un step falla → abort automático, canary se destruye |
| **Ventana de rollback post-promote** | 30s legacy / **120s enterprise** — blue queda vivo | inmediato — canary RS pasa a ser el stable |
| **Pods durante el rollout** | 6 pods (3 blue + 3 green) | 3 stable + 1-2 canary (depende del step) |
| **Riesgo** | Doble de recursos durante el rollout | Tráfico productivo va a la versión nueva desde el primer step |
| **Cuándo conviene** | Apps stateless, recursos sobrados, queremos test funcional pre-tráfico | Cambios riesgosos, queremos detectar problemas con tráfico real, recursos justos |

---

## Cómo el chart elige qué template renderizar

`charts/pythonapps/templates/rollout.yaml` ramifica por **dos** valores:
- `rollout.strategy` → `bluegreen` | `canary` | `rollingupdate`
- `analysis.enabled` → `true` (modelo enterprise) | `false` (modelo legacy)

```
rollout.strategy=bluegreen + analysis.enabled=false → blueGreen, autoPromotionEnabled=false, scaleDownDelay=30
rollout.strategy=bluegreen + analysis.enabled=true  → blueGreen, autoPromotionEnabled=true,  scaleDownDelay=120,
                                                       prePromotionAnalysis + postPromotionAnalysis
rollout.strategy=canary    + analysis.enabled=false → canary, steps con pause:{}
rollout.strategy=canary    + analysis.enabled=true  → canary, steps con analysis:{} (5/25/50/100)
rollout.strategy=rollingupdate                      → canary con un solo step setWeight:100
```

Cambiar la estrategia o el modelo de una app = cambiar **una o dos líneas** en `<app>/<env>/values.yaml` + commitear. ArgoCD sync + Argo Rollouts re-aplica el nuevo Rollout spec en el próximo release. El `AnalysisTemplate` lo genera el mismo chart (`templates/analysis-template.yaml`) cuando `analysis.enabled=true`.

---

## Cómo el pipeline auto-detecta la estrategia (Stage 4)

`charts/pythonapps/templates/pipeline-templates/task-wait-argocd.yaml` step 2:

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

Emite `strategy` como result, que las Stages 5 y 6 consumen para elegir script de k6 y patch correspondiente. **El developer no pasa la estrategia por el tag** — viene del chart.

Además, las Stages 4, 5 y 6 detectan el **modo** (legacy vs enterprise) por introspección: ¿el Rollout tiene `prePromotionAnalysis` (BG) o algún `steps[*].analysis` (canary)? Si sí → modo enterprise → el pipeline observa en vez de patchear. Esta detección tampoco requiere params extra — el pipeline se adapta solo a lo que el chart generó.

---

## Y entonces el burn pipeline ¿dónde encaja?

NO encaja en ninguna estrategia — es ortogonal. El burn pipeline corre contra la versión **ya stable** (post-promote), pega al `stable svc` y satura CPU para verificar que el HPA escala. Sirve igual para BG, Canary o RollingUpdate, una vez que el rollout terminó. Ver [docs/pipeline-stages.md → pipeline auxiliar burn-to-scale](pipeline-stages.md#pipeline-auxiliar--burn-to-scale-capacity-test).
