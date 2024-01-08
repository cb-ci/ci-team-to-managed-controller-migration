#!/bin/bash

source ./envvars.sh

#In case we trigger this script from a loop, it will take the controller name from the fhe first parameter $1
export DOMAIN_SOURCE=${1:-$DOMAIN_SOURCE}
export CONTROLLER_URL=${BASE_URL}"/"${DOMAIN_SOURCE}
export NAMESPACE_CB_CORE=${2:-"cloudbees-core"}

function checkControllerOnline () {
  # We have to wait until ingress is created and we can call the Jenkins HealthCheck with state 200
  while [ ! -n "$(curl  -IL  ${1}/whoAmI/api/json?tree=authenticated | grep -o  'HTTP/2 200')" ]
  do
    #echo "wait 30 sec for State HTTP 200:  ${CONTROLLER_URL}/login"
    echo "wait 30 sec for State HTTP 200:  ${1}/whoAmI/api/json?tree=authenticated"
    sleep 30
  done
}

# We render the CasC template instances for cjoc-controller-items.yaml and the casc-folder (target folder)
# All variables from the envvars.sh will be substituted
envsubst < templates/create-mc.yaml > $GENDIR/${DOMAIN_SOURCE}-mc.yaml
envsubst < templates/create-folder.yaml > $GENDIR/${DOMAIN_SOURCE}-folder.yaml

# We switch to the cloudbees namespace, where the TC runs
#kubens $NAMESPACE
kubectl config set-context $(kubectl config current-context) --namespace=$NAMESPACE_CB_CORE

#CREATE MC CONTROLLER
# We apply the cjoc-controller-items.yaml to cjoc. Cjoc will create a new MC for us using our $GENDIR/${DOMAIN_SOURCE}.yaml
echo "------------------  CREATING MANAGED CONTROLLER ------------------"
curl -XPOST \
   --user $TOKEN \
   "${CJOC_URL}/casc-items/create-items" \
    -H "Content-Type:text/yaml" \
   --data-binary @$GENDIR/${DOMAIN_SOURCE}-mc.yaml

# We wait until our new Managed Controller pod is up
echo "------------------  WAITING FOR CONTROLLER TO COME UP ------------------"
checkControllerOnline $CONTROLLER_URL

# Now we apply the target Folder to the Managed Controller.
# This is the root folder where we want to migrate our credentials and jobs to
echo "------------------  CREATING INITIAL TEAM FOLDER ------------------"
curl -v  -XPOST \
    --user $TOKEN \
    "${CONTROLLER_URL}/casc-items/create-items" \
     -H "Content-Type:text/yaml" \
    --data-binary @$GENDIR/${DOMAIN_SOURCE}-folder.yaml -o $GENDIR/create-folder-output.log
# curl  -XPOST -u ${TOKEN} ${CONTROLLER_URL}/casc-items/create-items -d @${DOMAIN_SOURCE}-folder.yaml
# sleep 180

# COPY JOBS
# We copy the jobs folder recursive from TC to the new folder on MC
echo -n  "------------------  COPYING JOBS FOLDER ------------------ \n
      THIS COPIES ALL JOBS TO LOCAL DISK AND THEN UPLOAD TO MANAGED CONTROLLER \n
      THE PERFORMANCE DEPENDS ON THE NETWORK BANDWIDTH"
mkdir -p $GENDIR/teams-${DOMAIN_SOURCE}-jobs
#kubectl exec -it teams-${DOMAIN_SOURCE}-0 --  tar -cvzf /tmp/${DOMAIN_SOURCE}-job.tar.gz -C /var/jenkins_home/jobs/
kubectl cp teams-${DOMAIN_SOURCE}-0:var/jenkins_home/jobs/${DOMAIN_SOURCE}/jobs/helloworld $GENDIR/teams-${DOMAIN_SOURCE}-jobs/
kubectl cp $GENDIR/teams-${DOMAIN_SOURCE}-jobs/. ${DOMAIN_SOURCE}-0:var/jenkins_home/jobs/${DOMAIN_SOURCE}/jobs
#kubectl exec -it ${DOMAIN_SOURCE}-0 --  tar -xvf /tmp/${DOMAIN_SOURCE}-job.tar.gz -C /var/jenkins_home/jobs/

