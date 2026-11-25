# DeployEx in a container. It is built from the source in the build context, so it works
# on amd64 and arm64, and runs the applications it manages inside the same container.
ARG BUILDER_IMAGE=hexpm/elixir:1.19.5-erlang-28.5.0.5-ubuntu-noble-20260810
ARG RUNNER_IMAGE=ubuntu:24.04

FROM ${BUILDER_IMAGE} AS builder
RUN apt-get update -y && apt-get install -y build-essential git libcap-dev ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
ENV MIX_ENV=prod
RUN mix local.hex --force && mix local.rebar --force
COPY . .
RUN mix do deps.get + compile
RUN mix assets.deploy
RUN mix release
RUN mkdir /release && tar -xzf "$(ls -t _build/prod/deployex-*.tar.gz | head -1)" -C /release
# Certificates for the TLS distribution between DeployEx and the applications. They are
# made when the image is built, which is enough for a trial: mount real ones in production
RUN mkdir /certs && cd /certs && MIX_ENV=dev elixir /src/devops/scripts/certificates/otp-28/tls-distribution-certs

FROM ${RUNNER_IMAGE}
RUN apt-get update -y && apt-get install -y libstdc++6 openssl libncurses6 libcap2 locales ca-certificates logrotate \
    && rm -rf /var/lib/apt/lists/* && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8
# The applications are run as this user, never as root
RUN useradd --create-home --shell /bin/bash deployex \
    && mkdir -p /opt/deployex /var/lib/deployex /var/log/deployex /var/log/monitored-apps /certs /bucket \
    && chown -R deployex:deployex /opt/deployex /var/lib/deployex /var/log/deployex /var/log/monitored-apps /certs /bucket
COPY --from=builder --chown=deployex:deployex /release /opt/deployex
COPY --from=builder --chown=deployex:deployex /certs/ca.crt /certs/deployex.crt /certs/deployex.key /certs/
# The log files of the applications are rotated from the entrypoint, see logrotate.conf.
# It is not in /etc/deployex: a volume mounted there for deployex.yaml would hide it
COPY --chown=deployex:deployex devops/docker/logrotate.conf /opt/logrotate.conf
COPY --chown=deployex:deployex devops/docker/entrypoint.sh /opt/entrypoint.sh
USER deployex
# erlexec, which runs the applications, does not start without a shell to run them with,
# and a container sets none
ENV SHELL=/bin/bash \
    DEPLOYEX_CONFIG_YAML_PATH=/etc/deployex/deployex.yaml \
    DEPLOYEX_OTP_TLS_CERT_PATH=/certs
EXPOSE 5001
CMD ["/opt/entrypoint.sh"]
