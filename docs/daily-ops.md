# Daily ops — encender y apagar el cluster

Guía corta para usar el cluster día a día sin perder estado. Los addons (ArgoCD, Tekton, Prometheus, etc.) y las apps deployadas se preservan entre sesiones — solo se apaga el "motor".

---

## Comandos

| Comando | Para qué | ¿Preserva estado? |
|---------|----------|------------------|
| `make cluster-stop` | Apagar al final del día | ✅ sí |
| `make cluster-start` | Encender al día siguiente | ✅ retoma desde donde dejaste |
| `make cluster-down` | Eliminar TODO (cluster + volúmenes) | ❌ destructivo — solo para teardown completo |
| `make cluster-up` | Crear cluster de cero | (para primera vez o después de `cluster-down`) |

Por debajo: `make cluster-stop` ejecuta `k3d cluster stop`, que pausa los containers de Docker que contienen los nodos k3s pero no los elimina. `make cluster-start` los re-arranca y el estado del etcd, los PVCs (local-path) y las configs siguen intactos.

---

## Al final del día (apagar)

```bash
# 1. (opcional) Si tenés un ngrok corriendo (make tunnel), matalo con Ctrl-C
#    o desde otra terminal:
pkill -f "ngrok http"

# 2. Apagar el cluster (preserva estado)
make cluster-stop

# 3. (opcional) Cerrar Docker Desktop para liberar RAM
```

Después de esto podés cerrar la PC tranquilo. El estado del cluster vive en los volúmenes de Docker.

---

## Al día siguiente (encender)

```bash
# 1. Abrir Docker Desktop y esperar 30s a que esté listo
#    (el ícono de la barra de tareas debe estar verde)

# 2. Reanudar el cluster
cd C:\Users\tadeo\OneDrive\Escritorio\bellochallenge-k3d\belo-infrabase-k3d
make cluster-start
```

`make cluster-start` automáticamente:
- Verifica que Docker esté corriendo
- Hace `k3d cluster start belo-challenge`
- Fija el contexto kubectl
- Espera a que los nodos estén Ready
- Espera a que ArgoCD, el EventListener y el Tekton Dashboard estén disponibles

Cuando termina, tenés el cluster en el mismo estado que cuando hiciste `cluster-stop` — mismas apps, mismos Rollouts, mismos PipelineRuns en el historial.

### Verificación rápida post-start

```bash
# Estado general
make cluster-status

# Apps de ArgoCD
kubectl -n argocd get applications

# PipelineRuns previos siguen en el historial
kubectl -n tekton-pipelines get pipelineruns

# UIs siguen accesibles (sin hacer nada más):
# - http://argocd.localhost:8888
# - http://tekton.localhost:8888
# - http://grafana.localhost:8888
# - http://api01.localhost:8888
```

---

## Re-disparar un pipeline después del start

### Opción A — manual (recomendado para testing rápido)

```bash
make pipeline-run APP=webserver-api01 TAG=v0.5.0
```

> El nombre del PipelineRun es determinístico: `webserver-api01-pipelinerun-v0.5.0`. Re-correr el mismo `TAG` falla con `AlreadyExists` — usá un semver nuevo.

### Opción B — via webhook de GitHub

```bash
# 1. Re-abrir el tunnel ngrok (cada start trae URL nueva — limitación de free tier)
make tunnel
```

ngrok va a mostrar una URL nueva tipo `https://xyz789.ngrok-free.app`. Tenés que:

```bash
# 2. Actualizar el webhook en GitHub
#    Repo de la app → Settings → Webhooks → editar el webhook existente:
#    Payload URL: https://xyz789.ngrok-free.app   ← URL nueva
#    Save changes
```

```bash
# 3. Pushear un tag nuevo desde el repo de la app
cd C:\Users\tadeo\OneDrive\Escritorio\belochallenge\webserver-api01
git tag release/v0.5.0/dev
git push origin release/v0.5.0/dev
```

```bash
# 4. Monitorear (en otra terminal o en el dashboard)
# Visual: http://tekton.localhost:8888/#/namespaces/tekton-pipelines/pipelineruns/webserver-api01-pipelinerun-v0.5.0
# CLI:
kubectl -n tekton-pipelines get pipelinerun webserver-api01-pipelinerun-v0.5.0 -w
```

---

## Troubleshooting del start

### `make cluster-start` dice `Docker no responde`

Docker Desktop no terminó de arrancar todavía. Esperá ~30s y reintentá.

### Nodos en estado `NotReady` después del start

A veces los pods de control plane tardan un poco. Esperá 30-60s y verificá:

```bash
kubectl get nodes
kubectl -n kube-system get pods | grep -v Running
```

Si después de 2 minutos sigue NotReady, ver logs:

```bash
docker logs k3d-belo-challenge-server-0 2>&1 | tail -50
```

### ArgoCD apps en `Unknown` o `OutOfSync` después del start

Es normal durante los primeros 30-60s. Forzar refresh:

```bash
kubectl annotate app webserver-api01-dev -n argocd \
  argocd.argoproj.io/refresh=normal --overwrite
kubectl annotate app webserver-api02-dev -n argocd \
  argocd.argoproj.io/refresh=normal --overwrite
```

### PSA `enforce=restricted` volvió al namespace `tekton-pipelines`

Eso pasa solo si re-instalaste Tekton (`kubectl apply -f .../release.yaml`). `cluster-stop`/`cluster-start` NO toca los labels del namespace.

Si lo ves de nuevo:

```bash
kubectl label namespace tekton-pipelines \
  pod-security.kubernetes.io/enforce=baseline --overwrite
```

---

## Cuándo usar `cluster-down` en vez de `cluster-stop`

Solo si:
- Querés recrear el cluster con cambios en `k3d/config.yaml` (puertos, nodos, networking)
- El cluster quedó en estado roto y querés borrar todo
- Cambiaste de máquina y querés un fresh start
- Estás cerrando el proyecto completamente

En esos casos:

```bash
make cluster-down       # destruye todo (pide confirm visual, no real)
make all                # recrea desde cero
make secrets-apply DOCKERHUB_USER=... DOCKERHUB_TOKEN=... GITHUB_TOKEN=...
make images-initial DOCKERHUB_USER=...
# Y re-instalar Tekton Dashboard:
kubectl apply -f https://storage.googleapis.com/tekton-releases/dashboard/latest/release.yaml
kubectl apply -f manifests/tekton/dashboard-ingress.yaml
# Bajar el PSA del namespace tekton-pipelines a baseline (kaniko):
kubectl label namespace tekton-pipelines \
  pod-security.kubernetes.io/enforce=baseline --overwrite
```

---

## Resumen visual

```
┌────────────────────────────────────────────────────────────────┐
│                      DAILY OPS                                  │
├────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Primera vez:        make cluster-up + secrets + images + boot  │
│                                                                 │
│  Final del día:      make cluster-stop                          │
│  Día siguiente:      make cluster-start                         │
│                                                                 │
│  Re-disparar:        make pipeline-run APP=... TAG=vX.Y.Z       │
│                      o                                          │
│                      make tunnel + actualizar webhook GitHub    │
│                      + git push tag                             │
│                                                                 │
│  Teardown final:     make cluster-down  (destructivo)           │
│                                                                 │
└────────────────────────────────────────────────────────────────┘
```
