# Guía de Demo — belo-infrabase-k3d

Esta guía cubre las tres estrategias de deployment disponibles. Seguila en orden después de tener el cluster corriendo (`make cluster-up && make secrets-apply ... && make bootstrap`).

---

## Pre-condiciones

```bash
# Verificar que el cluster está listo
make cluster-status

# Verificar que las apps sincronizaron en ArgoCD
kubectl -n argocd get applications
# Esperado: webserver-api01-dev y webserver-api02-dev en estado Synced/Healthy

# Verificar que los Rollouts existen (cada app vive en su propio namespace: app-env)
kubectl -n webserver-api01-dev get rollouts
kubectl -n webserver-api02-dev get rollouts
```

Asegurate de tener las entradas en el archivo `hosts` de Windows (`C:\Windows\System32\drivers\etc\hosts`):

```
127.0.0.1 argocd.localhost grafana.localhost kibana.localhost headlamp.localhost tekton.localhost
127.0.0.1 api01.localhost preview-api01.localhost
127.0.0.1 api02.localhost preview-api02.localhost
127.0.0.1 tekton-webhook.localhost
```

Y que el tunnel de ngrok esté corriendo (en otra terminal):

```bash
make tunnel
# Copiá la URL que muestra y configurala en GitHub → Settings → Webhooks → Payload URL
```

---

## Demo 1 — BlueGreen (webserver-api01)

**Objetivo**: deployer una nueva versión sin downtime; el tráfico solo cambia después de que el pipeline confirme que el preview pasa el load test.

### Paso 1 — Ir al repo de la app

```bash
# El repo de la app debe llamarse webserver-api01 en GitHub
cd /ruta/a/webserver-api01
```

### Paso 2 — Crear y pushear el tag

El formato del tag es `release/<semver>/<env>`:

```bash
git tag release/v1.2.0/dev
git push origin release/v1.2.0/dev
```

> El tag dispara el webhook → EventListener filtra con CEL → extrae `image_tag=v1.2.0`, `environments=dev` → crea PipelineRun **`webserver-api01-pipelinerun-v1.2.0`** automáticamente.
>
> La **strategy** (bluegreen) no viene del tag — está fija en `rollout.strategy: bluegreen` del `values.yaml` del chart. La task `wait-argocd` la auto-detecta inspeccionando el live Rollout.

### Paso 3 — Monitorear el pipeline

**Visualmente (recomendado):** abrir el Tekton Dashboard en

```
http://tekton.localhost:8888/#/pipelineruns
```

Vas a ver el run nuevo con tree view de las 6 stages. Click en cada Task muestra los logs en streaming. Link directo al run específico:

```
http://tekton.localhost:8888/#/namespaces/tekton-pipelines/pipelineruns/webserver-api01-pipelinerun-v1.2.0
```

> El nombre del PipelineRun es **determinístico**: `<app>-pipelinerun-<tag>`. Re-pushear el mismo tag falla con `AlreadyExists` — usá un semver nuevo o borrá el run con `kubectl delete pipelinerun webserver-api01-pipelinerun-v1.2.0 -n tekton-pipelines`.

**CLI (alternativa):**

```bash
# Ver el PipelineRun en tiempo real
tkn pipelinerun logs -n tekton-pipelines --last -f

# O con kubectl
kubectl -n tekton-pipelines get pipelineruns --watch
```

### Paso 4 — Ver el estado del Rollout durante Stage 4

```bash
kubectl argo rollouts get rollout webserver-api01-dev -n webserver-api01-dev --watch
```

Vas a ver algo como:
```
Name:            webserver-api01-dev
Namespace:       webserver-api01-dev
Status:          ॥ Paused
Message:         BlueGreenPause
Strategy:        BlueGreen
  ActiveSelector:    <hash-viejo>  (Blue = v1.1)
  PreviewSelector:   <hash-nuevo>  (Green = v1.2)
```

### Paso 5 — Verificar el preview (Green) mientras Stage 5 corre el k6

