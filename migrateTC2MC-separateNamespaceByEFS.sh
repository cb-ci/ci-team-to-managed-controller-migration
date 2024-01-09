#! /bin/bash
#enable debugging output
#set -x

source ./envvars.sh

#Name of the original Team or Managed Controller you want to copy jobs from
export DOMAIN_SOURCE=${1:-"myteam"}
#Teamcontrollers have always the prefix "teams-". If the source controller is a Managed Controller, set the DOMAIN_SOURCE_TEAM_PREFIX to empty string""
#Team Controller prefix
export DOMAIN_SOURCE_TEAM_PREFIX="teams-"
#Managed Controller prefix
#DOMAIN_SOURCE_TEAM_PREFIX=""

#Name of the destination Team or Managed Controller you want to copy jobs to
export DOMAIN_DESTINATION=${2:-"myteam"}

#Name of the original namespace where your $DOMAIN_SOURCE Controller is located
export NAMESPACE_SOURCE=${3:-"cloudbees-core"}
#Name of the destination namespace where your $DOMAIN_DESTINATION Controller is located
export NAMESPACE_DESTINATION=${4:-"cloudbees-controllers"}

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
# We apply the cjoc-controller-items.yaml to cjoc. Cjoc will create a new Managed Controller for us using our $GENDIR/${DOMAIN_DESTINATION}.yaml
echo "------------------  CREATING MANAGED CONTROLLER ${DOMAIN_DESTINATION}------------------"
export CONTROLLER_NAME="${DOMAIN_DESTINATION}"
envsubst < templates/create-mc.yaml > $GENDIR/${DOMAIN_DESTINATION}-mc.yaml
curl -XPOST \
   --user $TOKEN \
   "${CJOC_URL}/casc-items/create-items" \
    -H "Content-Type:text/yaml" \
   --data-binary @$GENDIR/${DOMAIN_DESTINATION}-mc.yaml
# We wait until our new Managed Controller pod is up
echo "------------------  WAITING FOR CONTROLLER TO COME UP ------------------"
checkControllerOnline $BASE_URL/$DOMAIN_DESTINATION


# Now we apply the target Folder to the Managed Controller.
# This is the root folder where we want to migrate our credentials and jobs to
echo "------------------  CREATING INITIAL TEAM FOLDER ${DOMAIN_SOURCE} on Managed Controller ${DOMAIN_DESTINATION}------------------"
export CONTROLLER_NAME="${DOMAIN_SOURCE}"
envsubst < templates/create-folder.yaml > ${GENDIR}/${DOMAIN_SOURCE}-folder.yaml
curl -v  -XPOST \
    --user $TOKEN \
    "${BASE_URL}/${DOMAIN_DESTINATION}/casc-items/create-items" \
     -H "Content-Type:text/yaml" \
    --data-binary @${GENDIR}/${DOMAIN_SOURCE}-folder.yaml -o ${GENDIR}/${DOMAIN_SOURCE}-create-folder-output.log

#Get the SOURCE JENKINS_HOME PV name where we want to copy from
# We also get some attributes from from the original pv and pvc that we need to reclaim the EFS volume
VOLUME_NAME_SOURCE=$(kubectl get "pvc/jenkins-home-${DOMAIN_SOURCE_TEAM_PREFIX}${DOMAIN_SOURCE}-0" -n ${NAMESPACE_SOURCE} -o go-template={{.spec.volumeName}})
VOLUME_HANDLE_SOURCE=$(kubectl get pv $VOLUME_NAME_SOURCE -n ${NAMESPACE_SOURCE} -o go-template={{.spec.csi.volumeHandle}})
VOLUME_ATTRIBUTE_SOURCE=$(kubectl get pv $VOLUME_NAME_SOURCE -o   go-template={{.spec.csi.volumeAttributes}} | sed  's#map\[storage.kubernetes.io/csiProvisionerIdentity:##'  | sed 's#]##')
VOLUME_CAPACITY_STORAGE_SOURCE=$(kubectl get pv $VOLUME_NAME_SOURCE -o   go-template={{.spec.capacity.storage}})
VOLUME_STORAGE_CLASSNAME_SOURCE=$(kubectl get pv $VOLUME_NAME_SOURCE -o   go-template={{.spec.storageClassName}})

