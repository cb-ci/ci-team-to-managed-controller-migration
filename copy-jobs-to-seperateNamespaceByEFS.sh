#! /bin/bash
#enable debugging output
set -x

source ./envvars.sh

#Name of the original Team or Managed Controller you want to copy jobs from
DOMAIN_SOURCE=${1:-"myteam"}

#Teamcontrollers have always the prefix "teams-". If the source controller is a managed controller, set the DOMAIN_SOURCE_TEAM_PREFIX to empty string""
#Team Controller prefix
DOMAIN_SOURCE_TEAM_PREFIX="teams-"
#Managed Controller prefix
#DOMAIN_SOURCE_TEAM_PREFIX=""

#Name of the destination Team or Managed Controller you want to copy jobs to
DOMAIN_DESTINATION=${2:-"sepns-efs"}

#Name of the original namespace where your $DOMAIN_SOURCE Controller is located
NAMESPACE_SOURCE=${3:-"cloudbees-core"}

#Name of the destination namespace where your $DOMAIN_DESTINATION Controller is located
NAMESPACE_DESTINATION=${4:-"cloudbees-controllers"}



#Temporary dir for generated files and log files
export GENDIR=generated
mkdir -p $GENDIR

#Helper function to check if an controller is online
function checkControllerOnline () {
  # We have to wait until ingress is created and we can call the Jenkins HealthCheck with state 200
  while [ ! -n "$(curl  -IL  ${1}/whoAmI/api/json?tree=authenticated | grep -o  'HTTP/2 200')" ]
  do
    #echo "wait 30 sec for State HTTP 200:  ${CONTROLLER_URL}/login"
    echo "wait 30 sec for State HTTP 200:  ${1}/whoAmI/api/json?tree=authenticated"
    sleep 10
  done
}

#CREATE MC CONTROLLER
# We apply the cjoc-controller-items.yaml to cjoc. Cjoc will create a new Managed Controller for us using our $GENDIR/${CONTROLLER_NAME}.yaml
echo "------------------  CREATING MANAGED CONTROLLER ------------------"
export CONTROLLER_NAME="${DOMAIN_DESTINATION}"
envsubst < templates/create-mc.yaml > $GENDIR/${DOMAIN_DESTINATION}.yaml
curl -XPOST \
   --user $TOKEN \
   "${CJOC_URL}/casc-items/create-items" \
    -H "Content-Type:text/yaml" \
   --data-binary @$GENDIR/${DOMAIN_DESTINATION}.yaml
# We wait until our new Managed Controller pod is up
echo "------------------  WAITING FOR CONTROLLER TO COME UP ------------------"
checkControllerOnline $BASE_URL/$DOMAIN_DESTINATION


# Now we apply the target Folder to the Managed Controller.
# This is the root folder where we want to migrate our credentials and jobs to
echo "------------------  CREATING INITIAL TEAM FOLDER ------------------"
export CONTROLLER_NAME="${DOMAIN_SOURCE}"
envsubst < templates/create-folder.yaml > ${GENDIR}/${DOMAIN_SOURCE}-folder.yaml
curl -v  -XPOST \
    --user $TOKEN \
    "${BASE_URL}/${DOMAIN_DESTINATION}/casc-items/create-items" \
     -H "Content-Type:text/yaml" \
    --data-binary @${GENDIR}/${DOMAIN_SOURCE}-folder.yaml -o ${GENDIR}/${DOMAIN_SOURCE}-create-folder-output.log

#Get the SOURCE JENKINS_HOME PV name where we want to take a snapshot from
# We also get some attributes from from the original pv and pvc that we need to reclaim the EFS volume
VOLUME_NAME_SOURCE=$(kubectl get "pvc/jenkins-home-${DOMAIN_SOURCE_TEAM_PREFIX}${DOMAIN_SOURCE}-0" -n ${NAMESPACE_SOURCE} -o go-template={{.spec.volumeName}})
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
kubectl wait pod/rescue-pod  --for condition=ready --timeout=60s

echo "########SYNC JOBS########"
#This command will sync all jobs and folders excluding the build
#time kubectl exec -ti rescue-pod -- rsync -avz --exclude="*/builds/" /tmp/jenkins_home_source/jobs/$DOMAIN_SOURCE/jobs/ /tmp/jenkins_home_destination/jobs/$DOMAIN_SOURCE/jobs
time kubectl exec -ti rescue-pod -- rsync -az  /tmp/jenkins_home_source/jobs/$DOMAIN_SOURCE/jobs/ /tmp/jenkins_home_destination/jobs/$DOMAIN_SOURCE/jobs/

#cp seems to faster rather than rsync
time kubectl exec -ti rescue-pod -- cp -Rf /tmp/jenkins_home_source/jobs/$DOMAIN_SOURCE/jobs /tmp/jenkins_home_destination/jobs/$DOMAIN_SOURCE/


#reload new Jobs from disk
curl -L -s -u $TOKEN -XPOST  "https://ci.acaternberg.pscbdemos.com/$DOMAIN_DESTINATION/reload" \

echo "########CLEANUP RESOURCES########"
#Clean resources
function cleanUpResources {
  echo "delete rescue-pod , we don't need it anymore"
  kubectl delete pod rescue-pod -n $NAMESPACE_DESTINATION || true
  echo "delete rescue-pvc-${DOMAIN_SOURCE} , we don't need it anymore"
  kubectl delete pvc rescue-efs-pvc-${DOMAIN_SOURCE} -n $NAMESPACE_DESTINATION || true
  kubectl delete pv rescue-efs-pv-${DOMAIN_SOURCE} || true
  kubectl get pod,pv,pvc -n $NAMESPACE_DESTINATION
}
#https://www.putorius.net/using-trap-to-exit-bash-scripts-cleanly.html#google_vignette
trap cleanUpResources  SIGINT SIGTERM ERR EXIT