```bash
# Stable (Blue) — versión anterior
curl http://api01.localhost:8888/version

# Preview (Green) — nueva versión
curl http://preview-api01.localhost:8888/version
```

> **Sobre los scripts k6**: viven en el **repo de la app** (`github.com/Valentino-33/webserver-api01/loadtest/load-bluegreen.js`), no en este repo. El Stage 1 los clona automáticamente. Si cambiás `rollout.strategy` del chart (e.g., de bluegreen a canary), el repo de la app debe tener el script correspondiente (`load-canary.js`) — sino el Stage 5 falla `fail-fast`.

### Paso 6 — Ver el resultado del pipeline

Si el k6 pasa, Stage 6 hace:

```
kubectl patch rollout webserver-api01-dev -n webserver-api01-dev \
  --subresource=status --type=merge -p '{"status":{"pauseConditions":null}}'
```

Eso:
- Switch del active service: Blue → Green (= v1.2 ahora es stable)
- Scale-down del Blue en 30 segundos (`scaleDownDelaySeconds`)
- El step verifica que `phase=Healthy` antes de declarar éxito

Si el k6 falla, Stage 6 hace:

```
kubectl patch rollout webserver-api01-dev -n webserver-api01-dev \
  --type=merge -p '{"spec":{"abort":true}}'
```

Eso destruye el Green; el Blue (stable) sigue intacto. El step verifica `phase=Degraded` antes de exit.

### Verificación final

```bash
curl http://api01.localhost:8888/version
# Debe devolver v1.2.0

curl http://api01.localhost:8888/health
# {"status": "ok"}
```

### Guía interactiva (resumen visual)

```bash
make demo-bluegreen
```

---

## Demo 2 — Canary (webserver-api02)

**Objetivo**: gradualmente migrar el tráfico a la nueva versión: 5% → 25% → 50% → 100%, con load test antes del promote.

### Paso 1 — Crear y pushear el tag

```bash
cd /ruta/a/webserver-api02

git tag release/v1.2.0/dev
git push origin release/v1.2.0/dev
```

### Paso 2 — Monitorear el pipeline y el Rollout

```bash
# Pipeline visual
# http://tekton.localhost:8888/#/pipelineruns

# Rollout en otra terminal
kubectl argo rollouts get rollout webserver-api02-dev -n webserver-api02-dev --watch
```

### Paso 3 — Observar los pasos del Canary

Con strategy=canary, el Rollout avanza así (definido en `charts/pythonapps/templates/rollout.yaml`):

```
Step 1: setWeight 5    → Rollout pausa
Step 2: setWeight 25   → Rollout pausa
Step 3: setWeight 50   → Rollout pausa
(después de cada pausa el pipeline puede correr k6 si está configurado)
promote-full           → 100% canary → se convierte en stable
```

> En esta POC, el Stage 6 del pipeline hace **promote-full directo** (`status.promoteFull=true`) si el k6 pasa. Eso lleva el canary de su step actual a 100% en una sola operación. Para demos graduales sin promote-full, podés saltear el pipeline y correr a mano:
> ```bash
> kubectl argo rollouts promote webserver-api02-dev -n webserver-api02-dev
> ```
> (eso avanza un solo step a la vez)

### Paso 4 — Verificar la distribución de tráfico

Durante el canary (mientras esté en Step 1 al 3), podés ver la distribución:

```bash
# Stable — versión anterior
for i in $(seq 1 20); do
  curl -s http://api02.localhost:8888/version
done | sort | uniq -c
# Ejemplo en Step 1 (5%):
#   19 v1.1.x
#    1 v1.2.0
```

### Paso 5 — Guía interactiva

```bash
make demo-canary
```

---

## Demo 3 — RollingUpdate (cualquier app)

**Objetivo**: deployment simple sin pauses. Los pods se actualizan uno a uno; el pipeline corre un smoke test al final.

### Paso 1 — Configurar la app con strategy=rollingupdate

Editar el `values.yaml` del env de la app (en este repo: `charts/pythonapps/apps/<app>/<env>/values.yaml`) y setear:

```yaml
rollout:
  strategy: rollingupdate
```

