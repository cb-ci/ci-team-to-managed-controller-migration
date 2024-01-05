#! /bin/bash
set -x
#Name of the original Team or Managed Controller you want to copy jobs from
DOMAIN_SOURCE=${1:-"teams-myteam"}
#Name of the destination Team or Managed Controller you want to copy jobs to
DOMAIN_DESTINATION=${2:-"sepns-efs"}
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

#Get the SOURCE JENKINS_HOME PV name where we want to take a snapshot from
# We also get some attributes from from the original pv and pvc that we need to reclaim the EFS volume
VOLUME_NAME_SOURCE=$(kubectl get "pvc/jenkins-home-${DOMAIN_SOURCE}-0" -n ${NAMESPACE_SOURCE} -o go-template={{.spec.volumeName}})
VOLUME_HANDLE_SOURCE=$(kubectl get pv $VOLUME_NAME_SOURCE -n ${NAMESPACE_SOURCE} -o go-template={{.spec.csi.volumeHandle}})
VOLUME_ATTRIBUTE_SOURCE=$(kubectl get pv $VOLUME_NAME_SOURCE -o   go-template={{.spec.csi.volumeAttributes}} | sed  's#map\[storage.kubernetes.io/csiProvisionerIdentity:# #'  | sed 's#]##')
VOLUME_CAPACITY_STORAGE_SOURCE=$(kubectl get pv $VOLUME_NAME_SOURCE -o   go-template={{.spec.capacity.storage}})
VOLUME_STORAGE_CLASSNAME_SOURCE=$(kubectl get pv $VOLUME_NAME_SOURCE -o   go-template={{.spec.storageClassName}})

#create a rescue PV,PVC for the new volume. It references the original EFS filesystem
cat <<EOF | kubectl --namespace=$NAMESPACE_DESTINATION apply -f -
---
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: rescue-efs-pv-${DOMAIN_SOURCE}
spec:
  capacity:
    storage: ${VOLUME_CAPACITY_STORAGE_SOURCE}
  volumeMode: Filesystem
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ${VOLUME_STORAGE_CLASSNAME_SOURCE}
  csi:
    driver: efs.csi.aws.com
    volumeAttributes:
      storage.kubernetes.io/csiProvisionerIdentity: ${VOLUME_ATTRIBUTE_SOURCE}
    volumeHandle: ${VOLUME_HANDLE_SOURCE}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: rescue-efs-pvc-${DOMAIN_SOURCE}
  namespace: ${NAMESPACE_DESTINATION}
spec:
  storageClassName: ${VOLUME_STORAGE_CLASSNAME_SOURCE}
  volumeName: rescue-efs-pv-${DOMAIN_SOURCE}
  accessModes:
    - ReadWriteMany  # Choose appropriate access mode based on your requirement
  resources:
    requests:
      storage: ${VOLUME_CAPACITY_STORAGE_SOURCE}  # Set your desired storage size
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
        claimName: rescue-efs-pvc-${DOMAIN_SOURCE}
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
function cleanUpResources {
  echo "delete rescue-pod , we don't need it anymore"
  kubectl delete pod rescue-pod -n $NAMESPACE_DESTINATION
  echo "delete rescue-pvc-${DOMAIN_SOURCE} , we don't need it anymore"
  kubectl delete pvc rescue-efs-pvc-${DOMAIN_SOURCE} -n $NAMESPACE_DESTINATION
  kubectl delete pvc rescue-efs-pv-${DOMAIN_SOURCE}
  kubectl get pod,pv,pvc -n $NAMESPACE_DESTINATION
}
#https://www.putorius.net/using-trap-to-exit-bash-scripts-cleanly.html#google_vignette
trap cleanUpResources  SIGINT SIGTERM ERR EXIT


#reload new Jobs from disk
#TODO: restart Controller ${DOMAIN_DESTINATION} or reload configuration from disk
