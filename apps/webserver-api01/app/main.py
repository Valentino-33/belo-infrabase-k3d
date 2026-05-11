import os
from contextlib import asynccontextmanager

import structlog
from fastapi import FastAPI, Request
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
from starlette.responses import Response

from app.logging_config import configure_logging

APP_VERSION = os.getenv("APP_VERSION", "0.0.0")
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO")
SERVICE_NAME = "webserver-api01"

configure_logging(LOG_LEVEL)
log = structlog.get_logger()

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
    log.info("startup", service=SERVICE_NAME, version=APP_VERSION)
    yield
    log.info("shutdown", service=SERVICE_NAME)


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
    )
    return response


@app.get("/")
async def root():
    return {"service": SERVICE_NAME, "version": APP_VERSION, "status": "ok"}


@app.get("/health")
async def health():
    return {"status": "healthy", "service": SERVICE_NAME}


@app.get("/version")
async def version():
    return {"service": SERVICE_NAME, "version": APP_VERSION}


@app.get("/api01/hello")
async def hello():
    return {"message": "Hello from api01", "version": APP_VERSION}


@app.get("/api01/metrics")
async def metrics():
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)
