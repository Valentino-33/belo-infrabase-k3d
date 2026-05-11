// Corre contra el stable service mientras el canary está activo.
// Una fracción del tráfico va al canary según el peso configurado en ArgoRollouts.
// Si los checks fallan → rollback automático al stable.
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

export const errorRate = new Rate('errors');
export const latencyTrend = new Trend('latency_ms', true);

export const options = {
  stages: [
    { duration: '10s', target: 5 },
    { duration: '20s', target: 5 },
    { duration: '10s', target: 0 },
  ],
  thresholds: {
    http_req_duration: ['p(95)<600', 'p(99)<1200'],
    errors: ['rate<0.005'],
  },
};

const BASE_URL = __ENV.BASE_URL || 'http://webserver-api02-stable.dev.svc.cluster.local:8000';

export default function () {
  const healthRes = http.get(`${BASE_URL}/health`);
  check(healthRes, { 'health 200': (r) => r.status === 200 });

  const apiRes = http.get(`${BASE_URL}/api02/hello`);
  const ok = check(apiRes, {
    'api 200': (r) => r.status === 200,
    'version present': (r) => JSON.parse(r.body).version !== undefined,
  });
  errorRate.add(!ok);
  latencyTrend.add(apiRes.timings.duration);
  sleep(0.5);
}
