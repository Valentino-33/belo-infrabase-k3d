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

## Blue/Green — api01

### Manifest generado por el chart (`templates/rollout.yaml`)

```yaml
spec:
  strategy:
    blueGreen:
      activeService:        webserver-api01-dev-stable    # ← donde el tráfico real
      previewService:       webserver-api01-dev-preview   # ← donde la nueva versión
      autoPromotionEnabled: false                          # ← gate manual obligatorio
      scaleDownDelaySeconds: 30                            # ← ventana de rollback
```

### Flujo de un release

```
T=0    Estado inicial — solo blue (v0.6.0) está vivo
       ┌──────────────────────────────────────────────────────┐
       │ stable svc → ReplicaSet blue (v0.6.0)  [3 pods]      │ ← 100% tráfico
       │ preview svc → ReplicaSet blue (v0.6.0)               │
       └──────────────────────────────────────────────────────┘

T+30s  Pipeline Stage 3 bumpea image.tag a v0.7.0 en gitops
       ArgoCD aplica el cambio → Argo Rollouts detecta nuevo image

T+1m   Argo Rollouts crea green RS con v0.7.0 + lo escala a 3 pods
       Pero el switch de tráfico NO ocurre (autoPromotionEnabled: false)
       phase=Paused
       ┌──────────────────────────────────────────────────────┐
       │ stable svc → blue (v0.6.0)   [3 pods, sirviendo]     │ ← 100% real
       │ preview svc → green (v0.7.0) [3 pods, ready]         │ ← 0% real
       └──────────────────────────────────────────────────────┘
       Stage 4 confirma: rollout.spec.image=v0.7.0 + phase=Paused

T+3m   Stage 5 (si el tag fue release/v0.7.0/dev/loadtest=true):
         k6 corre contra preview-api01.localhost:8888
         → enrutea al preview svc → enrutea SOLO al green RS
         → todos los hits llegan a v0.7.0
         Si k6 pasa (errors<20%, p95<3s, p99<5s):
           outcome=passed

       Si el tag fue release/v0.7.0/dev (sin /loadtest=true):
         Stage 5 skipea k6 inmediatamente (log "loadtest disabled by tag flag")
         outcome=passed por construcción → Stage 6 auto-promueve.

T+3m30s Stage 6: kubectl patch rollout webserver-api01-dev \
                  --subresource=status --type=merge \
                  -p '{"status":{"pauseConditions":null}}'
       ↓
       Argo Rollouts SWITCH: activeService ahora apunta al green RS
       ┌──────────────────────────────────────────────────────┐
       │ stable svc → green (v0.7.0)  [3 pods]                │ ← 100% real
       │ preview svc → green (v0.7.0)                          │
       │ blue (v0.6.0) [3 pods, scale-down en 30s]            │ ← rollback ventana
       └──────────────────────────────────────────────────────┘

T+4m   Pasados los 30s de scaleDownDelay, blue pods eliminados.
       phase=Healthy. Pipeline termina.
```

### Si k6 falla (Stage 5 outcome=failed)

```
Stage 6: kubectl patch rollout ... --type=merge -p '{"spec":{"abort":true}}'
       ↓
       Argo Rollouts destruye el green RS, blue sigue intacto sirviendo
       phase=Degraded → pipeline marca rollback efectivo OK.
```

---

## Canary — api02

### Manifest generado por el chart

```yaml
spec:
  strategy:
    canary:
      stableService:  webserver-api02-dev-stable    # ← donde está la versión vieja + split
      canaryService:  webserver-api02-dev-preview   # ← solo la versión nueva
      trafficRouting:
        nginx:
          stableIngress: webserver-api02-dev-stable
      steps:
      - setWeight: 5
      - pause: {}              # ← pipeline corre k6 acá
      - setWeight: 25
      - pause: {}              # ← y acá
      - setWeight: 50
      - pause: {}              # ← y acá
      # Stage 6 patcha promoteFull=true → 100% canary
```

### Flujo de un release

