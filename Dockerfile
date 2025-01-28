FROM ghcr.io/foundry-rs/foundry:latest

WORKDIR /contracts

COPY . .

RUN /bin/bash ./scripts/deploy-docker.sh

ENTRYPOINT ["./scripts/docker-entrypoint.sh"]
