#!/bin/bash

set -o errexit
set -o xtrace

function retry_apt_command() {
  cmd="$1"
  for ((i = 0; i < 2; i++)); do
    if eval "$cmd"; then
      return 0
    fi
    sleep 5
  done
  return 1
}

function install_apt_get() {
  retry_apt_command "cd /opt"
  retry_apt_command "wget https://dlcdn.apache.org/zookeeper/zookeeper-3.6.3/apache-zookeeper-3.6.3-bin.tar.gz"
  retry_apt_command "tar -xf apache-zookeeper-3.6.3-bin.tar.gz "
  retry_apt_command "mv apache-zookeeper-3.6.3-bin zookeeper"

}

function write_config() {
  cat >>/opt/zookeeper/conf/zoo.cfg <<EOF
# Properties from Zookeeper init action.
tickTime=2000
dataDir=/var/lib/zookeeper
clientPort=2181
initLimit=5
syncLimit=2
server.0=${CLUSTER_NAME}-m:2888:3888
EOF

  if [[ ${WORKER_COUNT} -gt 0 ]]; then
    cat >>/opt/zookeeper/conf/zoo.cfg <<EOF
server.1=${CLUSTER_NAME}-w-0:2888:3888
server.2=${CLUSTER_NAME}-w-1:2888:3888
EOF
  fi
}

# Variables for this script
ROLE=$(/usr/share/google/get_metadata_value attributes/dataproc-role)
CLUSTER_NAME=$(hostname | sed -r 's/(.*)-[w|m](-[0-9]+)?$/\1/')
WORKER_COUNT=$(/usr/share/google/get_metadata_value attributes/dataproc-worker-count)

# Validate the cluster mode and worker count.
ADDITIONAL_MASTER=$(/usr/share/google/get_metadata_value attributes/dataproc-master-additional)
if [[ -n "$ADDITIONAL_MASTER" ]]; then
  echo "ZooKeeper init action cannot be used in HA clusters which already have ZooKeeper running."
  exit 1
fi

# Configure ZooKeeper node ID, master has ID 0, workers start from 1.
if [[ "${ROLE}" == 'Worker' ]]; then
  NODE_NUMBER=$(($(hostname | sed 's/.*-w-\([0-9]\)*.*/\1/g') + 1))
else
  NODE_NUMBER=0
fi

if (($NODE_NUMBER > 2)); then
  write_config
  echo "Skip running ZooKeeper on this node."
  exit 0
fi

install_apt_get

# Write ZooKeeper node ID.
mkdir -p /var/lib/zookeeper
echo ${NODE_NUMBER} >|/var/lib/zookeeper/myid

# Write ZooKeeper configuration file
write_config
/opt/zookeeper/bin/zkServer.sh start