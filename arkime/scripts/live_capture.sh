#!/bin/bash

# Copyright (c) 2023 Battelle Energy Alliance, LLC.  All rights reserved.

ARKIME_DIR=${ARKIME_DIR:-"/opt/arkime"}
CERT_FILE="${ARKIME_DIR}"/etc/viewer.crt
KEY_FILE="${ARKIME_DIR}"/etc/viewer.key
ARKIME_PACKET_THREADS=${ARKIME_PACKET_THREADS:-1}
PUSER=${PUSER:-"arkime"}
PGROUP=${PGROUP:-"arkime"}
ARKIME_LIVE_NODE_NAME=${ARKIME_LIVE_NODE_NAME:-"malcolm"}
ARKIME_LIVE_NODE_HOST=${ARKIME_LIVE_NODE_HOST:-""}

OPENSEARCH_PRIMARY=${OPENSEARCH_PRIMARY:-"opensearch-local"}
OPENSEARCH_URL=${OPENSEARCH_URL:-"http://opensearch:9200"}
OPENSEARCH_PRIMARY=${OPENSEARCH_PRIMARY:-"opensearch-local"}
OPENSEARCH_SSL_CERTIFICATE_VERIFICATION=${OPENSEARCH_SSL_CERTIFICATE_VERIFICATION:-"false"}
OPENSEARCH_CREDS_CONFIG_FILE=${OPENSEARCH_CREDS_CONFIG_FILE:-"/var/local/curlrc/.opensearch.primary.curlrc"}
if ( [[ "$OPENSEARCH_PRIMARY" == "opensearch-remote" ]] || [[ "$OPENSEARCH_PRIMARY" == "elasticsearch-remote" ]] ) && [[ -r "$OPENSEARCH_CREDS_CONFIG_FILE" ]]; then
  CURL_CONFIG_PARAMS=(
    --config
    "$OPENSEARCH_CREDS_CONFIG_FILE"
    )
else
  CURL_CONFIG_PARAMS=()
fi

rm -f /var/run/arkime/initialized /var/run/arkime/runwise

# make sure TLS certificates exist prior to starting up
CERT_FILE=$ARKIME_DIR/etc/viewer.crt
KEY_FILE=$ARKIME_DIR/etc/viewer.key
if ( [[ ! -f "$CERT_FILE" ]] || [[ ! -f "$KEY_FILE" ]] ) && [[ -x /usr/local/bin/self_signed_key_gen.sh ]]; then
  rm -f "$CERT_FILE" "$KEY_FILE" ./newcerts
  pushd $ARKIME_DIR/etc/ >/dev/null 2>&1
  /usr/local/bin/self_signed_key_gen.sh -n -o ./newcerts >/dev/null 2>&1
  mv ./newcerts/server.crt "$CERT_FILE"
  mv ./newcerts/server.key "$KEY_FILE"
  rm -rf ./newcerts
  popd >/dev/null 2>&1
fi

# download and/or update geo updates
$ARKIME_DIR/bin/arkime_update_geo.sh

# we haven't dropUser/dropGroup'ed yet, so make sure the regular user owns the files we just touched
[[ -n ${PUID} ]] && [[ -n ${PGID} ]] && chown -f -R ${PUID}:${PGID} "${ARKIME_DIR}"/etc/ || true

# wait patiently for the non-live Arkime to initialize the database
echo "Giving $OPENSEARCH_PRIMARY time to start..."
/opt/opensearch_status.sh 2>&1 && echo "$OPENSEARCH_PRIMARY is running!"
echo "Giving Arkime time to initialize..."
sleep 5
until (( $(curl "${CURL_CONFIG_PARAMS[@]}" -fs -XGET -H'Content-Type: application/json' "${OPENSEARCH_URL}/_cat/indices/arkime_users_v*" | wc -l) >= 1 )); do
    sleep 1
done

# this will also allow viewer to kick off
touch /var/run/arkime/initialized

echo "Arkime is initialized!"
echo

"${ARKIME_DIR}"/bin/capture --insecure \
  -c "${ARKIME_DIR}"/etc/config.ini \
  -o pcapDir=/data/pcap/processed \
  -o packetThreads=${ARKIME_PACKET_THREADS} \
  -o dropUser=${PUSER} \
  -o dropGroup=${PGROUP} \
  -o ecsEventProvider=arkime \
  -o ecsEventDataset=session \
  --node "${ARKIME_LIVE_NODE_NAME}" \
  --host "${ARKIME_LIVE_NODE_HOST}"
