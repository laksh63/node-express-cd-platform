import client from 'prom-client';
import { Request, Response, NextFunction } from 'express';

export const register = new client.Registry();

// Node process metrics: heap, event loop lag, GC.
client.collectDefaultMetrics({ register });

const httpRequestDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'Duration of HTTP requests in seconds',
  labelNames: ['method', 'route', 'status_code'],
  // Buckets chosen around expected API latency so p95/p99 are meaningful.
  buckets: [0.01, 0.05, 0.1, 0.3, 0.5, 1, 3, 5],
});

const httpRequestsTotal = new client.Counter({
  name: 'http_requests_total',
  help: 'Total HTTP requests',
  labelNames: ['method', 'route', 'status_code'],
});

register.registerMetric(httpRequestDuration);
register.registerMetric(httpRequestsTotal);

export function metricsMiddleware(req: Request, res: Response, next: NextFunction) {
  const end = httpRequestDuration.startTimer();

  res.on('finish', () => {
    // Use the matched route pattern, not the raw URL — otherwise every
    // article slug becomes its own metric series and cardinality explodes.
    const route = req.route?.path ?? req.path;
    const labels = {
      method: req.method,
      route,
      status_code: String(res.statusCode),
    };
    end(labels);
    httpRequestsTotal.inc(labels);
  });

  next();
}
