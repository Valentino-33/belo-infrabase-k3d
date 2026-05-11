// Corre contra el preview service durante el BlueGreen, antes del switch de tráfico.
// Si los checks pasan → ArgoRollouts promueve la versión green.
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

export const errorRate = new Rate('errors');
export const latencyP95 = new Trend('latency_p95_ms', true);

export const options = {
  stages: [
    { duration: '15s', target: 10 },
    { duration: '30s', target: 10 },
    { duration: '15s', target: 0 },
  ],
  thresholds: {
    http_req_duration: ['p(95)<800', 'p(99)<1500'],
    errors: ['rate<0.01'],
  },
};

const PREVIEW_URL = __ENV.PREVIEW_URL || __ENV.BASE_URL || 'http://webserver-api01-preview.dev.svc.cluster.local:8000';

export default function () {
  const healthRes = http.get(`${PREVIEW_URL}/health`);
  check(healthRes, { 'health 200': (r) => r.status === 200 });
  latencyP95.add(healthRes.timings.duration);

  const apiRes = http.get(`${PREVIEW_URL}/api01/hello`);
  const ok = check(apiRes, {
    'api 200': (r) => r.status === 200,
    'version present': (r) => JSON.parse(r.body).version !== undefined,
  });
  errorRate.add(!ok);
  sleep(0.5);
}
