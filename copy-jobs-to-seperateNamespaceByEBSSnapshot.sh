#! /bin/bash
set -x

source ./envvars.sh

mkdir -p $GENDIR

#Name of the original Team or Managed Controller you want to copy jobs from
DOMAIN_SOURCE=${1:-"ebs"}
#Name of the destination Team or Managed Controller you want to copy jobs to
DOMAIN_DESTINATION=${2:-"sepns"}
#Name of the original namespace where your $DOMAIN_SOURCE Controller is located
NAMESPACE_SOURCE=${3:-"cloudbees-core"}
#Name of the destination namespace where your $DOMAIN_DESTINATION Controller is located
NAMESPACE_DESTINATION=${4:-"cloudbees-controllers"}


#TODO:Adjust your tags here
AWS_TAGS="Tags=[{Key=cb-environment,Value=customer-dev-XY},{Key=cb-user,Value=XY},{Key=cb-owner,Value=XY}]"

#Get the SOURCE JENKINS_HOME PV name where we want to take a snapshot from
VOLUME_NAME_SOURCE=$(kubectl get "pvc/jenkins-home-${DOMAIN_SOURCE}-0" -n ${NAMESPACE_SOURCE} -o go-template={{.spec.volumeName}})

#The volume id of the PV
VOLUME_ID_SOURCE=$(kubectl get pv $VOLUME_NAME_SOURCE -n ${NAMESPACE_SOURCE} -o go-template={{.spec.awsElasticBlockStore.volumeID}})

echo "take snapshot for $DOMAIN_SOURCE, $VOLUME_NAME_SOURCE, $VOLUME_ID_SOURCE"
SNAPSHOT=$(aws ec2 create-snapshot \
--volume-id "$VOLUME_ID_SOURCE" \
--description "$DOMAIN_SOURCE,$VOLUME_NAME_SOURCE,$VOLUME_ID_SOURCE" \
--output json \
--tag-specifications "ResourceType=snapshot,$AWS_TAGS")
echo $SNAPSHOT |jq  >  $GENDIR/ebs-snapshot.json

export SNAPSHOT_ID=$(cat $GENDIR/ebs-snapshot.json |jq -r '.SnapshotId')
aws ec2 wait snapshot-completed \
    --snapshot-ids $SNAPSHOT_ID
echo "snapshot $SNAPSHOT_ID created"

echo "create volume for $SNAPSHOT_ID"
export SNAPSHOT_VOLUME=$(aws ec2 create-volume \
--volume-type gp2 \
--snapshot-id $SNAPSHOT_ID \
--tag-specifications "ResourceType=volume,$AWS_TAGS" \
--availability-zone $AWS_DEFAULT_REGION \
--output json)
echo $SNAPSHOT_VOLUME |jq  >  $GENDIR/ebs-snapshot_volume.json
export VOLUME_ID_SNAPSHOT=$(cat $GENDIR/ebs-snapshot_volume.json |jq -r  '.VolumeId')
echo "volume $VOLUME_ID_SNAPSHOT created"


#create PV,PVC fro the new volume (that was restored from EBS Snapshot previously)
cat <<EOF | kubectl --namespace=$NAMESPACE_DESTINATION apply -f -
---
apiVersion: "v1"
kind: PersistentVolume
metadata:
  name: rescue-pv-${DOMAIN_SOURCE}
spec:
  capacity:
    storage: 50Gi  # Define your desired storage size
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce  # Replace with appropriate access mode (e.g., ReadWriteOnce)
  persistentVolumeReclaimPolicy: Delete  # Adjust reclaim policy based on your requirement
  storageClassName: gp2
  awsElasticBlockStore:
    volumeID: "${VOLUME_ID_SNAPSHOT}"  # Replace with your AWS EBS volume ID
    fsType: ext4  # Define the file system type
    readOnly: true  # Set to true if the volume should be mounted as read-only
---
apiVersion: "v1"
kind: PersistentVolumeClaim
metadata:
  name: rescue-pvc-${DOMAIN_SOURCE}
  namespace: ${NAMESPACE_DESTINATION}
spec:
  storageClassName: gp2
  volumeName: rescue-pv-${DOMAIN_SOURCE}
  accessModes:
    - ReadWriteOnce  # Choose appropriate access mode based on your requirement
  resources:
    requests:
      storage: 50Gi  # Set your desired storage size
---
apiVersion: v1
kind: Pod
metadata:
  name: rescue-pod
spec:
  securityContext:
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
  volumes:
    - name: pv-data-source
      persistentVolumeClaim:
        claimName: rescue-pvc-${DOMAIN_SOURCE}
    - name: pv-data-destination
      persistentVolumeClaim:
        claimName: jenkins-home-${DOMAIN_DESTINATION}-0
   # emptyDir: {}
  containers:
  - name: rescue-pvc
    #image: busybox
    #We need rsync!!
    image: instrumentisto/rsync-ssh
    command: [ "sh", "-c", "sleep 10000" ]
    volumeMounts:
    - name:  pv-data-source
      mountPath: /tmp/jenkins_home_source
    - name: pv-data-destination
      mountPath: /tmp/jenkins_home_destination
    securityContext:
      allowPrivilegeEscalation: false
EOF

#Wait until pod is up
kubectl wait pod/rescue-pod  --for condition=ready
#This command will sync all jobs and folders excluding the build
kubectl exec -ti rescue-pod -- rsync -az --exclude="*/builds/" /tmp/jenkins_home_source/jobs/ /tmp/jenkins_home_destination/jobs

#This command will sync all jobs and folders including history
#kubectl exec -ti rescue-pod -- rsync -az  /tmp/jenkins_home_source/jobs/ /tmp/jenkins_home_destination/jobs


#reload new Jobs from disk
curl -L -s -u $TOKEN -XPOST  "https://ci.acaternberg.pscbdemos.com/$DOMAIN_DESTINATION/reload" \


#Clean resources
function cleanUpResources {
  echo "delete snapshot $SNAPSHOT_ID, we don't need it anymore"
  aws ec2 delete-snapshot --snapshot-id $SNAPSHOT_ID
  echo "delete rescue-pod , we don't need it anymore"
  kubectl delete pod rescue-pod
  echo "delete rescue-pvc-${DOMAIN_SOURCE} , we don't need it anymore"
  kubectl delete pvc rescue-pvc-${DOMAIN_SOURCE}
  sleep 10 # this can be improved, we need to wait until the pvc is deleted before deleting the volume_id below
  echo "delete snapshot volume   ${VOLUME_ID_SNAPSHOT} , we don't need it anymore"
  aws ec2 detach-volume --volume-id ${VOLUME_ID_SNAPSHOT} --force
  aws ec2 delete-volume --volume-id ${VOLUME_ID_SNAPSHOT}
}
#https://www.putorius.net/using-trap-to-exit-bash-scripts-cleanly.html#google_vignette
trap cleanUpResources  SIGINT SIGTERM ERR EXIT
