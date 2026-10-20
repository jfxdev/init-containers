# syntax=docker/dockerfile:1

# Imagem do init container. Roda como root por padrão porque o caso de uso
# central é chown de volumes para o uid do container principal.
FROM alpine:3.23 AS runtime

# git para clonar, jq para ler a configuração, ca-certificates para HTTPS.
# bash porque o script usa arrays e pipefail, que o busybox sh não tem.
RUN apk add --no-cache \
      bash \
      ca-certificates \
      git \
      jq

WORKDIR /opt/init-containers
COPY bin/ bin/
COPY lib/ lib/

ARG VERSION=dev
ENV INITC_VERSION=${VERSION} \
    INITC_CONFIG=/etc/init-containers/config.json

ENTRYPOINT ["/opt/init-containers/bin/init-containers"]

# Estágio de teste: roda a suíte bats dentro da própria imagem, para garantir
# que o script funciona com os utilitários do busybox e não só com os do GNU.
FROM runtime AS test
RUN apk add --no-cache bats
COPY test/ test/
COPY examples/ examples/
RUN git config --global user.email ci@example.com \
 && git config --global user.name CI \
 && bats test/
