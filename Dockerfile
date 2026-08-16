# AppFlowy Cloud for Railway — the whole self-hosted stack in one container.
#
# Upstream ships nine containers (nginx, appflowy_cloud, appflowy_worker,
# appflowy_web, gotrue, minio, admin_frontend, postgres, redis). Railway bills
# per service, so everything that does not need its own disk or its own
# database engine is folded into this image and supervised here. Only Postgres
# and Redis stay as separate Railway services.
#
# Base is appflowy_web, because it already carries nginx, supervisord and bun.

ARG APPFLOWY_CLOUD_VERSION=0.17.12
ARG APPFLOWY_WEB_VERSION=0.16.18
ARG MINIO_VERSION=RELEASE.2025-04-22T22-12-26Z

FROM appflowyinc/appflowy_cloud:${APPFLOWY_CLOUD_VERSION} AS cloud
FROM appflowyinc/appflowy_worker:${APPFLOWY_CLOUD_VERSION} AS worker
FROM appflowyinc/gotrue:${APPFLOWY_CLOUD_VERSION} AS gotrue
FROM minio/minio:${MINIO_VERSION} AS minio

FROM appflowyinc/appflowy_web:${APPFLOWY_WEB_VERSION}

USER root

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl liblzma5 libbz2-1.0 libssl3 postgresql-client tzdata \
 && rm -rf /var/lib/apt/lists/*

COPY --from=cloud  /usr/local/bin/appflowy_cloud  /usr/local/bin/appflowy_cloud
COPY --from=worker /usr/local/bin/appflowy_worker /usr/local/bin/appflowy_worker
COPY --from=worker /app/services                  /app/services
COPY --from=gotrue /auth                          /usr/local/bin/gotrue
COPY --from=gotrue /migrations                    /gotrue/migrations
COPY --from=minio  /usr/bin/minio                 /usr/local/bin/minio

# Fail the build rather than the deploy if a binary cannot run on this base.
RUN appflowy_cloud --version || true \
 && ldd /usr/local/bin/appflowy_cloud  | grep -q "not found" && exit 1 || true \
 && ldd /usr/local/bin/appflowy_worker | grep -q "not found" && exit 1 || true \
 && /usr/local/bin/minio --version >/dev/null

COPY nginx.conf.template /etc/appflowy/nginx.conf.template
COPY supervisord.conf    /etc/appflowy/supervisord.conf
COPY railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
RUN chmod +x /usr/local/bin/railway-entrypoint.sh

ENV APPFLOWY_ENVIRONMENT=production \
    APPFLOWY_WORKER_ENVIRONMENT=production \
    RUST_LOG=info \
    APPFLOWY_ACCESS_CONTROL=true \
    APPFLOWY_WEBSOCKET_MAILBOX_SIZE=6000 \
    APPFLOWY_DATABASE_MAX_CONNECTIONS=40 \
    APPFLOWY_S3_USE_MINIO=true \
    APPFLOWY_S3_CREATE_BUCKET=true \
    APPFLOWY_S3_BUCKET=appflowy \
    APPFLOWY_S3_REGION=us-east-1 \
    APPFLOWY_INDEXER_ENABLED=false \
    GOTRUE_DB_DRIVER=postgres \
    GOTRUE_JWT_EXP=604800 \
    GOTRUE_MAILER_AUTOCONFIRM=true \
    GOTRUE_EXTERNAL_EMAIL_ENABLED=true \
    GOTRUE_LOG_LEVEL=info \
    APPFLOWY_DATA_DIR=/data

ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