#create a rescue PV,PVC,POD for the new volume. It references the original EFS filesystem of the $DOMAIN_SOURCE Controller
cat <<EOF | kubectl -n $NAMESPACE_DESTINATION apply -f -
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
kubectl wait pod/rescue-pod -n $NAMESPACE_DESTINATION  --for condition=ready --timeout=60s || false

echo "########SYNC JOBS########"

######copy jobs using the rescue pod. `cp` seems to be the fastest approach
time kubectl  -n $NAMESPACE_DESTINATION  exec -ti rescue-pod -- cp -Rf /tmp/jenkins_home_source/jobs/$DOMAIN_SOURCE/jobs /tmp/jenkins_home_destination/jobs/$DOMAIN_SOURCE/

####### TEST AND DEVELOPMENT: The following commented lines are just for testing purpose

# see sync options https://repost.aws/knowledge-center/efs-copy-data-in-parallel
#####rsync all jobs and folders excluding the build
#with rsync we can exclude the build history, see filter --exclude="*/builds/"
#time kubectl  -n $NAMESPACE_DESTINATION  exec -ti rescue-pod -- rsync -az --exclude="*/builds/" /tmp/jenkins_home_source/jobs/$DOMAIN_SOURCE/jobs/ /tmp/jenkins_home_destination/jobs/$DOMAIN_SOURCE/jobs/
#time kubectl  -n $NAMESPACE_DESTINATION  exec -ti rescue-pod -- rsync -az  /tmp/jenkins_home_source/jobs/$DOMAIN_SOURCE/jobs/ /tmp/jenkins_home_destination/jobs/$DOMAIN_SOURCE/jobs/

#####using parallel is not faster rather than normal cp
#time kubectl  -n $NAMESPACE_DESTINATION  exec -ti rescue-pod -- find -L   /tmp/jenkins_home_source/jobs/$DOMAIN_SOURCE/jobs/ -type f | parallel  rsync -az {}  /tmp/jenkins_home_destination/jobs/$DOMAIN_SOURCE/jobs/
#time kubectl  -n $NAMESPACE_DESTINATION  exec -ti rescue-pod -- find -L  /tmp/jenkins_home_source/jobs/$DOMAIN_SOURCE/jobs/  -type f | parallel -j 32 cp  -Rf {} /tmp/jenkins_home_destination/jobs/$DOMAIN_SOURCE/jobs/

#######aproach with tar.gz seems not to be faster than cp
#time kubectl  -n $NAMESPACE_DESTINATION  exec -ti rescue-pod -- sh -c "cd /tmp/jenkins_home_source/jobs/$DOMAIN_SOURCE/;tar -czf /tmp/jenkins_home_destination/jobs/$DOMAIN_SOURCE/jobs.tar.gz jobs"
#time kubectl  -n $NAMESPACE_DESTINATION  exec -ti ${DOMAIN_DESTINATION}-0 -- bash -c "cd /var/jenkins_home/jobs/$DOMAIN_SOURCE/;tar -xzf jobs.tar.gz;rm jobs.tar.gz"


######Here we copy just one hello world job for testing purposes and to reduce the time consumption
#time kubectl  -n $NAMESPACE_DESTINATION  exec -ti rescue-pod -- mkdir -p /tmp/jenkins_home_destination/jobs/$DOMAIN_SOURCE/jobs/
#time kubectl  -n $NAMESPACE_DESTINATION  exec -ti rescue-pod -- cp -Rf /tmp/jenkins_home_source/jobs/$DOMAIN_SOURCE/jobs/helloworld /tmp/jenkins_home_destination/jobs/$DOMAIN_SOURCE/jobs/

