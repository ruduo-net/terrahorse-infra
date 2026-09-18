FROM ghcr.io/actions/actions-runner:2.337.0 AS github-runner

FROM docker:29.8.1-cli AS docker-cli

FROM mcr.microsoft.com/playwright:v1.63.0-noble

RUN apt-get update \
    && apt-get install -y --no-install-recommends git libicu74 libssl3t64 ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 ci \
    && mkdir -p /runner /opt/actions-runner \
    && chown -R ci:ci /runner /opt/actions-runner

COPY --from=github-runner --chown=ci:ci /home/runner/ /opt/actions-runner/
COPY --from=docker-cli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker-cli /usr/local/libexec/docker/cli-plugins/ /usr/local/libexec/docker/cli-plugins/
COPY --chown=ci:ci start.sh /opt/actions-runner/start.sh

ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
USER ci
WORKDIR /runner
ENTRYPOINT ["/bin/sh", "/opt/actions-runner/start.sh"]
