# Grafana — cómo agregar un dashboard nuevo

Guía paso-a-paso para crear dashboards que el cluster cargue **automáticamente** sin tener que hacer click en la UI de Grafana cada vez que el cluster se rebuilda.

---

## Mecanismo: sidecar de kube-prometheus-stack

El chart de `kube-prometheus-stack` (instalado por `make addons`) tiene esta config en [`helm/addons/kube-prometheus/values.yaml`](../helm/addons/kube-prometheus/values.yaml):

```yaml
grafana:
  sidecar:
    dashboards:
      enabled: true
```

Esto enciende un **sidecar container** dentro del pod de Grafana que escanea **todos los namespaces** buscando ConfigMaps con el label:

```
grafana_dashboard: "1"
```

Cada vez que ve un ConfigMap nuevo (o uno modificado) con ese label:
1. Lee cada key del `data:` como un dashboard JSON
2. Lo copia a `/tmp/dashboards/` dentro del pod de Grafana
3. Grafana lo importa por convención de filesystem

**Resultado**: el dashboard aparece en la UI ~30s después del `kubectl apply`, sin tocar Grafana directamente.

---

## Pasos para agregar un dashboard nuevo

### Paso 1 — Diseñá el dashboard en la UI

1. Entrar a http://grafana.localhost:8888 (admin / belo-challenge)
2. **Dashboards** → **New** → **New dashboard** → agregar paneles
3. Para cada panel, definir:
   - **Title**
   - **Datasource**: Prometheus (`Prometheus` o `prometheus` según versión)
   - **Query**: el PromQL (ejemplos abajo)
   - **Visualization**: timeseries, stat, gauge, table, etc.
4. **Save dashboard** → poner un nombre (no se persiste fuera del pod, pero queda para exportar)

### Paso 2 — Exportá el JSON

1. Abrir el dashboard guardado
2. Settings (⚙) → **JSON Model** → seleccionar todo → copiar
3. **Importante**: limpiar campos volátiles antes de versionar:
   - Borrar `"id": <num>`
   - Borrar `"iteration": <num>`
   - Setear `"version": 1`
   - Setear `"uid": "<algo-único-versionable>"` (no el UID auto-generado)

### Paso 3 — Convertir el JSON a ConfigMap

Plantilla:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-<nombre>
  namespace: monitoring
  labels:
    grafana_dashboard: "1"   # ← clave: el sidecar lo levanta por este label
data:
  <nombre>.json: |
    {
      ... JSON acá, indentado 4 espacios ...
    }
```

> El nombre del archivo dentro de `data:` (`<nombre>.json`) es lo que Grafana usa como filename interno — no afecta nada visible al usuario, pero ayuda a debuggear (`kubectl exec -n monitoring deploy/kube-prometheus-grafana -c grafana-sc-dashboard -- ls /tmp/dashboards/`).

### Paso 4 — Aplicar

Guardar el YAML en `manifests/grafana/dashboard-<nombre>.yaml` y:

```bash
kubectl apply -f manifests/grafana/dashboard-<nombre>.yaml
# o, mejor:
make dashboards-apply
```

A los ~30s aparece en Grafana → Dashboards → Browse.

### Paso 5 — Versionarlo

`git add manifests/grafana/dashboard-<nombre>.yaml && git commit`. Próximo `make cluster-up` lo levanta solo.

---

## Queries PromQL útiles para apps en este cluster

Las apps emiten métricas custom vía `prometheus_client`:
- `api01_requests_total{method, endpoint, status_code}` (Counter)
- `api01_request_duration_seconds_*` (Histogram con buckets `le`, `_sum`, `_count`)
- Mismo set para api02 (`api02_*`).

| Métrica | PromQL |
|---------|--------|
| Request rate por endpoint | `sum by (endpoint) (rate(api01_requests_total[1m]))` |
| Error rate 5xx | `sum by (endpoint) (rate(api01_requests_total{status_code=~"5.."}[1m]))` |
| p95 de latencia | `histogram_quantile(0.95, sum by (le, endpoint) (rate(api01_request_duration_seconds_bucket[1m])))` |
| p99 de latencia | `histogram_quantile(0.99, sum by (le, endpoint) (rate(api01_request_duration_seconds_bucket[1m])))` |
| Pods Running en un ns | `count(kube_pod_status_phase{namespace="webserver-api01-dev", phase="Running"} == 1)` |
| HPA current replicas | `kube_horizontalpodautoscaler_status_current_replicas{namespace="webserver-api01-dev"}` |
| HPA desired replicas | `kube_horizontalpodautoscaler_status_desired_replicas{namespace="webserver-api01-dev"}` |
| HPA % CPU actual | `kube_horizontalpodautoscaler_status_current_metrics_average_utilization{namespace="webserver-api01-dev"}` |
| CPU usado por pod | `sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="webserver-api01-dev"}[1m]))` |
| Memoria usada por pod | `sum by (pod) (container_memory_working_set_bytes{namespace="webserver-api01-dev"})` |
| Rollout phase | `rollout_info{name="webserver-api01-dev"}` |
| Tekton TaskRun durations p95 | `histogram_quantile(0.95, sum by (le, task) (rate(tekton_pipelines_controller_taskrun_duration_seconds_bucket[5m])))` |

---

## Dashboards ya provisionados

| Archivo | UID | Contenido |
|---------|-----|-----------|
| `manifests/grafana/dashboard-api01.yaml` | `belo-api01` | RPS, error rate, p95/p99, pods, HPA, CPU/mem para webserver-api01-dev |
| `manifests/grafana/dashboard-api02.yaml` | `belo-api02` | Mismo set para webserver-api02-dev |
| `manifests/grafana/dashboard-pipeline.yaml` | `belo-pipeline` | Tekton TaskRun duration p95, Rollout phases, runs por hora |

Para clonarlos como punto de partida para una app nueva:
```bash
cp manifests/grafana/dashboard-api01.yaml manifests/grafana/dashboard-<nueva>.yaml
# Buscar y reemplazar: webserver-api01 → <nueva>, api01_ → <prefix>_, belo-api01 → belo-<nueva>
```

---

## Troubleshooting

| Síntoma | Causa probable | Fix |
|---------|----------------|-----|
| Dashboard no aparece después de `kubectl apply` | Label mal puesto | Verificar: `kubectl get cm <name> -n monitoring -o jsonpath='{.metadata.labels}'` — debe tener `grafana_dashboard: "1"` |
| Sidecar no detecta el ConfigMap | El sidecar busca el label `grafana_dashboard` con value `"1"` (string). Otros values son ignorados | Confirmar que es string `"1"`, no booleano |
| Aparece pero los paneles dicen "No data" | El datasource UID no matchea, o las queries hacen referencia a métricas que no existen | Abrir el panel → Edit → ver query en consola. `kubectl -n monitoring exec -ti pod/prometheus-... -- promtool query instant '...'` |
| El JSON tiene `${DS_PROMETHEUS}` literal en queries | Exportaste con "Export for sharing externally" en lugar de "JSON Model" | Re-exportar via Settings → JSON Model |
| Cambios en el ConfigMap no se reflejan | El sidecar cachea filenames; si solo cambias el contenido, regenera. Si cambias el filename dentro de `data:`, hace falta esperar reload | `kubectl rollout restart deployment/kube-prometheus-grafana -n monitoring` fuerza el refresh |
