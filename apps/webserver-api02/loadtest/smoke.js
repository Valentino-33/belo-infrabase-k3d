// Smoke test básico — valida que el stable service de api02 responde correctamente.
// Usado por el pipeline cuando strategy=rollingupdate.
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate } from 'k6/metrics';

export const errorRate = new Rate('errors');

export const options = {
  stages: [
    { duration: '10s', target: 5 },
    { duration: '20s', target: 5 },
    { duration: '10s', target: 0 },
  ],
  thresholds: {
    http_req_duration: ['p(95)<500'],
    errors: ['rate<0.01'],
  },
};

const BASE_URL = __ENV.BASE_URL || 'http://webserver-api02-stable.dev.svc.cluster.local:8000';

export default function () {
  const res = http.get(`${BASE_URL}/health`);
  const ok = check(res, {
    'status 200': (r) => r.status === 200,
    'body healthy': (r) => JSON.parse(r.body).status === 'healthy',
  });
  errorRate.add(!ok);
  sleep(1);
}
