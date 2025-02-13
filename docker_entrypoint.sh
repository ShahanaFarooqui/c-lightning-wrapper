#!/bin/sh

set -ea

_term() {
  echo "Caught SIGTERM signal!"
  kill -TERM "$lightningd_child" 2>/dev/null
}

export EMBASSY_IP=$(ip -4 route list match 0/0 | awk '{print $3}')
export PEER_TOR_ADDRESS=$(yq e '.peer-tor-address' /root/.lightning/start9/config.yaml)
export RPC_TOR_ADDRESS=$(yq e '.rpc-tor-address' /root/.lightning/start9/config.yaml)
export REST_TOR_ADDRESS=$(yq e '.rest-tor-address' /root/.lightning/start9/config.yaml)

CLBOSS_ENABLED_VALUE=$(yq e '.advanced.plugins.clboss.enabled' /root/.lightning/start9/config.yaml)
if [ $CLBOSS_ENABLED_VALUE = "enabled" ]; then
  if yq -e '.advanced.plugins.clboss.min-onchain' /root/.lightning/start9/config.yaml > /dev/null 2>&1; then
    MIN_ONCHAIN_VALUE=$(yq e '.advanced.plugins.clboss.min-onchain' /root/.lightning/start9/config.yaml)
    MIN_ONCHAIN=" --clboss-min-onchain=$MIN_ONCHAIN_VALUE"
  else
    MIN_ONCHAIN=""
  fi

  if yq -e '.advanced.plugins.clboss.auto-close' /root/.lightning/start9/config.yaml > /dev/null 2>&1; then
    AUTO_CLOSE_VALUE=$(yq e '.advanced.plugins.clboss.auto-close' /root/.lightning/start9/config.yaml)
    AUTO_CLOSE=" --clboss-auto-close=$AUTO_CLOSE_VALUE"
  else
    AUTO_CLOSE=""
  fi

  ZEROBASEFEE_VALUE=$(yq e '.advanced.plugins.clboss.zerobasefee' /root/.lightning/start9/config.yaml)
  if [ $ZEROBASEFEE_VALUE = "default" ]; then
      ZEROBASEFEE=""
  else
      ZEROBASEFEE=" --clboss-zerobasefee=$ZEROBASEFEE_VALUE"
  fi

  if yq -e '.advanced.plugins.clboss.min-channel' /root/.lightning/start9/config.yaml > /dev/null 2>&1; then
    MIN_CHANNEL_VALUE=$(yq e '.advanced.plugins.clboss.min-channel' /root/.lightning/start9/config.yaml)
    MIN_CHANNEL=" --clboss-min-channel=$MIN_CHANNEL_VALUE"
  else
    MIN_CHANNEL=""
  fi

  if yq -e '.advanced.plugins.clboss.max-channel' /root/.lightning/start9/config.yaml > /dev/null 2>&1; then
    MAX_CHANNEL_VALUE=$(yq e '.advanced.plugins.clboss.max-channel' /root/.lightning/start9/config.yaml)
    MAX_CHANNEL=" --clboss-max-channel=$MAX_CHANNEL_VALUE"
  else
    MAX_CHANNEL=""
  fi
fi

mkdir -p /root/.lightning/shared
mkdir -p /root/.lightning/public

echo $PEER_TOR_ADDRESS > /root/.lightning/start9/peerTorAddress
echo $RPC_TOR_ADDRESS > /root/.lightning/start9/rpcTorAddress
echo $REST_TOR_ADDRESS > /root/.lightning/start9/restTorAddress


sh /root/.lightning/start9/waitForStart.sh
sed "s/proxy={proxy}/proxy=${EMBASSY_IP}:9050/" /root/.lightning/config.main > /root/.lightning/config

echo "Cleaning old lightning rpc"
if [ -e /root/.lightning/bitcoin/lightning-rpc ]; then
    rm /root/.lightning/bitcoin/lightning-rpc
fi

# echo "Checking cert"
echo "Fetching system cert for REST interface"
# if ! [ -e /usr/local/libexec/c-lightning/plugins/c-lightning-REST/certs/key.pem ] || ! [ -e /usr/local/libexec/c-lightning/plugins/c-lightning-REST/certs/certificate.pem ]; then
  # echo "Cert missing, copying cert into c-lightning-REST dir"
while ! [ -e /mnt/cert/rest.key.pem ]; do
  echo "Waiting for system cert key file..."
  sleep 1
done
mkdir -p /usr/local/libexec/c-lightning/plugins/c-lightning-REST/certs
cp /mnt/cert/rest.key.pem /usr/local/libexec/c-lightning/plugins/c-lightning-REST/certs/key.pem
while ! [ -e /mnt/cert/rest.cert.pem ]; do
  echo "Waiting for system cert..."
  sleep 1
done
cp /mnt/cert/rest.cert.pem /usr/local/libexec/c-lightning/plugins/c-lightning-REST/certs/certificate.pem
# fi

# use macaroon if exists
if [ -e /root/.lightning/public/access.macaroon ] && [ -e /root/.lightning/public/rootKey.key ]; then
  cp /root/.lightning/public/access.macaroon /usr/local/libexec/c-lightning/plugins/c-lightning-REST/certs/access.macaroon
  cp /root/.lightning/public/rootKey.key /usr/local/libexec/c-lightning/plugins/c-lightning-REST/certs/rootKey.key
else
  echo "Macaroon not found, generating new one"
fi

echo "Starting lightning"
lightningd --database-upgrade=true$MIN_ONCHAIN$AUTO_CLOSE$ZEROBASEFEE$MIN_CHANNEL$MAX_CHANNEL &
lightningd_child=$!

while ! [ -e /root/.lightning/bitcoin/lightning-rpc ]; do
    echo "Waiting for lightning rpc to start..."
    sleep 1
    if ! ps -p $lightningd_child > /dev/null; then
        echo "lightningd has stopped, exiting container"
        exit 1
    fi
done

echo "Cleaning link to lightning rpc"
if [ -e /root/.lightning/shared/lightning-rpc ]; then
    rm /root/.lightning/shared/lightning-rpc
fi
ln /root/.lightning/bitcoin/lightning-rpc /root/.lightning/shared/lightning-rpc


if ! [ -e /root/.lightning/public/access.macaroon ] || ! [ -e /root/.lightning/public/rootKey.key ] ; then
  while ! [ -e /usr/local/libexec/c-lightning/plugins/c-lightning-REST/certs/access.macaroon ] || ! [ -e /usr/local/libexec/c-lightning/plugins/c-lightning-REST/certs/rootKey.key ];
  do
      echo "Waiting for macaroon..."
      sleep 1
      if ! ps -p $lightningd_child > /dev/null; then
          echo "lightningd has stopped, exiting container"
          exit 1
      fi
  done
  cp /usr/local/libexec/c-lightning/plugins/c-lightning-REST/certs/access.macaroon /root/.lightning/public/access.macaroon
  cp /usr/local/libexec/c-lightning/plugins/c-lightning-REST/certs/rootKey.key /root/.lightning/public/rootKey.key
fi

cat /root/.lightning/public/access.macaroon | basenc --base64url -w0  > /root/.lightning/start9/access.macaroon.base64
cat /root/.lightning/public/access.macaroon | basenc --base16 -w0  > /root/.lightning/start9/access.macaroon.hex

lightning-cli getinfo > /root/.lightning/start9/lightningGetInfo

echo "All configuration Done"

trap _term TERM

wait $lightningd_child