Commit y push al gitops repo. ArgoCD lo aplica al Rollout.

### Paso 2 — Pushear el tag

```bash
cd /ruta/a/webserver-api01  # o webserver-api02

git tag release/v1.3.0/dev
git push origin release/v1.3.0/dev
```

### Paso 3 — El Rollout completa solo

A diferencia de BlueGreen y Canary, no hay pausa. El Stage 4 espera que el Rollout llegue a `phase=Healthy` directamente.

```bash
kubectl argo rollouts get rollout webserver-api01-dev -n webserver-api01-dev --watch
# Status: Healthy (sin Paused)
```

### Paso 4 — Stage 5 corre smoke test

Stage 5 corre `smoke.js` contra el stable service. Si pasa, el pipeline termina exitosamente. Si falla, Stage 6 hace `kubectl patch ... '{"spec":{"abort":true}}'`.

---

## Demo 4 — Pipeline manual (sin webhook)

Para demostrar el pipeline sin necesidad de pushear un tag de Git:

```bash
# BlueGreen manual (api01)
make pipeline-run APP=webserver-api01 TAG=v1.2.0

# Canary manual (api02)
make pipeline-run APP=webserver-api02 TAG=v1.2.0

# Monitorear visualmente
# http://tekton.localhost:8888/#/pipelineruns
```

> El PipelineRun manual usa `repo-url=https://github.com/Valentino-33/${APP}` y `revision=main`. Para cambiar el revision o environments, editá `manifests/tekton/pipelinerun-manual.yaml`.

---

## Demo 5 — Burn pipeline (HPA capacity test)

**Objetivo**: validar que el HPA escala el Rollout cuando el CPU supera el target. Es un pipeline **separado** del release — corre on-demand y no afecta el flujo de promote/rollback.

### Prerequisito — HPA habilitado

`charts/pythonapps/apps/<app>/<env>/values.yaml` debe tener:
```yaml
hpa:
  enabled: true
  minReplicas: 1
  maxReplicas: 5
  targetCPUUtilizationPercentage: 70
```

(ya viene habilitado por defecto para api01 y api02 en dev).

### Paso 1 — Disparar el burn

**Vía webhook** (desde el repo de la app):
```bash
cd /ruta/a/webserver-api01
git tag burn/dev
git push origin burn/dev
```

**Manual** (sin webhook):
```bash
make burn-test APP=webserver-api01 ENV=dev
```

### Paso 2 — Observar el HPA escalando en vivo

En otra terminal:
```bash
kubectl get hpa webserver-api01-dev -n webserver-api01-dev -w
```

Vas a ver algo como:
```
NAME                  REFERENCE                        TARGETS   MINPODS   MAXPODS   REPLICAS   AGE
webserver-api01-dev   Rollout/webserver-api01-dev      12%/70%   1         5         1          5m   ← baseline
webserver-api01-dev   Rollout/webserver-api01-dev      89%/70%   1         5         1          5m   ← burn empieza
webserver-api01-dev   Rollout/webserver-api01-dev      95%/70%   1         5         3          6m   ← HPA escaló
webserver-api01-dev   Rollout/webserver-api01-dev      45%/70%   1         5         3          7m   ← carga distribuida
```

### Paso 3 — Ver el resultado del PipelineRun

```bash
# Listar burn runs
kubectl get pipelinerun -n tekton-pipelines -l pipeline=burn

# Ver results del último
kubectl get pipelinerun -n tekton-pipelines -l pipeline=burn \
  -o jsonpath='{.items[-1].status.results}'
# Esperado:
# outcome=passed
# baseline-replicas=1
# max-replicas=3
```

O visualmente en `http://tekton.localhost:8888/#/pipelineruns` filtrado por `pipeline=burn`.

### Paso 4 — Re-correr

A diferencia del release pipeline (deterministic name), el burn usa `generateName` — cada run es independiente, no falla con AlreadyExists. Pero el tag git sí existe ya. Para re-pushear:
```bash
git tag -d burn/dev && git push --delete origin burn/dev
git tag burn/dev && git push origin burn/dev
```

