# POC — Comandos paso a paso para la demo

Playbook ejecutable end-to-end. Cada sección tiene los comandos exactos, qué esperar como output, y qué hacer si algo no anda.

**Pre-condición**: cluster k3d `belo-challenge` corriendo, secretos aplicados, ArgoCD bootstraped.

**Estado validado al cierre de esta iteración (2026-05-12)**:
- api01 v0.5.1 corriendo Healthy con código bajo `/api01/*`
- api02 v0.1.0 corriendo Healthy con código bajo `/api02/*` + catálogo + echo
- EFK ingestando logs JSON al índice `k8s-YYYY.MM.DD` (índice creado, 9.7k+ docs)
- Index pattern `k8s-*` creado en Kibana
- 4 dashboards en Grafana: `belo-api01`, `belo-api02`, `belo-pipeline`, `belo-dev-cluster`
- EventListener con 2 triggers: `github-tag-release` + `github-tag-burn`

---

## 0. Verificación previa (1 min)

```bash
cd C:/Users/tadeo/OneDrive/Escritorio/bellochallenge-k3d/belo-infrabase-k3d
make pipeline-check
```

**Esperás ver**:
- Pipelines: `pythonapps-pipeline` + `pythonapps-burn-pipeline`
- EventListener triggers: `github-tag-release` Y `github-tag-burn`
- Pod del EventListener Running

Si falta algo: `make tekton-apply`.

Verificar apps healthy:
```bash
kubectl get rollout -A | grep -E "Healthy|Paused"
curl -s http://api01.localhost:8888/api01/version
curl -s http://api02.localhost:8888/api02/version
```

**Esperás**: `{"service":"webserver-api01","version":"v0.5.1",...}` y `{"service":"webserver-api02","version":"v0.1.0",...}`.

---

## 1. Demo Blue/Green — api01 (5 min)

Abrí 3 pestañas/terminales antes de empezar:

```
Terminal A:  kubectl get rollout webserver-api01-dev -n webserver-api01-dev -o wide -w
Terminal B:  kubectl get pods -n webserver-api01-dev -w
Browser:     http://tekton.localhost:8888/#/pipelineruns
```

### Disparar el release

```bash
cd C:/Users/tadeo/OneDrive/Escritorio/belochallenge/webserver-api01
git tag release/v0.6.0/dev
git push origin release/v0.6.0/dev
```

> Esto dispara el webhook GitHub → EventListener trigger `github-tag-release` → crea PipelineRun `webserver-api01-pipelinerun-v0.6.0`.

### Qué va a pasar (~3 min total)

| Stage | Duración | Qué hace |
|---|---|---|
| 1. clone | ~10s | git clone de `webserver-api01` en la ref del tag |
| 2. build-push | ~30s | Kaniko build + push `valentinobruno/webserver-api01:v0.6.0` |
| 3. bump-gitops | ~10s | yq `image.tag = v0.6.0` en `apps/webserver-api01/dev/values.yaml` + git push |
| 4. wait-argocd | ~20s | force-refresh ArgoCD + esperar sync.revision == commit-sha + Rollout phase=Paused |
| 5. load-test | ~3 min | k6 ramp hasta 1000 VUs contra preview svc (`load-bluegreen.js`) |
| 6. promote-rollback | ~10s | `kubectl patch status.pauseConditions=null` → switchover blue→green |

### Verificación en vivo

Durante Stage 4-5, en Terminal A vas a ver:
```
Phase: Paused
stableRS: 7df8587555 (v0.5.1 — blue)
currentPodHash: <nuevo hash> (v0.6.0 — green)
activeSelector: 7df8587555 (blue todavía)
previewSelector: <nuevo hash> (green)
```

Mientras el k6 corre, en otra terminal:
```bash
curl http://preview-api01.localhost:8888/api01/version    # green (v0.6.0)
curl http://api01.localhost:8888/api01/version             # stable (v0.5.1)
```

Después del Stage 6, `api01.localhost` devuelve v0.6.0.

### Si falla

- Stage 5 da errors > 10%: la app tiene capacidad chica. Cambiá `replicas: 3` en `dev/values.yaml` y re-tagueá.
- Stage 4 timeout: ArgoCD no syncó. `kubectl annotate app webserver-api01-dev -n argocd argocd.argoproj.io/refresh=normal --overwrite`.
- Stage 6 abort por outcome=failed: ver logs `tkn pipelinerun logs <run-name> -n tekton-pipelines | grep -A30 "STAGE 5"`.

---

## 2. Demo Canary — api02 (5 min)

```
Terminal A:  kubectl get rollout webserver-api02-dev -n webserver-api02-dev -o wide -w
Browser:     http://tekton.localhost:8888/#/pipelineruns
```

### Disparar el release

```bash
cd C:/Users/tadeo/OneDrive/Escritorio/belochallenge/webserver-api02
git tag release/v0.2.0/dev
git push origin release/v0.2.0/dev
```

### Qué va a pasar

El Rollout de api02 tiene strategy=canary con 3 steps:
- setWeight 5 → pausa
- setWeight 25 → pausa
- setWeight 50 → pausa
- (Stage 6 patcha `promoteFull=true` que salta a 100%)

