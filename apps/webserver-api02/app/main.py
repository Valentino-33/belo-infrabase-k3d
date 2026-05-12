"""webserver-api02 — Canary deployment demo.

Todos los endpoints viven bajo /api02/ — esta API NO expone nada en /.
La API expone catálogo de items + echo + endpoint de stats para
diferenciarse claramente de api01 (que es un hello-world más simple).

Los logs salen a stdout en JSON via structlog. Las métricas son
prometheus_client (Counter + Histogram + Gauge) y se scrapean en
/api02/metrics via ServiceMonitor.
"""
import os
import time
from contextlib import asynccontextmanager
from typing import Optional

import structlog
from fastapi import FastAPI, Query, Request
from prometheus_client import Counter, Histogram, Gauge, generate_latest, CONTENT_TYPE_LATEST
from starlette.responses import Response

from app.logging_config import configure_logging

APP_VERSION = os.getenv("APP_VERSION", "0.0.0")
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO")
SERVICE_NAME = "webserver-api02"
STRATEGY = "canary"
STARTED_AT = time.time()

# Catálogo en memoria — simula un dataset distinto al hello-world de api01.
# La idea es que durante un canary deploy, /api02/items y /api02/items/{id}
# devuelvan responses ricos que dejan ver claramente la versión que sirvió
# cada request (clave para validar el split de tráfico).
CATALOG = {
    1: {"name": "argo-rollouts", "category": "deployment-strategy"},
    2: {"name": "tekton-pipelines", "category": "ci-cd"},
    3: {"name": "k6", "category": "load-testing"},
    4: {"name": "kube-prometheus", "category": "observability"},
    5: {"name": "fluent-bit", "category": "observability"},
}

configure_logging(LOG_LEVEL)
log = structlog.get_logger()

REQUEST_COUNT = Counter(
    "api02_requests_total",
    "Total de requests recibidos",
    ["method", "endpoint", "status_code"],
)
REQUEST_LATENCY = Histogram(
    "api02_request_duration_seconds",
    "Latencia de requests en segundos",
    ["endpoint"],
)
# Gauge custom que api01 NO tiene — diferencia visible en Prometheus.
CATALOG_SIZE = Gauge(
    "api02_catalog_items",
    "Cantidad de items en el catálogo",
)
CATALOG_SIZE.set(len(CATALOG))


@asynccontextmanager
async def lifespan(app: FastAPI):
    log.info("startup", service=SERVICE_NAME, version=APP_VERSION, strategy=STRATEGY, catalog_items=len(CATALOG))
    yield
    log.info("shutdown", service=SERVICE_NAME, version=APP_VERSION)


app = FastAPI(title=SERVICE_NAME, version=APP_VERSION, lifespan=lifespan)


@app.middleware("http")
async def log_requests(request: Request, call_next):
    with REQUEST_LATENCY.labels(endpoint=request.url.path).time():
        response = await call_next(request)
    REQUEST_COUNT.labels(
        method=request.method,
        endpoint=request.url.path,
        status_code=response.status_code,
    ).inc()
    log.info(
        "request",
        method=request.method,
        path=request.url.path,
        status=response.status_code,
        version=APP_VERSION,
    )
    return response


# Toda la API vive bajo /api02/* — la raíz / no responde nada (404).
# La probe de liveness/readiness apunta a /api02/health.

@app.get("/api02/")
async def root():
    """Landing — describe el servicio y su strategy (canary)."""
    return {
        "service": SERVICE_NAME,
        "version": APP_VERSION,
        "strategy": STRATEGY,
        "endpoints": [
            "/api02/health",
            "/api02/version",
            "/api02/hello",
            "/api02/items",
            "/api02/items/{id}",
            "/api02/echo",
            "/api02/info",
            "/api02/metrics",
        ],
    }


@app.get("/api02/health")
async def health():
    """Liveness + readiness target. Schema distinto al de api01."""
    return {
        "status": "healthy",
        "service": SERVICE_NAME,
        "version": APP_VERSION,
        "strategy": STRATEGY,
        "catalog_loaded": len(CATALOG) > 0,
    }


@app.get("/api02/version")
async def version():
    """Devuelve la versión junto con metadata del deployment."""
    return {
        "service": SERVICE_NAME,
        "version": APP_VERSION,
        "strategy": STRATEGY,
        "deployed_via": "Tekton + ArgoCD + Argo Rollouts",
    }


@app.get("/api02/hello")
async def hello():
    """Endpoint de negocio. Distinto en shape al de api01 a propósito —
    durante un canary podés ver el split de tráfico comparando responses."""
    return {
        "message": f"Greetings from canary deployment of {SERVICE_NAME}",
        "version": APP_VERSION,
        "from": STRATEGY,
    }


@app.get("/api02/items")
async def list_items():
    """Lista el catálogo entero — endpoint exclusivo de api02 que api01 no tiene."""
    return {
        "service": SERVICE_NAME,
        "version": APP_VERSION,
        "items": [{"id": k, **v} for k, v in CATALOG.items()],
        "total": len(CATALOG),
    }


@app.get("/api02/items/{item_id}")
async def get_item(item_id: int):
    """Item del catálogo por ID. Útil para demos de routing."""
    item = CATALOG.get(item_id)
    if not item:
        return Response(
            content='{"error": "item not found", "item_id": ' + str(item_id) + '}',
            status_code=404,
            media_type="application/json",
        )
    return {
        "id": item_id,
        **item,
        "served_by": SERVICE_NAME,
        "version": APP_VERSION,
    }


@app.get("/api02/echo")
async def echo(msg: Optional[str] = Query(default="hello", description="Mensaje a echoar")):
    """Echo con metadata — útil para tests de routing donde queremos ver
    qué pod respondió. api01 no tiene un endpoint equivalente."""
    return {
        "echo": msg,
        "served_by": SERVICE_NAME,
        "version": APP_VERSION,
        "strategy": STRATEGY,
    }


@app.get("/api02/info")
async def info():
    """Metadata del proceso — útil para debug en la demo."""
    return {
        "service": SERVICE_NAME,
        "version": APP_VERSION,
        "strategy": STRATEGY,
        "uptime_seconds": round(time.time() - STARTED_AT, 1),
        "log_level": LOG_LEVEL,
        "catalog_items": len(CATALOG),
    }


@app.get("/api02/metrics")
async def metrics():
    """Endpoint Prometheus — scrapeado por kube-prometheus-stack via ServiceMonitor."""
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)
