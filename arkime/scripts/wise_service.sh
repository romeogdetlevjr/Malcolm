#!/bin/bash

# Copyright (c) 2023 Battelle Energy Alliance, LLC.  All rights reserved.

while true; do
  if [[ ("$WISE" == "on") && (-f /var/run/arkime/runwise) && (-f $ARKIME_DIR/etc/wise.ini) ]]; then
    echo "Launch wise..."
    rm -f $ARKIME_DIR/logs/wise*
    pushd $ARKIME_DIR/wiseService >/dev/null 2>&1
    $ARKIME_DIR/bin/node wiseService.js --insecure -c $ARKIME_DIR/etc/wise.ini
    popd >/dev/null 2>&1
  fi
  sleep 5
done