# Now we restart the MC
curl -u ${TOKEN} -X POST ${CONTROLLER_URL}/reload 2>&1 > /dev/null
checkControllerOnline $CONTROLLER_URL

# EXPORT FOLDER CREDENTIALS
echo "------------------  EXPORT FOLDER CREDENTIALS  ------------------"
curl -o ./credentials-migration/export-credentials-folder-level.groovy https://raw.githubusercontent.com/cloudbees/jenkins-scripts/master/credentials-migration/export-credentials-folder-level.groovy
curl --data-urlencode "script=$(cat ./credentials-migration/export-credentials-folder-level.groovy)" \
--user $TOKEN ${BASE_URL}/teams-${DOMAIN_SOURCE}/scriptText  -o $GENDIR/test-folder.creds
tail -n 1  $GENDIR/test-folder.creds | sed  -e "s#\[\"##g"  -e "s#\"\]##g"  | tee  $GENDIR/folder-imports.txt

# IMPORT FOLDER CREDENTIALS
echo "------------------  IMPORT FOLDER CREDENTIALS  ------------------"
kubectl cp $GENDIR/folder-imports.txt ${DOMAIN_SOURCE}-0:/var/jenkins_home/
curl -o ./credentials-migration/update-credentials-folder-level.groovy https://raw.githubusercontent.com/cloudbees/jenkins-scripts/master/credentials-migration/update-credentials-folder-level.groovy  
cat ./credentials-migration/update-credentials-folder-level.groovy | sed  "s#^\/\/ encoded.*#encoded = [new File(\"/var\/jenkins_home\/folder-imports.txt\").text]#g" >  $GENDIR/update-credentials-folder-level.groovy
curl --data-urlencode "script=$(cat $GENDIR/update-credentials-folder-level.groovy)" \
--user $TOKEN ${BASE_URL}/${DOMAIN_SOURCE}/scriptText

# EXPORT SYSTEM CREDENTIALS
echo "------------------  EXPORT SYSTEM CREDENTIALS  ------------------"
curl -o ./credentials-migration/export-credentials-system-level.groovy https://raw.githubusercontent.com/cloudbees/jenkins-scripts/master/credentials-migration/export-credentials-system-level.groovy
curl --data-urlencode "script=$(cat ./credentials-migration/export-credentials-system-level.groovy)" \
--user $TOKEN ${BASE_URL}/teams-${DOMAIN_SOURCE}/scriptText  -o $GENDIR/test-system-folder.creds
tail -n 1  $GENDIR/test-system-folder.creds | sed  -e "s#\[\"##g"  -e "s#\"\]##g"  | tee  $GENDIR/system-imports.txt

# IMPORT SYSTEM CREDENTIALS
echo "-------------------- IMPORT SYSTEM CREDENTIALS  ------------------"
kubectl cp $GENDIR/system-imports.txt ${DOMAIN_SOURCE}-0:/var/jenkins_home/
curl -o ./credentials-migration/update-credentials-system-level.groovy https://raw.githubusercontent.com/cloudbees/jenkins-scripts/master/credentials-migration/update-credentials-system-level.groovy
cat ./credentials-migration/update-credentials-system-level.groovy | sed  "s#^\/\/ encoded.*#encoded = [new File(\"/var\/jenkins_home\/system-imports.txt\").text]#g" >  $GENDIR/update-credentials-folder-level.groovy
curl --data-urlencode "script=$(cat $GENDIR/update-credentials-folder-level.groovy)" \
--user $TOKEN ${BASE_URL}/${DOMAIN_SOURCE}/scriptText
