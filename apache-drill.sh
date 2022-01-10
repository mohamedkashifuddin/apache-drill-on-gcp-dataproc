#!/bin/bash

set -euxo pipefail

# drill installation paths and user & version details
readonly DRILL_USER=drill
readonly DRILL_USER_HOME=/var/lib/drill
readonly DRILL_HOME=/opt/drill
readonly DRILL_LOG_DIR=${DRILL_HOME}/log
readonly DRILL_VERSION='1.19.0'
readonly bucket=bucket-to-store-plugin-details
readonly bucket_accuknox=gs://bucket-to-access-data
 
function err() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $@" >&2
  return 1
}

function print_err_logs() {
  for i in ${DRILL_LOG_DIR}/*; do
    echo ">>> $i"
    cat "$i"
  done
  return 1
}



function create_gcs_storage_plugin() {
  # Create GCS storage plugin
  cat >/tmp/gcs_plugin.json <<EOF 
{
    "config": {
        "connection": "${bucket_accuknox}",
        "enabled": true,
        "formats": {
            "avro": {
                "type": "avro"
            },
            "csv": {
                "delimiter": ",",
                "extensions": [
                    "csv"
                ],
                "type": "text"
            },
            "csvh": {
                "delimiter": ",",
                "extensions": [
                    "csvh"
                ],
                "extractHeader": true,
                "type": "text"
            },
            "json": {
                "extensions": [
                    "json"
                ],
                "type": "json"
            },
            "parquet": {
                "type": "parquet"
            },
            "psv": {
                "delimiter": "|",
                "extensions": [
                    "tbl"
                ],
                "type": "text"
            },
            "sequencefile": {
                "extensions": [
                    "seq"
                ],
                "type": "sequencefile"
            },
            "tsv": {
                "delimiter": "\t",
                "extensions": [
                    "tsv"
                ],
                "type": "text"
            }
        },
        "type": "file",
        "workspaces": {
            "root": {
                "defaultInputFormat": null,
                "location": "/",
                "writable": true
            }
        }
    },
    "name": "gcs"
}
EOF
  curl -d@/tmp/gcs_plugin.json -H 'Content-Type: application/json' -X POST http://localhost:8047/storage/gs.json
}

function start_drillbit() {
  # Start drillbit
  sudo -u ${DRILL_USER} ${DRILL_HOME}/bin/drillbit.sh status ||
    sudo -u ${DRILL_USER} ${DRILL_HOME}/bin/drillbit.sh start && sleep 60

  create_gcs_storage_plugin

}

function drill_hostname() {

hostname=$(curl -kLs "http://api.ipify.org")

cat>>/opt/drill/conf/drill-env.sh<< EOF
export DRILL_HOST_NAME=$hostname
EOF

}

function gcs_write() {
cat>>/opt/drill/conf/core-site.xml<< EOF
<?xml version="1.0" ?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<!--
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License. See accompanying LICENSE file.
-->
<!-- Put site-specific property overrides in this file. -->
<configuration>
<property>
<name>fs.gs.project.id</name>
<value>YOUR_PROJECT_ID</value>
<description>
    Optional. Google Cloud Project ID with access to GCS buckets.
    Required only for list buckets and create bucket operations.
</description>
</property>
<property>
<name>fs.gs.auth.service.account.private.key.id</name>
<value>YOUR_PRIVATE_KEY_ID</value>
</property>
<property>
    <name>fs.gs.auth.service.account.private.key</name>
    <value>-----BEGIN PRIVATE KEY-----\nYOUR_PRIVATE_KEY\n-----END PRIVATE KEY-----\n</value>
</property>
<property>
<name>fs.gs.auth.service.account.email</name>
<value>YOUR_SERVICE_ACCOUNT_EMAIL/value>
<description>
    The email address is associated with the service account used for GCS
    access when fs.gs.auth.service.account.enable is true. Required
    when authentication key specified in the Configuration file (Method 1)
    or a PKCS12 certificate (Method 3) is being used.
</description>
</property>
<property>
<name>fs.gs.working.dir</name>
<value>/</value>
<description>
    The directory relative gs: uris resolve in inside of the default bucket.
</description>
</property>
<property>
<name>fs.gs.implicit.dir.repair.enable</name>
<value>true</value>
<description>
    Whether or not to create objects for the parent directories of objects
    with / in their path e.g. creating gs://bucket/foo/ upon deleting or
    renaming gs://bucket/foo/bar.
</description>
</property>
<property>
<name>fs.gs.glob.flatlist.enable</name>
<value>true</value>
<description>
    Whether or not to prepopulate potential glob matches in a single list
    request to minimize calls to GCS in nested glob cases.
</description>
</property>
<property>
<name>fs.gs.copy.with.rewrite.enable</name>
<value>true</value>
<description>
    Whether or not to perform copy operation using Rewrite requests. Allows
    to copy files between different locations and storage classes.
</description>
</property>
</configuration>
EOF
}

function main() {
  # Determine the cluster name
  local cluster_name=$(/usr/share/google/get_metadata_value attributes/dataproc-cluster-name)

  # Determine the cluster uuid
  local cluster_uuid=$(/usr/share/google/get_metadata_value attributes/dataproc-cluster-uuid)

  # Change these if you have a GCS bucket you'd like to use instead.
  local dataproc_bucket=${bucket}

  # Use a GCS bucket for Drill profiles, partitioned by cluster name and uuid.
  local profile_store="gs://${dataproc_bucket}/profiles/${cluster_name}/${cluster_uuid}"
  local gs_plugin_bucket="gs://${dataproc_bucket}"

  # intelligently generate the zookeeper string
  readonly zookeeper_cfg="/opt/zookeeper/conf/zoo.cfg"
  readonly zookeeper_client_port=$(grep 'clientPort' ${zookeeper_cfg} |
    tail -n 1 |
    cut -d '=' -f 2)
  readonly zookeeper_list=$(grep '^server\.' ${zookeeper_cfg} |
    tac |
    sort -u -t '=' -k1,1 |
    cut -d '=' -f 2 |
    cut -d ':' -f 1 |
    sed "s/$/:${zookeeper_client_port}/" |
    xargs echo |
    sed "s/ /,/g")



  # Create drill pseudo-user.
  useradd -r -m -d ${DRILL_USER_HOME} ${DRILL_USER} || echo

  # Create drill home
  mkdir -p ${DRILL_HOME} && chown ${DRILL_USER}:${DRILL_USER} ${DRILL_HOME}

  # Download and unpack Drill as the pseudo-user.
  wget -nv --timeout=5 --tries=5 --retry-connrefused \
    https://archive.apache.org/dist/drill/drill-${DRILL_VERSION}/apache-drill-${DRILL_VERSION}.tar.gz

  tar -xzf apache-drill-${DRILL_VERSION}.tar.gz -C ${DRILL_HOME} --strip 1

  # Replace default configuration with cluster-specific.
  sed -i "s/drillbits1/${cluster_name}/" ${DRILL_HOME}/conf/drill-override.conf
  sed -i "s/localhost:2181/${zookeeper_list}/" ${DRILL_HOME}/conf/drill-override.conf
  # Make the log directory
  mkdir -p ${DRILL_LOG_DIR} && chown ${DRILL_USER}:${DRILL_USER} ${DRILL_LOG_DIR}

  # Symlink drill conf dir to /etc
  mkdir -p /etc/drill && ln -sf ${DRILL_HOME}/conf /etc/drill/

  # Point drill logs to $DRILL_LOG_DIR
  echo DRILL_LOG_DIR=${DRILL_LOG_DIR} >>${DRILL_HOME}/conf/drill-env.sh

  # Link GCS connector to drill 3rdparty jars
  local connector_dir
  if [[ -d /usr/local/share/google/dataproc/lib ]]; then
    connector_dir=/usr/local/share/google/dataproc/lib
  else
    connector_dir=/usr/lib/hadoop/lib
  fi
  ln -sf ${connector_dir}/gcs-connector-*.jar ${DRILL_HOME}/jars/3rdparty

  # Set ZK PStore to use a GCS Bucket
  # Using GCS makes all Drill profiles available from any drillbit, and also
  # persists the profiles past the lifetime of a cluster.
  cat >>${DRILL_HOME}/conf/drill-override.conf <<EOF
drill.exec: { sys.store.provider.zk.blobroot: "${profile_store}" }
EOF
  chown -R drill:drill /etc/drill/conf/*

  chmod +rx /etc/drill/conf/*

  chmod 777 ${DRILL_HOME}/log/
  
  echo -n > ${DRILL_HOME}/conf/core-site.xml
  gcs_write
  drill_hostname
  start_drillbit || err "Failed to start drill"
  # Clean up
  rm -f /tmp/*_plugin.json
}

main || print_err_logs