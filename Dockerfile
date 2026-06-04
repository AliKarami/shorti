FROM ubuntu:24.04 AS base

RUN apt-get update && apt-get install -y \
    openconnect \
    oathtool \
    iproute2 \
    iptables \
    iputils-ping \
    curl \
    python3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY scripts/ ./scripts/
RUN chmod +x ./scripts/*.sh

EXPOSE 9798
ENTRYPOINT ["./scripts/entrypoint.sh"]

# ── Test target ───────────────────────────────────────────────────────────────
FROM base AS test

RUN apt-get update && apt-get install -y bats && rm -rf /var/lib/apt/lists/*

COPY tests/ ./tests/
ENTRYPOINT ["bats", "--tap", "tests/"]
