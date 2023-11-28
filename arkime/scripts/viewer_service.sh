#!/bin/bash

# Copyright (c) 2023 Battelle Energy Alliance, LLC.  All rights reserved.

while true; do
  if [[ -f /var/run/arkime/initialized && "$VIEWER" == "on" ]]; then
    echo "Launch viewer..."
    rm -f $ARKIME_DIR/logs/viewer*
    pushd $ARKIME_DIR/viewer >/dev/null 2>&1
    $ARKIME_DIR/bin/node viewer.js --insecure -n "${PCAP_NODE_NAME:-malcolm}" -c $ARKIME_DIR/etc/config.ini
    popd >/dev/null 2>&1
  fi
  sleep 5
done
