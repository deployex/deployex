#!/bin/sh
# Starts DeployEx as the main process of the container, with logrotate run every few
# minutes next to it: a container has no cron to do it.
set -e

(
  while sleep "${LOGROTATE_INTERVAL_SECONDS:-300}"; do
    logrotate -s /var/lib/deployex/logrotate.status /etc/deployex/logrotate.conf || true
  done
) &

exec /opt/deployex/bin/deployex start
