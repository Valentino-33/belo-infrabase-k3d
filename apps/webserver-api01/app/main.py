"""webserver-api01 — Blue/Green deployment demo.

Todos los endpoints viven bajo /api01/ — esta API NO expone nada en /.
Los logs salen a stdout en JSON via structlog. Las métricas son
prometheus_client (Counter + Histogram) y se scrapean en /api01/metrics
via ServiceMonitor.
"""
import os
import time
from contextlib import asynccontextmanager

import structlog
from fastapi import FastAPI, Request
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
from starlette.responses import Response

from app.logging_config import configure_logging

APP_VERSION = os.getenv("APP_VERSION", "0.0.0")
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO")
SERVICE_NAME = "webserver-api01"
STRATEGY = "bluegreen"
STARTED_AT = time.time()

configure_logging(LOG_LEVEL)
log = structlog.get_logger()

# Las métricas se exponen en /api01/metrics; los nombres llevan el prefijo
# api01_ para que sean fácilmente filtrables en Prometheus/Grafana.
REQUEST_COUNT = Counter(
    "api01_requests_total",
    "Total de requests recibidos",
    ["method", "endpoint", "status_code"],
)
REQUEST_LATENCY = Histogram(
    "api01_request_duration_seconds",
    "Latencia de requests en segundos",
    ["endpoint"],
)


@asynccontextmanager
async def lifespan(app: FastAPI):
    log.info("startup", service=SERVICE_NAME, version=APP_VERSION, strategy=STRATEGY)
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


# Toda la API vive bajo /api01/* — la raíz / no responde nada (404).
# La probe de liveness/readiness apunta a /api01/health.

@app.get("/api01/")
async def root():
    """Landing minimalista — describe el servicio y su strategy."""
    return {
        "service": SERVICE_NAME,
        "version": APP_VERSION,
        "strategy": STRATEGY,
        "status": "ok",
    }


@app.get("/api01/health")
async def health():
    """Liveness + readiness probe target. Devuelve la versión que sirve
    para que el load test pueda verificar contra qué RS está hablando."""
    return {
        "status": "healthy",
        "service": SERVICE_NAME,
        "version": APP_VERSION,
    }


@app.get("/api01/version")
async def version():
    """Endpoint dedicado a versión — usado para verificar el resultado
    del switchover en demos de Blue/Green."""
    return {
        "service": SERVICE_NAME,
        "version": APP_VERSION,
        "strategy": STRATEGY,
    }


@app.get("/api01/hello")
async def hello():
    """Endpoint de negocio — el que pegan los load tests del pipeline."""
    return {
        "message": "Hello from api01 (Blue/Green deployment)",
        "version": APP_VERSION,
    }


@app.get("/api01/info")
async def info():
    """Metadata extra del proceso — útil para debug en la demo."""
    return {
        "service": SERVICE_NAME,
        "version": APP_VERSION,
        "strategy": STRATEGY,
        "uptime_seconds": round(time.time() - STARTED_AT, 1),
        "log_level": LOG_LEVEL,
    }


@app.get("/api01/metrics")
async def metrics():
    """Endpoint Prometheus — scrapeado por kube-prometheus-stack via
    ServiceMonitor (config en charts/pythonapps/templates/servicemonitor.yaml)."""
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)
