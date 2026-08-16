# appflowy-railway

Wrapper image that runs the whole [AppFlowy Cloud](https://github.com/AppFlowy-IO/AppFlowy-Cloud)
self-hosted stack in a single container, for the Railway template
`AppFlowy | (Just Updated) Notion Alternative`.

Upstream ships nine containers. Railway bills per service, so everything that needs
neither its own disk nor its own database engine is folded into this image and
supervised here:

| process        | port (loopback) | upstream image                        |
| -------------- | --------------- | ------------------------------------- |
| nginx          | `$PORT`         | (base image)                          |
| appflowy_web   | 3000            | `appflowyinc/appflowy_web:0.16.18`    |
| appflowy_cloud | 8000            | `appflowyinc/appflowy_cloud:0.17.12`  |
| appflowy_worker| —               | `appflowyinc/appflowy_worker:0.17.12` |
| gotrue         | 9999            | `appflowyinc/gotrue:0.17.12`          |
| minio          | 9000 / 9001     | `minio/minio:RELEASE.2025-04-22T…`    |

Only Postgres (pgvector) and Redis stay as separate Railway services, so a deploy is
three billed services instead of eight.

## What this image fixes

- **The advertised admin login is unusable on a stock deploy.** AppFlowy-Cloud refuses
  to create an `af_user` row — and therefore a workspace — for a GoTrue *system admin*,
  which is exactly what `gotrue admin createuser --admin` (and `GOTRUE_ADMIN_EMAIL`)
  produces: signing in as it returns `{"code":1024,"message":"User not found"}` and
  `GET /api/workspace` returns `Record not found: user … not found in af_user`. This
  image seeds two separate accounts — an internal system admin for AppFlowy-Cloud's own
  GoTrue admin API calls, and the deployer's account as a normal confirmed user.
- **Public sign-up is closed by default** (`APPFLOWY_ALLOW_SIGNUP=true` re-opens it),
  because the URL is public from the moment Railway publishes it.
- **No SMTP account is required.** E-mail confirmation is off unless `GOTRUE_SMTP_HOST`
  is set, so a deploy has zero blank required variables.
- **The admin password is re-applied on every boot**, so a redeploy is a working
  password reset — GoTrue has no `updateuser` subcommand and the recovery flow needs
  SMTP.
- **`APPFLOWY_S3_PRESIGNED_URL_ENDPOINT`** is derived from the public domain, so
  presigned upload/download URLs point at something a browser can actually reach.
- **A real healthcheck**: `/healthz` proxies AppFlowy-Cloud's `/api/health`, so a green
  deploy implies a working API rather than a running nginx.
- Sign-in and sign-up are rate-limited per client address, keyed on the first address
  of `X-Forwarded-For` (Railway's edge hop rotates per request).
- Every upstream image is pinned.

## Variables

| variable                     | required | notes                                        |
| ---------------------------- | -------- | -------------------------------------------- |
| `APPFLOWY_ADMIN_EMAIL`       | yes      | deployer's login                              |
| `APPFLOWY_ADMIN_PASSWORD`    | yes      | re-applied every boot; empty refuses to boot  |
| `GOTRUE_JWT_SECRET`          | yes      | 64 chars                                      |
| `MINIO_ROOT_PASSWORD`        | yes      |                                               |
| `DATABASE_URL`               | yes      | Postgres with pgvector                        |
| `REDIS_URL`                  | yes      |                                               |
| `APPFLOWY_ALLOW_SIGNUP`      | no       | `true` re-opens public registration           |
| `APPFLOWY_AUTH_RATE_PER_MIN` | no       | default 20                                    |
| `APPFLOWY_DATA_DIR`          | no       | default `/data`, holds the MinIO object store  |

## Local test

```sh
docker build -t appflowy-railway:test .
docker run -d --name afapp -p 8080:8080 \
  -e PORT=8080 -e APPFLOWY_BASE_URL=http://localhost:8080 \
  -e DATABASE_URL='postgres://postgres:pw@pg:5432/appflowy' \
  -e REDIS_URL='redis://redis:6379' \
  -e APPFLOWY_ADMIN_EMAIL=admin@example.com \
  -e APPFLOWY_ADMIN_PASSWORD='…' -e GOTRUE_JWT_SECRET="$(openssl rand -hex 32)" \
  -e MINIO_ROOT_PASSWORD='…' appflowy-railway:test
```
