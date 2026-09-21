FROM ghcr.io/actions/actions-runner:2.337.0 AS github-runner

FROM public.ecr.aws/aws-cli/aws-cli:2.36.39 AS aws-cli

FROM mcr.microsoft.com/playwright:v1.63.0-noble

RUN apt-get update \
    && apt-get install -y --no-install-recommends git jq libicu74 libssl3t64 ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 deploy \
    && mkdir -p /runner /opt/actions-runner \
    && chown -R deploy:deploy /runner /opt/actions-runner

COPY --from=github-runner --chown=deploy:deploy /home/runner/ /opt/actions-runner/
COPY --from=aws-cli /usr/local/aws-cli/ /usr/local/aws-cli/
RUN ln -s /usr/local/aws-cli/v2/current/bin/aws /usr/local/bin/aws \
    && ln -s /usr/local/aws-cli/v2/current/bin/aws_completer /usr/local/bin/aws_completer
COPY --chown=deploy:deploy ci-runner/start.sh /opt/actions-runner/start.sh

USER deploy
WORKDIR /runner
ENTRYPOINT ["/bin/sh", "/opt/actions-runner/start.sh"]