######Here we copy directly from the DOMAIN_SOURCE to a local workerstation/bastion host and then upload to the target DOMAIN_DESTINATION
#The rescue Pod is not used here
#kubectl cp teams-${DOMAIN_SOURCE}-0:var/jenkins_home/jobs/${DOMAIN_SOURCE}/jobs/helloworld $GENDIR/teams-${DOMAIN_SOURCE}-jobs/
#kubectl cp $GENDIR/teams-${DOMAIN_SOURCE}-jobs/. ${DOMAIN_SOURCE}-0:var/jenkins_home/jobs/${DOMAIN_SOURCE}/jobs

####### END TEST AND DEVELOPMENT



# EXPORT FOLDER CREDENTIALS
echo "------------------  EXPORT FOLDER CREDENTIALS  ------------------"
curl -o ./credentials-migration/export-credentials-folder-level.groovy https://raw.githubusercontent.com/cloudbees/jenkins-scripts/master/credentials-migration/export-credentials-folder-level.groovy
curl --data-urlencode "script=$(cat ./credentials-migration/export-credentials-folder-level.groovy)" \
--user $TOKEN ${BASE_URL}/teams-${DOMAIN_SOURCE}/scriptText  -o $GENDIR/test-folder.creds
tail -n 1  $GENDIR/test-folder.creds | sed  -e "s#\[\"##g"  -e "s#\"\]##g"  | tee  $GENDIR/folder-imports.txt

# IMPORT FOLDER CREDENTIALS
echo "------------------  IMPORT FOLDER CREDENTIALS  ------------------"
kubectl cp $GENDIR/folder-imports.txt ${DOMAIN_DESTINATION}-0:/var/jenkins_home/ -n $NAMESPACE_DESTINATION
curl -o ./credentials-migration/update-credentials-folder-level.groovy https://raw.githubusercontent.com/cloudbees/jenkins-scripts/master/credentials-migration/update-credentials-folder-level.groovy
cat ./credentials-migration/update-credentials-folder-level.groovy | sed  "s#^\/\/ encoded.*#encoded = [new File(\"/var\/jenkins_home\/folder-imports.txt\").text]#g" >  $GENDIR/update-credentials-folder-level.groovy
curl --data-urlencode "script=$(cat $GENDIR/update-credentials-folder-level.groovy)" \
--user $TOKEN ${BASE_URL}/${DOMAIN_DESTINATION}/scriptText

# EXPORT SYSTEM CREDENTIALS
echo "------------------  EXPORT SYSTEM CREDENTIALS  ------------------"
curl -o ./credentials-migration/export-credentials-system-level.groovy https://raw.githubusercontent.com/cloudbees/jenkins-scripts/master/credentials-migration/export-credentials-system-level.groovy
curl --data-urlencode "script=$(cat ./credentials-migration/export-credentials-system-level.groovy)" \
--user $TOKEN ${BASE_URL}/teams-${DOMAIN_SOURCE}/scriptText  -o $GENDIR/test-system-folder.creds
tail -n 1  $GENDIR/test-system-folder.creds | sed  -e "s#\[\"##g"  -e "s#\"\]##g"  | tee  $GENDIR/system-imports.txt

# IMPORT SYSTEM CREDENTIALS
echo "-------------------- IMPORT SYSTEM CREDENTIALS  ------------------"
kubectl cp $GENDIR/system-imports.txt ${DOMAIN_DESTINATION}-0:/var/jenkins_home/  -n $NAMESPACE_DESTINATION
curl -o ./credentials-migration/update-credentials-system-level.groovy https://raw.githubusercontent.com/cloudbees/jenkins-scripts/master/credentials-migration/update-credentials-system-level.groovy
cat ./credentials-migration/update-credentials-system-level.groovy | sed  "s#^\/\/ encoded.*#encoded = [new File(\"/var\/jenkins_home\/system-imports.txt\").text]#g" >  $GENDIR/update-credentials-folder-level.groovy
curl --data-urlencode "script=$(cat $GENDIR/update-credentials-folder-level.groovy)" \
--user $TOKEN ${BASE_URL}/${DOMAIN_DESTINATION}/scriptText

#reload new Jobs from disk
curl -L -s -u $TOKEN -XPOST  "https://ci.acaternberg.pscbdemos.com/$DOMAIN_DESTINATION/reload" 2>&1 > /dev/null


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




