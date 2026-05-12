# Logging — EFK (Elasticsearch + Fluent-bit + Kibana)

Verificación end-to-end de que los logs de las apps están llegando a Kibana con el formato esperado, y queries que un operador puede usar día a día.

---

## 1. Formato de log esperado en las apps

Las dos apps emiten **JSON** a stdout vía [structlog](https://www.structlog.org/) (configurado en `app/logging_config.py` de cada repo).

Ejemplo de una línea real:

```json
{"event":"request","method":"GET","path":"/api01/hello","status":200,"level":"info","timestamp":"2026-05-12T12:34:56.123456Z"}
```

Campos clave para queries en Kibana:

| Campo | Tipo | Ejemplo | Cómo se usa |
|-------|------|---------|-------------|
| `event` | string | `request`, `startup`, `shutdown` | Discriminar tipo de evento |
| `method` | string | `GET`, `POST` | Solo en eventos `request` |
| `path` | string | `/health`, `/api01/hello` | Solo en eventos `request` |
| `status` | int | `200`, `500` | Solo en eventos `request` |
| `level` | string | `info`, `warning`, `error` | Severidad |
| `timestamp` | ISO 8601 | `2026-05-12T12:34:56Z` | Time field principal |
| `service` | string | `webserver-api01` | Solo en eventos `startup`/`shutdown` |
| `version` | string | `v0.4.9` | Solo en eventos `startup` |

> **Por qué structlog y no logging plain**: structlog garantiza que cada línea sea JSON parseable. Si fuera plain text con format strings, fluent-bit no podría hacer merge de keys y las búsquedas en Kibana serían sobre el campo `log` crudo (no indexado por field).

---

## 2. Cómo fluye un log hasta Kibana

```
app pod (stdout)
   │  línea JSON: {"event":"request",...}
   ▼
/var/log/containers/<pod>_<ns>_<container>-<id>.log
   │  (envuelta por docker en {"log":"...","stream":"stdout","time":"..."})
   ▼
fluent-bit DaemonSet (Tail INPUT, Parser docker)
   │  parsea el envelope docker → event = {log: "{\"event\":\"request\",...}", ...}
   ▼
[FILTER kubernetes]
   │  agrega kubernetes_*: namespace_name, pod_name, container_name, labels
   │  Merge_Log On → parsea `log` como JSON y promueve keys al raíz
   │  Merge_Log_Trim On → borra `log` después del merge
   ▼
[OUTPUT es]
   │  index pattern: k8s-YYYY.MM.DD (rotación diaria por Logstash_Format On)
   ▼
elasticsearch-master (statefulset, 1 réplica, PVC local-path)
   │
   ▼
Kibana UI (http://kibana.localhost:8888 — el ingress lo expone)
```

Configuración fuente: [`helm/addons/fluent-bit/values.yaml`](../helm/addons/fluent-bit/values.yaml).

---

## 3. Verificación que EFK está vivo y consumiendo

### 3.1 Pods sanos

```bash
kubectl -n logging get pods
# Esperado:
#   elasticsearch-master-0      1/1 Running
#   fluent-bit-XXXXX            1/1 Running (uno por nodo, DaemonSet)
#   kibana-kibana-XXXXX         1/1 Running
```

### 3.2 Elasticsearch acepta queries

```bash
kubectl -n logging exec elasticsearch-master-0 -- \
  curl -s http://localhost:9200/_cluster/health | jq .
# Esperado: status="green" o "yellow" (single-node es yellow normal)
```

### 3.3 Hay índices con datos

```bash
kubectl -n logging exec elasticsearch-master-0 -- \
  curl -s "http://localhost:9200/_cat/indices/k8s-*?v"
# Esperado: una línea por día con docs.count > 0
# health status index            uuid pri rep docs.count store.size
# yellow open   k8s-2026.05.12   ...   1   1   1234567    150mb
```

Si `docs.count` es 0 — algo se rompió en fluent-bit. Ver troubleshooting abajo.

### 3.4 Hay logs de las apps específicamente

```bash
# Contar logs de api01 en el índice de hoy
TODAY=$(date +%Y.%m.%d)
kubectl -n logging exec elasticsearch-master-0 -- \
  curl -s "http://localhost:9200/k8s-${TODAY}/_count" \
  -H "Content-Type: application/json" \
  -d '{"query":{"match":{"kubernetes.namespace_name":"webserver-api01-dev"}}}'
# Esperado: {"count": N, ...} con N > 0
```

### 3.5 El merge JSON funcionó (los campos están al nivel raíz)

```bash
kubectl -n logging exec elasticsearch-master-0 -- \
  curl -s "http://localhost:9200/k8s-${TODAY}/_search?size=1&pretty" \
  -H "Content-Type: application/json" \
  -d '{
    "query": {"bool": {"must": [
      {"match": {"kubernetes.namespace_name": "webserver-api01-dev"}},
      {"match": {"event": "request"}}
    ]}},
    "_source": ["event", "method", "path", "status", "level", "kubernetes.pod_name"]
  }'
```

Esperado en `_source`:

```json
{
  "event": "request",
  "method": "GET",
  "path": "/api01/hello",
  "status": 200,
  "level": "info",
  "kubernetes": { "pod_name": "webserver-api01-dev-..." }
}
```

Si en cambio ves un campo `log` con todo el JSON sin parsear, el merge falló — revisar `Merge_Log On` en values.

---

## 4. Queries útiles en Kibana (Discover)

Las queries van con sintaxis **KQL** (Kibana Query Language).

| Objetivo | Query |
|----------|-------|
| Logs de api01 en cualquier env | `kubernetes.labels.app : "webserver-api01"` |
| Logs de api01 SOLO en dev | `kubernetes.namespace_name : "webserver-api01-dev"` |
| Errores 5xx en api01 | `kubernetes.labels.app : "webserver-api01" and status >= 500` |
| Eventos startup (verificar nueva versión deployada) | `event : "startup"` |
| Eventos de un pod específico | `kubernetes.pod_name : "webserver-api01-dev-abc123-xyz"` |
| Requests al endpoint health (puede ser ruido en HPA) | `path : "/health"` |
| Latencia "request" en último 5min | `event : "request" and @timestamp > now-5m` |
| Logs del PipelineRun de Tekton | `kubernetes.namespace_name : "tekton-pipelines"` |

> Para ver el dashboard de logs en tiempo real, abrir Kibana → Analytics → Discover → seleccionar index pattern `k8s-*` y aplicar las queries de arriba.

---

## 5. Crear el index pattern por primera vez

La primera vez que entrás a Kibana hay que crear el index pattern:

1. http://kibana.localhost:8888 → Management → Stack Management → Index Patterns
2. Click "Create index pattern"
3. Pattern: `k8s-*`
4. Time field: `@timestamp`
5. Save

Después, en Analytics → Discover se ve todo lo que está entrando.

---

## 6. Troubleshooting

| Síntoma | Causa probable | Fix |
|---------|----------------|-----|
| `docs.count = 0` en el índice del día | fluent-bit no ingesta | `kubectl -n logging logs ds/fluent-bit \| tail -50` — buscar errores de conexión a Elasticsearch |
| Logs aparecen pero como string crudo en campo `log` | `Merge_Log` está Off o el log NO es JSON parseable | Confirmar que la app emite JSON puro. `kubectl logs <pod>` debe mostrar JSON, no plain text |
| Kibana muestra "No results found" pero hay índice con docs | Time range muy estrecho | Cambiar el time picker a "Last 24 hours" |
| Elasticsearch en `red` status | Single-node y un shard primary no asignado | `kubectl -n logging delete pod elasticsearch-master-0` (el PVC sobrevive) — espera 60s para que vuelva |
| fluent-bit en CrashLoopBackOff | RBAC roto al consultar API de k8s | `kubectl -n logging logs ds/fluent-bit -p` y revisar permisos del SA |

---

## 7. Tunings que se pueden hacer

- **Retención**: actualmente sin ILM (Index Lifecycle Management). En POC los índices crecen sin límite. Para PoC > 1 semana, agregar política de ILM que cierre/elimine índices > 7 días.
- **Shards**: hoy 1 shard primario por índice (suficiente para single-node). Producción multi-node: 3 shards + 1 réplica.
- **Multi-índice por app**: separar `app-api01-*`, `app-api02-*` para retención diferenciada. Cambiar `Logstash_Prefix` por `record["kubernetes"]["labels"]["app"]` usando un Lua filter.
- **Alertas**: Elasticsearch Watcher (paid) o ElastAlert (OSS) para gatillar acciones cuando `status:5xx` supera un umbral.
