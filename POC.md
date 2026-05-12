# POC — Playbook completo de la demo

Comandos paso a paso, validados end-to-end.

## Estado validado (2026-05-12)

| Componente | Estado |
|---|---|
| **api01 release pipeline v0.7.0** | ✅ 6 stages Succeeded (clone → build → bump → wait-argocd → load-test → promote-rollback) |
| **api02 release pipeline v0.2.0** | ✅ 6 stages Succeeded |
| **Burn pipeline** | ✅ HPA escaló api01 de 3 → 7 replicas durante el burn |
| **Apps healthy** | api01 v0.7.0 (3 replicas) + api02 v0.2.0 (3 replicas) |
| **EFK ingestando** | ~15k+ docs/día en `k8s-YYYY.MM.DD`, JSON parseado a campos top-level |
| **Kibana** | 5 saved searches + dashboard `belo-cluster-overview` |
| **Grafana** | 4 dashboards (api01, api02, dev-cluster, pipeline — todos con datos reales) |
| **Tekton metrics** | Scrapeado por Prometheus (`tekton_pipelines_controller_*`) |
| **Argo Rollouts metrics** | Scrapeado (`rollout_info`, `rollout_phase`, `rollout_reconcile_*`) |

---

## 0. Verificación previa (1 min)

```bash
cd C:/Users/tadeo/OneDrive/Escritorio/bellochallenge-k3d/belo-infrabase-k3d
make pipeline-check
```

Tiene que mostrar:
- Pipelines: `pythonapps-pipeline` + `pythonapps-burn-pipeline`
- Triggers: `github-tag-release` + `github-tag-burn`
- EventListener pod Running

Si falta algo: `make tekton-apply`.

```bash
# Apps healthy
curl -s http://api01.localhost:8888/api01/version
# {"service":"webserver-api01","version":"v0.7.0","strategy":"bluegreen"}

curl -s http://api02.localhost:8888/api02/version
# {"service":"webserver-api02","version":"v0.2.0",...}

# HPA enabled (min:3 max:7 target:50%)
kubectl get hpa -A | grep webserver
```

---

## 1. Demo Blue/Green — api01 (~5 min)

Abrí 3 terminales/pestañas antes:

```
Terminal A:  kubectl get rollout webserver-api01-dev -n webserver-api01-dev -o wide -w
Terminal B:  kubectl get pods -n webserver-api01-dev -w
Browser:     http://tekton.localhost:8888/#/pipelineruns
```

### Disparar release

```bash
cd C:/Users/tadeo/OneDrive/Escritorio/belochallenge/webserver-api01
git tag release/v0.8.0/dev
git push origin release/v0.8.0/dev
```

### Stages esperados (~3-4 min total)

| Stage | Duración | Qué hace |
|---|---|---|
| 1. clone | ~10s | git clone @ tag |
| 2. build-push | ~30s | Kaniko build + push `webserver-api01:v0.8.0` |
| 3. bump-gitops | ~10s | yq image.tag + git push al gitops repo |
| 4. wait-argocd | ~20s | force-refresh ArgoCD + esperar sync + Rollout Paused |
| 5. load-test | ~3min | k6 ramp hasta 500 VUs contra preview svc |
| 6. promote-rollback | ~10s | patch status.pauseConditions=null → switchover blue→green |

### Verificación durante Stage 4-5

Terminal A va a mostrar el Rollout Paused con blue (v0.7.0 activo) y green (v0.8.0 preview):

```bash
# Vivo, mientras el k6 corre:
curl http://preview-api01.localhost:8888/api01/version   # → v0.8.0 (green RS preview)
curl http://api01.localhost:8888/api01/version            # → v0.7.0 (blue todavía activo)
```

Después del Stage 6, ambos URLs devuelven v0.8.0.

---

## 2. Demo Canary — api02 (~5 min)

```bash
cd C:/Users/tadeo/OneDrive/Escritorio/belochallenge/webserver-api02
git tag release/v0.3.0/dev
git push origin release/v0.3.0/dev
```

Durante el canary paused (setWeight 5 o 25), mostrar el split de tráfico:

```bash
for i in $(seq 1 30); do curl -s http://api02.localhost:8888/api02/version | jq -r .version; done | sort | uniq -c
# Esperás algo como:
#   27 v0.2.0   ← stable
#    3 v0.3.0   ← canary 10% (aprox)
```

Endpoints exclusivos de api02 (api01 no los tiene):

```bash
curl http://api02.localhost:8888/api02/items | jq
curl http://api02.localhost:8888/api02/items/3
curl "http://api02.localhost:8888/api02/echo?msg=demo"
```

---

