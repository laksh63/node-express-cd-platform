import express from 'express';
import cors from 'cors';
import * as bodyParser from 'body-parser';
import routes from './app/routes/routes';
import HttpException from './app/models/http-exception.model';
import { register, metricsMiddleware } from './app/metrics';

const app = express();

/**
 * App Configuration
 */

app.use(cors());
app.use(bodyParser.json());
app.use(bodyParser.urlencoded({ extended: true }));
app.use(metricsMiddleware);
app.use(routes);

// Serves images
app.use(express.static(__dirname + '/assets'));

app.get('/', (req: express.Request, res: express.Response) => {
  res.json({ status: 'API is running on /api' });

});

app.get('/metrics', async (req: express.Request, res: express.Response) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});

app.get('/api/health', (req: express.Request, res: express.Response) => {
  res.json({ status: 'ok' });
});


/* eslint-disable */
app.use(
  (
    err: Error | HttpException,
    req: express.Request,
    res: express.Response,
    next: express.NextFunction,
  ) => {
    // @ts-ignore
    if (err && err.name === 'UnauthorizedError') {
      return res.status(401).json({
        status: 'error',
        message: 'missing authorization credentials',
      });
      // @ts-ignore
    } else if (err && err.errorCode) {
      // @ts-ignore
      res.status(err.errorCode).json(err.message);
    } else if (err) {
      res.status(500).json(err.message);
    }
  },
);

/**
 * Server activation
 */

const PORT = process.env.PORT || 3000;

app.listen(PORT, () => {
  console.info(`server up on port ${PORT}`);
});