### Mostrar el split de tráfico

Mientras está paused en setWeight=5 o 25, en otra terminal:

```bash
# Hacé 30 requests, contá cuántos respondió cada versión
for i in $(seq 1 30); do curl -s http://api02.localhost:8888/api02/version | jq -r .version; done | sort | uniq -c
```

**Esperás** algo como:
```
  27 v0.1.0   ← stable
   3 v0.2.0   ← canary (5%)
```

### Endpoint nuevo solo en api02

```bash
curl http://api02.localhost:8888/api02/items | jq .total
curl http://api02.localhost:8888/api02/items/3
curl "http://api02.localhost:8888/api02/echo?msg=hola"
```

---

## 3. Burn pipeline — HPA capacity test (4 min)

Pipeline **separado** del release. Demuestra que el HPA escala bajo carga.

### Disparar vía tag (webhook)

```bash
cd C:/Users/tadeo/OneDrive/Escritorio/belochallenge/webserver-api01
git tag burn/dev
git push origin burn/dev
```

> Tag formato `burn/<env>` → trigger `github-tag-burn` → pipeline `pythonapps-burn-pipeline`.

### O disparar manual (sin webhook)

```bash
make burn-test APP=webserver-api01 ENV=dev
```

### Observar en vivo

```bash
# Terminal A: HPA
kubectl get hpa webserver-api01-dev -n webserver-api01-dev -w

# Terminal B: replicas
kubectl get rollout webserver-api01-dev -n webserver-api01-dev -w
```

**Vas a ver**:
```
NAME                  REFERENCE                       TARGETS    MIN  MAX  REPLICAS  AGE
webserver-api01-dev   Rollout/webserver-api01-dev     5%/70%      2    5    2          ← baseline
webserver-api01-dev   Rollout/webserver-api01-dev     189%/70%    2    5    2          ← burn empieza
webserver-api01-dev   Rollout/webserver-api01-dev     245%/70%    2    5    4          ← HPA escaló
webserver-api01-dev   Rollout/webserver-api01-dev     80%/70%     2    5    4          ← más capacidad
```

### Ver resultado

```bash
RUN=$(kubectl get pipelinerun -n tekton-pipelines -l pipeline=burn --sort-by='.metadata.creationTimestamp' -o jsonpath='{.items[-1].metadata.name}')
kubectl get pipelinerun $RUN -n tekton-pipelines -o jsonpath='{range .status.results[*]}{.name}={.value}{"\n"}{end}'
# Esperás:
# outcome=passed
# baseline-replicas=2
# max-replicas=4
```

Para burn de api02:
```bash
cd C:/Users/tadeo/OneDrive/Escritorio/belochallenge/webserver-api02
git tag -d burn/dev 2>/dev/null && git push --delete origin burn/dev 2>/dev/null  # cleanup si ya existía
git tag burn/dev
git push origin burn/dev
# O: make burn-test APP=webserver-api02 ENV=dev
```

---

## 4. Observabilidad — Kibana + Grafana (5 min)

### Kibana — logs reales de los APIs

URL: http://kibana.localhost:8888

1. **Discover** (icono brújula en la izquierda)
2. Seleccionar data view **`k8s-*`** (ya está creado)
3. Time range: **Last 15 minutes**

**Queries útiles** (KQL):

```
kubernetes.namespace_name : "webserver-api01-dev" and path : "/api01/hello"
```
→ Todos los hits al endpoint de negocio de api01 durante el load test.

```
kubernetes.namespace_name : "webserver-api02-dev" and status : 200
```
→ Requests exitosos a api02.

```
kubernetes.labels.app_kubernetes_io/instance : "webserver-api01-dev" and (status >= 500 or level : "error")
```
→ Solo errores (vacío en estado normal).

```
event : "startup"
```
→ Cada vez que un pod arrancó, con su versión. Útil para ver qué versión está activa.

> Si Kibana dice "No results found" pero hay docs, ampliá el time range a "Last 1 hour" o "Today".

### Grafana — dashboards

URL: http://grafana.localhost:8888 (admin / belo-challenge)

**4 dashboards provisionados** (Browse → tag `belo-challenge`):

| Dashboard | UID | Qué muestra |
|---|---|---|
| **belo — DEV cluster overview** | `belo-dev-cluster` | Vista centralizada del ambiente dev: replicas, RPS, error rate, p95/p99, HPA, recursos por pod y nodo, Tekton TaskRuns |
| webserver-api01 | `belo-api01` | Específico de api01: RPS por endpoint, p95/p99, HPA, CPU/mem |
| webserver-api02 | `belo-api02` | Específico de api02: mismo set |
| belo — pipeline & rollouts | `belo-pipeline` | Tekton runs, durations, rollout phases |

**Para la demo**: empezá con `belo-dev-cluster` (vista de cluster), después zoom-in a `belo-api01` o `belo-api02` cuando quieras detalle.

### URLs directas (copy-paste en browser)