## 3. Burn pipeline — HPA capacity test (~3-4 min)

Pipeline **separado** del release. Demuestra que el HPA escala bajo carga.

```bash
cd C:/Users/tadeo/OneDrive/Escritorio/belochallenge/webserver-api01
# Si ya pusheaste burn/dev antes, borrarlo primero:
git tag -d burn/dev 2>/dev/null && git push --delete origin burn/dev 2>/dev/null
git tag burn/dev
git push origin burn/dev
```

O sin webhook:

```bash
make burn-test APP=webserver-api01 ENV=dev
```

### Observar en vivo

```bash
# Terminal A:
kubectl get hpa webserver-api01-dev -n webserver-api01-dev -w

# Vas a ver:
# REPLICAS  AGE
# 3                              ← baseline (minReplicas)
# 3   (burn empieza, CPU sube)
# 5   ← HPA escaló (target 50% cruzado)
# 7   ← HPA escaló al máximo
# (cooldown 5 min después del fin del burn)
# 3   ← vuelve a baseline
```

### Ver resultado

```bash
RUN=$(kubectl get pipelinerun -n tekton-pipelines -l pipeline=burn,app=webserver-api01 --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
kubectl get pipelinerun $RUN -n tekton-pipelines -o yaml | grep -A2 "name: outcome\|name: max-replicas\|name: baseline"
# Esperás: outcome=passed, baseline-replicas=3, max-replicas=>=4
```

---

## 4. Kibana — logs reales con saved searches preconfiguradas

http://kibana.localhost:8888

### Dashboard preferido

**Analytics → Dashboard → "Belo — Cluster DEV (logs + saved searches)"**

Una sola vista con 5 paneles:
1. **Logs cluster DEV** — todos los logs ordenados por @timestamp desc, columnas: `level + kubernetes.pod_name + kubernetes.namespace_name + log`
2. **api01 requests** — solo `/api01/hello`, columnas: `status + method + path + version + pod_name`
3. **api02 requests** — solo endpoints de negocio (no probes)
4. **ERRORES** — `status >= 400 or level: (error or warning)`
5. **Tekton Pipeline logs** — logs de cualquier stage de cualquier PipelineRun

### Saved searches sueltas (Analytics → Discover → Open)

| Nombre | Query | Columnas |
|---|---|---|
| `Logs cluster DEV (level + pod + log)` | (vacío) | level, pod_name, namespace, log |
| `api01 — requests con status` | namespace=api01-dev + path=/hello | status, method, path, version, pod |
| `api02 — requests con status` | namespace=api02-dev sin health | status, method, path, version, pod |
| `ERRORES — solo 4xx/5xx o error/warning` | status>=400 or level=error/warning | status, level, pod, log |
| `Tekton Pipeline logs` | namespace=tekton-pipelines | pod, container, log |

### KQL queries útiles (Discover libre)

```
kubernetes.namespace_name : "webserver-api01-dev" and path : "/api01/hello"
event : "request" and status >= 400
kubernetes.namespace_name : "tekton-pipelines" and kubernetes.pod_name : *pipelinerun-v0.7.0*
event : "startup"
```

---

## 5. Grafana — dashboards con datos reales

http://grafana.localhost:8888 (admin / belo-challenge)

| Dashboard | URL | Qué muestra |
|---|---|---|
| **belo — DEV cluster overview** | http://grafana.localhost:8888/d/belo-dev-cluster | Vista centralizada: replicas, RPS, error rate, p95/p99 de ambas apps lado a lado, HPA current vs desired, CPU/mem por pod y por nodo, Tekton durations |
| webserver-api01 | http://grafana.localhost:8888/d/belo-api01 | RPS por endpoint, p95/p99, HPA |
| webserver-api02 | http://grafana.localhost:8888/d/belo-api02 | Mismo para api02 |
| **belo — pipeline & rollouts** | http://grafana.localhost:8888/d/belo-pipeline | Tabla rollouts (namespace/strategy/phase), TaskRun duration p95, PipelineRun count por status, Argo reconcile durations |

---

## 6. Tour final (lo que mostrar)

```
1. Tekton Dashboard:    http://tekton.localhost:8888/#/pipelineruns
2. ArgoCD:              http://argocd.localhost:8888  (admin / make argocd-password)
3. Grafana DEV cluster: http://grafana.localhost:8888/d/belo-dev-cluster
4. Grafana pipeline:    http://grafana.localhost:8888/d/belo-pipeline
5. Kibana dashboard:    http://kibana.localhost:8888/app/dashboards#/view/belo-cluster-overview
6. Apps:                http://api01.localhost:8888/api01/info  +  http://api02.localhost:8888/api02/items
```

---

