bucket="gs://<bucket-name>/folder-name"
cluster_name="apache-drill"
Number_of_worker_node=2
GCP_project_id=
### Get the project id from project console/using google sdk by gcloud info

gcloud dataproc clusters create $cluster_name \
--region us-west1 \
--zone=us-west1-c \
--scopes=default,storage-ro,storage-rw \
--initialization-actions=$bucket/zookeeper_quorum.sh,$bucket/apache-drill.sh \
 --master-machine-type n1-standard-2 \
 --master-boot-disk-size 50 \
  --num-workers $Number_of_worker_node \
--worker-machine-type n1-standard-2 \
--worker-boot-disk-size 50 \
--image-version 2.0-ubuntu18 \
--project $GCP_project_id