O simplemente:
```bash
make burn-test APP=webserver-api01 ENV=dev
```
(no requiere borrar nada — el manual usa generateName del manifest local).

---

## Dashboard tour (después del deploy)

### Tekton Dashboard

```
http://tekton.localhost:8888
```

- **Pipelines / PipelineRuns**: lista de todos los runs con status badges
- Click en un run: **tree view (DAG)** de las 6 stages, con dependencias y status por step
- Click en un step: logs streaming, env vars, container info
- Botones de retry / cancel / rerun

Equivalente exacto a la sección "Pipelines" de OpenShift Console.

### ArgoCD

```
http://argocd.localhost:8888
User: admin
Pass: make argocd-password
```

- Ver las Applications: `webserver-api01-dev` y `webserver-api02-dev`
- Sync status, health status, historial de revisiones
- El Rollout aparece como resource tree dentro de la Application
- Botón "REFRESH" forza re-fetch del repo gitops (lo que hace el Stage 4 automáticamente)

### Grafana

```
http://grafana.localhost:8888
User: admin / Pass: belo-challenge
```

Dashboards provisionados automáticamente (via sidecar de kube-prometheus-stack):
- **webserver-api01 — request, latency, HPA** (uid `belo-api01`): RPS, p95/p99, error rate, pod count, HPA replicas vs target, CPU/mem por pod.
- **webserver-api02 — request, latency, HPA** (uid `belo-api02`): mismo set para api02.
- **belo — pipeline & rollouts overview** (uid `belo-pipeline`): Tekton TaskRun duration p95, Rollout phase transitions.

Para agregar uno nuevo: ver [docs/grafana-dashboards.md](grafana-dashboards.md).

### Kibana

```
http://kibana.localhost:8888
(sin autenticación — xpack.security deshabilitado en dev)
```

- Management → Index Patterns → crear `k8s-*`
- Discover → filtrar por `kubernetes.namespace_name: "webserver-api01-dev"`
- Los logs son JSON estructurado (structlog). Queries útiles en [docs/logging-efk.md](logging-efk.md).

### Headlamp

```
http://headlamp.localhost:8888
Token: kubectl create token headlamp -n kube-system
```

- Kubernetes dashboard general
- Buena para inspeccionar pods, services, ingresses, CRDs
- (Para PipelineRuns específicamente, Tekton Dashboard es mejor)

---

## Comandos de referencia rápida

```bash
# Estado general
make cluster-info
make cluster-status

# Rollout control manual (equivalente a lo que hace Stage 6 del pipeline)
# Estado en vivo:
kubectl argo rollouts get rollout webserver-api01-dev -n webserver-api01-dev --watch

# Promover BG manual:
kubectl patch rollout webserver-api01-dev -n webserver-api01-dev \
  --subresource=status --type=merge -p '{"status":{"pauseConditions":null}}'

# Promover canary --full manual:
kubectl patch rollout webserver-api02-dev -n webserver-api02-dev \
  --subresource=status --type=merge -p '{"status":{"promoteFull":true}}'

# Abort manual (cualquier strategy):
kubectl patch rollout <ROLLOUT> -n <NS> \
  --type=merge -p '{"spec":{"abort":true}}'

# Load tests locales (k6 debe estar instalado)
make load-test-smoke APP=webserver-api01
make load-test-bluegreen
make load-test-canary

# Burn pipeline (HPA capacity test, on-demand)
make burn-test APP=webserver-api01 ENV=dev
make burn-test APP=webserver-api02 ENV=dev

# Ver pipelines
kubectl -n tekton-pipelines get pipelineruns
tkn pipelinerun list -n tekton-pipelines
tkn pipelinerun logs -n tekton-pipelines --last -f

# Ver logs de las apps (cada una en su namespace = app-env)
kubectl -n webserver-api01-dev logs -l app.kubernetes.io/name=webserver-api01-dev -f
kubectl -n webserver-api02-dev logs -l app.kubernetes.io/name=webserver-api02-dev -f
```
