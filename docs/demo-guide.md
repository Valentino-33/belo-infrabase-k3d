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

# Verificar que los Rollouts existen
kubectl -n dev get rollouts
```

Asegurate de tener las entradas en el archivo `hosts` de Windows (`C:\Windows\System32\drivers\etc\hosts`):

```
127.0.0.1 argocd.localhost grafana.localhost kibana.localhost headlamp.localhost
127.0.0.1 api01.localhost preview-api01.localhost
127.0.0.1 api02.localhost preview-api02.localhost
127.0.0.1 tekton-webhook.localhost
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

El formato del tag es `<env>/<strategy>/<semver>`:

```bash
git tag dev/bluegreen/v1.2.0
git push origin dev/bluegreen/v1.2.0
```

> El tag dispara el webhook → EventListener filtra con CEL → crea PipelineRun automáticamente.

### Paso 3 — Monitorear el pipeline

```bash
# Ver el PipelineRun en tiempo real
tkn pipelinerun logs -n tekton-pipelines --last -f

# O con kubectl
kubectl -n tekton-pipelines get pipelineruns --watch
```

### Paso 4 — Ver el estado del Rollout durante Stage 4

```bash
kubectl argo rollouts get rollout webserver-api01 -n dev --watch
```

Vas a ver algo como:
```
Name:            webserver-api01
Namespace:       dev
Status:          ॥ Paused
Message:         BlueGreenPause
...
  canary  webserver-api01-<hash>  2          2          2          2          <timestamp>
  stable  webserver-api01-<hash>  2          2          2          2          <timestamp>
```

### Paso 5 — Verificar el preview (Green) mientras Stage 5 corre el k6

```bash
# Stable (Blue) — versión anterior
curl http://api01.localhost:8888/version

# Preview (Green) — nueva versión
curl http://preview-api01.localhost:8888/version
```

### Paso 6 — Ver el resultado del pipeline

Si el k6 pasa:
- Stage 6 ejecuta `kubectl argo rollouts promote webserver-api01`
- El tráfico cambia al Green
- El Blue se elimina en 30 segundos

Si el k6 falla:
- Stage 6 ejecuta `kubectl argo rollouts abort webserver-api01`
- El Green se destruye
- El Blue (stable) sigue intacto

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

**Objetivo**: gradualmente migrar el tráfico a la nueva versión: 5% → 25% → 50% → 100%, con load test en cada paso.

### Paso 1 — Crear y pushear el tag

```bash
cd /ruta/a/webserver-api02

git tag dev/canary/v1.2.0
git push origin dev/canary/v1.2.0
```

### Paso 2 — Monitorear el pipeline y el Rollout

```bash
# Pipeline
tkn pipelinerun logs -n tekton-pipelines --last -f

# Rollout (en otra terminal)
kubectl argo rollouts get rollout webserver-api02 -n dev --watch
```

### Paso 3 — Observar los pasos del Canary

Con strategy=canary, el Rollout avanza así:

```
Step 1: setWeight 5    → Rollout pausa (Stage 5 corre k6)
Step 2: setWeight 25   → Rollout pausa (Stage 5 corre k6)
Step 3: setWeight 50   → Rollout pausa (Stage 5 corre k6)
promote-full           → 100% canary → se convierte en stable
```

> En esta POC, el pipeline hace `kubectl argo rollouts promote --full` en un solo paso (Stage 6) si el k6 pasó. Para demos más lentas, usá `make rollout-promote APP=webserver-api02` paso a paso.

### Paso 4 — Verificar la distribución de tráfico

Durante el canary (mientras esté en Step 1 al 3), podés ver la distribución:

```bash
# Stable — versión anterior
for i in $(seq 1 20); do
  curl -s http://api02.localhost:8888/version
done
# ~95% deben devolver v1.1.x, ~5% v1.2.0 (en Step 1)
```

### Paso 5 — Guía interactiva

```bash
make demo-canary
```

---

## Demo 3 — RollingUpdate (cualquier app)

**Objetivo**: deployment simple sin pauses. Los pods se actualizan uno a uno; el pipeline corre un smoke test al final.

### Paso 1 — Crear el tag con strategy rollingupdate

```bash
cd /ruta/a/webserver-api01  # o webserver-api02

git tag dev/rollingupdate/v1.3.0
git push origin dev/rollingupdate/v1.3.0
```

### Paso 2 — El Rollout completa solo

A diferencia de BlueGreen y Canary, no hay pausa. El Stage 4 espera que el Rollout llegue a `Healthy` directamente.

```bash
kubectl argo rollouts get rollout webserver-api01 -n dev --watch
# Status: Healthy (sin Paused)
```

### Paso 3 — Stage 5 corre smoke test

El Stage 5 corre `smoke.js` contra el stable service. Si pasa, el pipeline termina exitosamente. Si falla, Stage 6 hace `kubectl rollout undo`.

---

## Demo 4 — Pipeline manual (sin webhook)

Para demostrar el pipeline sin necesidad de pushear un tag de Git:

```bash
# BlueGreen manual
make pipeline-run APP=webserver-api01 TAG=v1.2.0

# Canary manual
make pipeline-run APP=webserver-api02 TAG=v1.2.0

# Monitorear
tkn pipelinerun logs -n tekton-pipelines --last -f
```

> El PipelineRun manual usa `strategy=bluegreen` por defecto. Para cambiar la estrategia, editá `manifests/tekton/pipelinerun-manual.yaml`.

---

## Dashboard tour (después del deploy)

### ArgoCD

```
http://argocd.localhost:8888
User: admin
Pass: make argocd-password
```

- Ver las Applications: `webserver-api01-dev` y `webserver-api02-dev`
- Sync status, health status, historial de revisiones
- El Rollout aparece como resource tree dentro de la Application

### Grafana

```
http://grafana.localhost:8888
User: admin / Pass: belo-challenge
```

- Dashboard "Kubernetes / Pods" → ver CPU/Memory de los pods durante el rollout
- Métricas de la app: `api01_requests_total`, `api01_request_duration_seconds`

### Kibana

```
http://kibana.localhost:8888
(sin autenticación — xpack.security deshabilitado en dev)
```

- Management → Index Patterns → crear `k8s-*`
- Discover → filtrar por `kubernetes.labels.app_name: webserver-api01`
- Los logs son JSON estructurado (structlog)

### Headlamp

```
http://headlamp.localhost:8888
Token: kubectl create token headlamp -n kube-system
```

- Kubernetes dashboard alternativo
- Ver pods, services, ingresses del namespace `dev`

---

## Comandos de referencia rápida

```bash
# Estado general
make cluster-info
make cluster-status

# Rollout control manual
make rollout-status APP=webserver-api01    # ver estado en vivo
make rollout-promote APP=webserver-api01   # promover (BG/Canary)
make rollout-abort APP=webserver-api01     # abortar/rollback

# Load tests locales (k6 debe estar instalado)
make load-test-smoke APP=webserver-api01
make load-test-bluegreen
make load-test-canary

# Ver pipelines
kubectl -n tekton-pipelines get pipelineruns
tkn pipelinerun list -n tekton-pipelines
tkn pipelinerun logs -n tekton-pipelines --last -f

# Ver logs de las apps
kubectl -n dev logs -l app.kubernetes.io/name=webserver-api01 -f
kubectl -n dev logs -l app.kubernetes.io/name=webserver-api02 -f
```