## Comandos de emergencia

### Reset completo de un rollout pausado/roto

```bash
# Si el rollout queda Paused y querés tirarlo abajo:
kubectl patch rollout <name> -n <ns> --subresource=status --type=merge -p '{"status":{"pauseConditions":null}}'
# o forzar rollback:
kubectl patch rollout <name> -n <ns> --type=merge -p '{"spec":{"abort":true}}'
```

### Limpiar PipelineRuns viejos

```bash
kubectl delete pipelinerun --all -n tekton-pipelines
```

### Forzar ArgoCD sync

```bash
kubectl annotate app webserver-api01-dev -n argocd argocd.argoproj.io/refresh=normal --overwrite
kubectl annotate app webserver-api02-dev -n argocd argocd.argoproj.io/refresh=normal --overwrite
```

### Re-pushear el mismo tag (burn o release fallido)

```bash
cd /ruta/al/app
git tag -d <tag>
git push --delete origin <tag>
git tag <tag>
git push origin <tag>
# Y borrar el PipelineRun si era release (deterministic name):
kubectl delete pipelinerun <app>-pipelinerun-<tag> -n tekton-pipelines
```

### Recrear Kibana saved objects (si desaparecen)

```bash
KIBANA_POD=$(kubectl get pod -n logging -l app=kibana -o jsonpath='{.items[0].metadata.name}')
DATA_VIEW_ID="929e12ce-6546-499e-b76b-d7e600d83f69"

# data view
kubectl exec -n logging $KIBANA_POD -- curl -s -X POST "http://localhost:5601/api/data_views/data_view" \
  -H "kbn-xsrf: true" -H "Content-Type: application/json" \
  -d '{"data_view":{"id":"'$DATA_VIEW_ID'","title":"k8s-*","name":"k8s logs","timeFieldName":"@timestamp"}}'

# Re-aplicar saved searches: ver los comandos al final de esta sesion en el git log
# o copiar de docs/logging-efk.md
```

### Verificar end-to-end metrics flow

```bash
# Tekton metrics
kubectl exec -n monitoring prometheus-kube-prometheus-kube-prome-prometheus-0 -c prometheus -- \
  promtool query instant http://localhost:9090 'up{job=~".*tekton.*"}'

# Argo Rollouts metrics
kubectl exec -n monitoring prometheus-kube-prometheus-kube-prome-prometheus-0 -c prometheus -- \
  promtool query instant http://localhost:9090 'rollout_info'

# App metrics
kubectl exec -n monitoring prometheus-kube-prometheus-kube-prome-prometheus-0 -c prometheus -- \
  promtool query instant http://localhost:9090 'sum(rate(api01_requests_total[1m]))'
```

### Re-aplicar TODO sobre un cluster ya levantado

```bash
make refresh
# Ejecuta: tekton-apply + dashboards-apply + helm upgrade fluent-bit + ArgoCD app refresh
```

---

## URLs + credenciales

| Servicio | URL | Cred |
|---|---|---|
| ArgoCD | http://argocd.localhost:8888 | admin / `make argocd-password` |
| Grafana | http://grafana.localhost:8888 | admin / belo-challenge |
| Kibana | http://kibana.localhost:8888 | sin auth |
| Tekton Dashboard | http://tekton.localhost:8888 | sin auth |
| Headlamp | http://headlamp.localhost:8888 | `kubectl create token headlamp -n kube-system` |
| api01 stable | http://api01.localhost:8888/api01/ | — |
| api01 preview | http://preview-api01.localhost:8888/api01/ | — |
| api02 stable | http://api02.localhost:8888/api02/ | — |
| api02 preview | http://preview-api02.localhost:8888/api02/ | — |

---

## Lo que evitar mostrar

- **Re-pushear el mismo release tag**: falla con AlreadyExists (intencional — disciplina semver)
- **Pipeline en producción**: tiene gate manual, no autoprueba
- **Pipelines viejos con `generateName`**: si hay runs anteriores con nombres random, limpialos antes (`kubectl delete pipelinerun --all -n tekton-pipelines`)
- **Burn justo después de otro burn**: HPA cooldown de 5min — esperá o el `max-replicas` puede no superar el baseline

## Flujo total para la demo (~20 min)

1. `make pipeline-check` (1 min)
2. `git tag release/v0.8.0/dev` en api01 (5 min — pipeline corre solo)
3. `git tag release/v0.3.0/dev` en api02 (5 min)
4. `git tag burn/dev` o `make burn-test APP=webserver-api01 ENV=dev` (4 min)
5. Tour: Tekton Dashboard → ArgoCD → Grafana dev-cluster → Grafana pipeline → Kibana dashboard (5 min)