```
http://grafana.localhost:8888/d/belo-dev-cluster
http://grafana.localhost:8888/d/belo-api01
http://grafana.localhost:8888/d/belo-api02
http://grafana.localhost:8888/d/belo-pipeline
http://kibana.localhost:8888/app/discover
http://tekton.localhost:8888/#/pipelineruns
http://argocd.localhost:8888
```

---

## 5. Rollback automático (opcional, 3 min)

Demuestra que un release con bug se rollbackea solo.

```bash
cd C:/Users/tadeo/OneDrive/Escritorio/belochallenge/webserver-api01
# Editar app/main.py: comentar el endpoint /api01/health (probe va a fallar)
# git commit -m "intentional break"
git tag release/v0.6.99/dev
git push origin release/v0.6.99/dev
```

**Qué va a pasar**:
- Stage 4 espera el Rollout en Paused — pero los pods nuevos no pasan readinessProbe (no hay /api01/health) → pod queda en NotReady
- Eventualmente Stage 4 timeout O Stage 5 falla con thresholds
- Stage 6 emite `kubectl patch spec.abort=true`
- Green RS se destruye, stable (v0.6.0) queda intacto sirviendo

Verificación: `curl http://api01.localhost:8888/api01/version` sigue devolviendo v0.6.0.

---

## Comandos de emergencia

### Si el cluster se rompe

```bash
make cluster-status
make pipeline-check
make burn-check
```

### Forzar re-sync de ArgoCD (sin esperar polling de 3min)

```bash
kubectl annotate app webserver-api01-dev -n argocd argocd.argoproj.io/refresh=normal --overwrite
kubectl annotate app webserver-api02-dev -n argocd argocd.argoproj.io/refresh=normal --overwrite
```

### Promover Rollout BG manual

```bash
kubectl patch rollout webserver-api01-dev -n webserver-api01-dev \
  --subresource=status --type=merge -p '{"status":{"pauseConditions":null}}'
```

### Promover canary --full manual

```bash
kubectl patch rollout webserver-api02-dev -n webserver-api02-dev \
  --subresource=status --type=merge -p '{"status":{"promoteFull":true}}'
```

### Abort cualquier Rollout

```bash
kubectl patch rollout <name> -n <ns> --type=merge -p '{"spec":{"abort":true}}'
```

### Limpiar PipelineRuns viejos

```bash
kubectl delete pipelinerun --all -n tekton-pipelines
```

### Re-tagueo de un tag burn

```bash
cd /ruta/al/app
git tag -d burn/dev && git push --delete origin burn/dev
git tag burn/dev && git push origin burn/dev
```

### Recrear el index pattern de Kibana si desapareciera

```bash
KIBANA_POD=$(kubectl get pod -n logging -l app=kibana -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n logging $KIBANA_POD -- curl -s -X POST "http://localhost:5601/api/data_views/data_view" \
  -H "kbn-xsrf: true" -H "Content-Type: application/json" \
  -d '{"data_view":{"title":"k8s-*","name":"k8s logs","timeFieldName":"@timestamp"}}'
```

### Re-aplicar Tekton + dashboards + fluent-bit después de un git pull

```bash
make refresh
```

---

## Flujo completo end-to-end (15-20 min total)

1. `make pipeline-check` (1 min)
2. **Demo BG api01**: `git tag release/v0.6.0/dev` desde repo api01 (5 min)
3. **Demo Canary api02**: `git tag release/v0.2.0/dev` desde repo api02 (5 min)
4. **Burn pipeline**: `git tag burn/dev` o `make burn-test ...` (4 min)
5. **Tour de observabilidad**: Grafana `belo-dev-cluster` + Kibana queries (3 min)
6. **Opcional**: rollback con tag que falla (3 min)

---

## Cosas que NO mostrar en la demo (saben fallar o son lentas)

- **Pipeline en producción** (env=production): tiene gate manual, no autoprometia
- **Re-pushear el MISMO release tag**: falla con AlreadyExists (intencional). Para re-correr: `kubectl delete pipelinerun <name> -n tekton-pipelines`
- **Rollout abort durante un BG paused**: el scaleDownDelaySeconds=30 hace que blue tarde 30s en irse — paciencia

---

## URLs + credenciales (cheat sheet)

| Servicio | URL | Cred |
|---|---|---|
| ArgoCD | http://argocd.localhost:8888 | admin / `make argocd-password` |
| Grafana | http://grafana.localhost:8888 | admin / belo-challenge |
| Kibana | http://kibana.localhost:8888 | sin auth |
| Tekton Dashboard | http://tekton.localhost:8888 | sin auth |
| Headlamp | http://headlamp.localhost:8888 | `kubectl create token headlamp -n kube-system` |
| api01 stable | http://api01.localhost:8888 | — |
| api01 preview | http://preview-api01.localhost:8888 | — |
| api02 stable | http://api02.localhost:8888 | — |
| api02 preview | http://preview-api02.localhost:8888 | — |

> Verificá `C:\Windows\System32\drivers\etc\hosts` tiene todos esos hostnames apuntando a 127.0.0.1.

Suerte.
