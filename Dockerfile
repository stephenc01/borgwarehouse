ARG UID=1001
ARG GID=1001

FROM node:22-bookworm-slim as base

# ---------- build stage ----------
FROM base AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

FROM base AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
# keep your Next tweak
RUN sed -i "s/images:/output: 'standalone',images:/" next.config.ts
RUN npm run build

# ---------- run stage ----------
FROM base AS runner
ARG UID
ARG GID

ENV NODE_ENV=production
ENV HOSTNAME=
ENV DEBIAN_FRONTEND=noninteractive

# Add backports and install runtime deps + haveged for entropy
RUN echo 'deb http://deb.debian.org/debian bookworm-backports main' >> /etc/apt/sources.list \
 && apt-get update && apt-get install -y \
    supervisor curl jq jc borgbackup/bookworm-backports openssh-server rsyslog haveged \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

# App user
RUN groupadd -g ${GID} borgwarehouse \
 && useradd -m -u ${UID} -g ${GID} borgwarehouse

# Best-effort: keep a copy of moduli in user home (as your original did)
RUN cp /etc/ssh/moduli /home/borgwarehouse/ || true

WORKDIR /home/borgwarehouse/app

# App + configs
COPY --from=builder --chown=borgwarehouse:borgwarehouse /app/docker/docker-bw-init.sh /app/LICENSE ./
COPY --from=builder --chown=borgwarehouse:borgwarehouse /app/helpers/shells ./helpers/shells
COPY --from=builder --chown=borgwarehouse:borgwarehouse /app/.next/standalone ./
COPY --from=builder --chown=borgwarehouse:borgwarehouse /app/public ./public
COPY --from=builder --chown=borgwarehouse:borgwarehouse /app/.next/static ./.next/static
COPY --from=builder --chown=borgwarehouse:borgwarehouse /app/docker/supervisord.conf ./
COPY --from=builder --chown=borgwarehouse:borgwarehouse /app/docker/rsyslog.conf /etc/rsyslog.conf
COPY --from=builder --chown=borgwarehouse:borgwarehouse /app/docker/sshd_config ./

# IMPORTANT: run the init script as root so it can:
# - create /run/sshd (tmpfs) with correct perms
# - generate host keys if needed
# - start haveged and sshd
# Your app still runs as the unprivileged user via Supervisor config.
USER root

EXPOSE 3000 22

ENTRYPOINT ["./docker-bw-init.sh"]
