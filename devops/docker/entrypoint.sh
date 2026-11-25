#!/bin/sh
# Starts DeployEx as the main process of the container, with logrotate run every few
# minutes next to it: a container has no cron to do it.
set -e

# The Erlang VM sizes its table of ports from the limit of open files, unless it is given
# +Q. DeployEx is, and the applications it starts usually are not: where the limit is about
# a billion, as in a Kubernetes pod on containerd, their VM asks for gigabytes when it
# boots and the container is killed for it. A limit that is already lower is kept
if [ "$(ulimit -n)" = "unlimited" ] || [ "$(ulimit -n)" -gt "${DEPLOYEX_MAX_OPEN_FILES:-65536}" ]; then
  ulimit -n "${DEPLOYEX_MAX_OPEN_FILES:-65536}"
fi

(
  while sleep "${LOGROTATE_INTERVAL_SECONDS:-300}"; do
    logrotate -s /var/lib/deployex/logrotate.status /etc/deployex/logrotate.conf || true
  done
) &

exec /opt/deployex/bin/deployex start
