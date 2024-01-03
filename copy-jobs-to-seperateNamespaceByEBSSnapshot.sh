#! /bin/bash
set -x
#Name of the original Team or Managed Controller you want to copy jobs from
DOMAIN_SOURCE=${1:-"ebs"}
#Name of the destination Team or Managed Controller you want to copy jobs to
DOMAIN_DESTINATION=${2:-"sepns"}
#Name of the original namespace where your $DOMAIN_SOURCE Controller is located
NAMESPACE_SOURCE=${3:-"cloudbees-core"}
#Name of the destination namespace where your $DOMAIN_DESTINATION Controller is located
NAMESPACE_DESTINATION=${4:-"cloudbees-controllers"}



#Adjust your AWS region
export AWS_DEFAULT_REGION=us-east-1
export GENDIR=generated
mkdir -p $GENDIR

#TODO:Adjust your tags here
TAGS="Tags=[{Key=cb-environment,Value=customer-dev-XY},{Key=cb-user,Value=XY},{Key=cb-owner,Value=XY}]"

#The JENKINS_HOME PV name where we want to take a snapshot from
VOLUMENAME=$(kubectl get "pvc/jenkins-home-${DOMAIN_SOURCE}-0" -n ${NAMESPACE_SOURCE} -o go-template={{.spec.volumeName}})

#The volume id of the PV
VOLUMEID=$(kubectl get pv $VOLUMENAME -n ${NAMESPACE_SOURCE} -o go-template={{.spec.awsElasticBlockStore.volumeID}})

echo "take snapshot for $DOMAIN_SOURCE, $VOLUMENAME, $VOLUMEID"
SNAPSHOT=$(aws ec2 create-snapshot \
--volume-id "$VOLUMEID" \
--description "$DOMAIN_SOURCE,$VOLUMENAME,$VOLUMEID" \
--output json \
--tag-specifications "ResourceType=snapshot,$TAGS")
echo $SNAPSHOT |jq  >  $GENDIR/ebs-snapshot.json

SNAPSHOTID=$(cat $GENDIR/ebs-snapshot.json |jq -r '.SnapshotId')
aws ec2 wait snapshot-completed \
    --snapshot-ids $SNAPSHOTID
echo "snapshot $SNAPSHOTID created"

echo "create volume for $SNAPSHOTID"
SNAPSHOT_VOLUME=$(aws ec2 create-volume \
--volume-type gp2 \
--snapshot-id $SNAPSHOTID \
--tag-specifications "ResourceType=volume,$TAGS" \
--availability-zone us-east-1a \
--output json)
echo $SNAPSHOT_VOLUME |jq  >  $GENDIR/ebs-snapshot_volume.json
export VOLUME_ID=$(cat $GENDIR/ebs-snapshot_volume.json |jq -r  '.VolumeId')
echo "volume $VOLUME_ID created"


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
    volumeID: "${VOLUME_ID}"  # Replace with your AWS EBS volume ID
    fsType: ext4  # Define the file system type
    readOnly: false  # Set to true if the volume should be mounted as read-only
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
EOF


#Create the rescue pod that mount the snapshot volume and the new controller volume
cat <<EOF | kubectl --namespace=$NAMESPACE_DESTINATION  apply -f -
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
kubectl exec -ti rescue-pod -- rsync -avz --exclude="*/builds/" /tmp/jenkins_home_source/jobs/ /tmp/jenkins_home_destination/jobs

#This command will sync all jobs and folders including history
#kubectl exec -ti rescue-pod -- rsync -avz  /tmp/jenkins_home_source/jobs/ /tmp/jenkins_home_destination/jobs


#Clean resources
##TODO: use trap command and sigterm, see https://opensource.com/article/20/6/bash-trap
#trap  "aws ec2 delete-snapshot --snapshot-id $SNAPSHOTID"  SIGINT SIGTERM ERR EXIT
echo "delete snapshot $SNAPSHOTID, we don't need it anymore"
aws ec2 delete-snapshot --snapshot-id $SNAPSHOTID
echo "delete rescue-pod , we don't need it anymore"
kubectl delete pod rescue-pod
echo "delete rescue-pvc-${DOMAIN_SOURCE} , we don't need it anymore"
kubectl delete pvc rescue-pvc-${DOMAIN_SOURCE}
sleep 10 # this can be improved, we need to wait until the pvc is deleted before deleting the volume_id below
echo "delete snapshot volume   ${VOLUME_ID} , we don't need it anymore"
aws ec2 delete-volume --volume-id ${VOLUME_ID}

#reload new Jobs from disk
#TODO: restart Controller ${DOMAIN_DESTINATION} or reload configuration from disk