```
T=0    Solo stable (v0.1.0)
       ┌──────────────────────────────────────────────────────┐
       │ stable svc → stable RS (v0.1.0)  [3 pods]            │ ← 100% tráfico
       │ canary svc → vacío (canary RS no existe aún)         │
       └──────────────────────────────────────────────────────┘

T+1m   ArgoCD aplica image.tag=v0.2.0. Argo Rollouts crea canary RS con v0.2.0.
       Empieza Step 1: setWeight: 5%
       phase=Paused (esperando promote)
       nginx-ingress recibe annotation que dice:
         "95% al stable svc, 5% al canary svc"
       ┌──────────────────────────────────────────────────────┐
       │ stable svc → stable RS (v0.1.0)  [3 pods]            │ ← 95% real
       │ canary svc → canary RS (v0.2.0)  [1 pod]             │ ← 5% real
       └──────────────────────────────────────────────────────┘
       Estado verificable:
         curl api02.localhost:8888/api02/version × 20
         → 19 hits v0.1.0, 1 hit v0.2.0 (~aproximadamente)

T+3m   Stage 5 (si tag con /loadtest=true):
         k6 pega al stable svc → recibe TRÁFICO REAL split
         (no al preview/canary svc — eso solo daría 100% canary, no
         muestra el comportamiento real del split).

         k6 cuenta canary_hits (informativo) y errors.
         Si pasa → outcome=passed.

       Si tag sin flag (default): skipea k6 → outcome=passed → Stage 6
         auto-promote (canary va directo a 100% sin esperar split-test).

T+3m30s Stage 6: kubectl patch rollout webserver-api02-dev \
                  --subresource=status --type=merge \
                  -p '{"status":{"promoteFull":true}}'
       ↓
       Argo Rollouts skipea los steps restantes (25%, 50%) y va a 100%:
       stableRS = canary RS = v0.2.0
       ┌──────────────────────────────────────────────────────┐
       │ stable svc → canary RS (v0.2.0)  [3 pods]            │ ← 100% real
       │ canary svc → vacío                                    │
       └──────────────────────────────────────────────────────┘
       phase=Healthy.
```

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
| **Cómo se promueve** | `patch status.pauseConditions=null` | `patch status.promoteFull=true` (skip steps) |
| **Cómo se rollbackea** | `patch spec.abort=true` → destruye green | `patch spec.abort=true` → destruye canary |
| **Ventana de rollback post-promote** | 30s (`scaleDownDelaySeconds`) — blue queda vivo | inmediato — canary RS pasa a ser el stable |
| **Pods durante el rollout** | 6 pods (3 blue + 3 green) | 3 stable + 1-2 canary (depende del step) |
| **Riesgo** | Doble de recursos durante el rollout | Tráfico productivo va a la versión nueva desde el primer step |
| **Cuándo conviene** | Apps stateless, recursos sobrados, queremos test funcional pre-tráfico | Cambios riesgosos, queremos detectar problemas con tráfico real, recursos justos |

---

## Cómo el chart elige qué template renderizar

`charts/pythonapps/templates/rollout.yaml`:

```yaml
{{- if eq .Values.rollout.strategy "bluegreen" }}
strategy:
  blueGreen:
    activeService: {{ ... }}-stable
    previewService: {{ ... }}-preview
    autoPromotionEnabled: false
    scaleDownDelaySeconds: 30
{{- else if eq .Values.rollout.strategy "canary" }}
strategy:
  canary:
    stableService: {{ ... }}-stable
    canaryService: {{ ... }}-preview
    trafficRouting:
      nginx:
        stableIngress: {{ ... }}-stable
    steps:
    - setWeight: 5
    - pause: {}
    - setWeight: 25
    - pause: {}
    - setWeight: 50
    - pause: {}
{{- else }}
# rollingupdate default
{{- end }}
```

Cambiar la estrategia de una app = cambiar **una línea** en `values.yaml` + commitear. ArgoCD sync + Argo Rollouts re-aplica el nuevo Rollout spec en el próximo release.

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

---

## Y entonces el burn pipeline ¿dónde encaja?

NO encaja en ninguna estrategia — es ortogonal. El burn pipeline corre contra la versión **ya stable** (post-promote), pega al `stable svc` y satura CPU para verificar que el HPA escala. Sirve igual para BG, Canary o RollingUpdate, una vez que el rollout terminó. Ver [docs/pipeline-stages.md → pipeline auxiliar burn-to-scale](pipeline-stages.md#pipeline-auxiliar--burn-to-scale-capacity-test).
