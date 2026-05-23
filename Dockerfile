ARG ALPINE_VERSION
FROM alpine:${ALPINE_VERSION} as alpine

ARG POSTGRES_VERSION
RUN apk add --no-cache postgresql$POSTGRES_VERSION-client \
      aws-cli \
      bash \
      curl
WORKDIR /scripts

COPY backup.sh .
ENTRYPOINT [ "bash", "backup.sh" ]
