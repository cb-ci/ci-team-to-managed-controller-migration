#!/bin/bash

source ./envvars.sh

GEN_DIR=gen
mkdir -p $GEN_DIR


envsubst < ${CREATE_MM_TEMPLATE_YAML} > $GEN_DIR/${CONTROLLER_NAME}.yaml
envsubst < ${CREATE_MM_FOLDER_TEMPLATE_YAML} > $GEN_DIR/${CONTROLLER_NAME}-folder.yaml

kubens $NAMESPACE

#CREATE CONTROLLER
echo "------------------  CREATING MANAGED CONTROLLER ------------------"
curl -XPOST \
   --user $TOKEN \
   "${CJOC_URL}/casc-items/create-items" \
    -H "Content-Type:text/yaml" \
   --data-binary @$GEN_DIR/${CONTROLLER_NAME}.yaml


# We wait until our new Managed Controller pod is up
echo "------------------  WAITING FOR CONTROLLER TO COME UP ------------------"
kubectl wait pods  -l tenant=${CONTROLLER_NAME} --for condition=Ready --timeout=90s
#We have to wait until ingress is created and we call and Jenkins HealthCheck with state 200
while [ ! -n "$(curl  -IL  ${CONTROLLER_URL}/login | grep -o  'HTTP/2 200')" ]
do
  echo "wait 30 sec for State HTTP 200:  ${CONTROLLER_URL}/login"
  sleep 30
done


# Now we apply the target Folder to the Managed Controller.
# This is the root Folder where we want to migrate our credentials and jobs to
echo "------------------  CREATING INITAL TEAM FOLDER ------------------"
curl -v  -XPOST \
    --user $TOKEN \
    "${CONTROLLER_URL}/casc-items/create-items" \
     -H "Content-Type:text/yaml" \
    --data-binary @$GEN_DIR/${CONTROLLER_NAME}-folder.yaml -o $GEN_DIR/create-folder-output.log

# curl  -XPOST -u ${TOKEN} ${CONTROLLER_URL}/casc-items/create-items -d @${CONTROLLER_NAME}-folder.yaml
# curl  -XPOST -u admin:authto113527cd5c2db897c8b6eb59b3ab803f24ken ${CJOC_URL}/casc-items/create-items -d @${CONTROLLER_NAME}.yaml

# sleep 180

# COPY CREDENTIAL IMPORT SCRIPT TO TARGET POD
# kubectl cp credentials-migration/export-credentials-system-level.groovy teams-${CONTROLLER_NAME}-0:/var/jenkins_home/ 
# kubectl cp credentials-migration/export-credentials-folder-level.groovy teams-${CONTROLLER_NAME}-0:/var/jenkins_home/ 

# COPY CREDENTIAL EXPORT SCRIPT TO TARGET POD
# kubectl cp credentials-migration/update-credentials-system-level.groovy ${CONTROLLER_NAME}-0:/var/jenkins_home/ 
# kubectl cp credentials-migration/update-credentials-folder-level.groovy ${CONTROLLER_NAME}-0:/var/jenkins_home/ 

# COPY JOBS
echo "------------------  COPYING JOBS FOLDER ------------------"
mkdir -p $GEN_DIR/teams-${CONTROLLER_NAME}-jobs
# kubectl exec -it teams-${CONTROLLER_NAME}-0 --  tar -cvzf ${CONTROLLER_NAME}-job.tar.gz $GEN_DIR/teams-${CONTROLLER_NAME}-jobs/
# kubectl exec -it teams-wpg-0 --  tar -cvzf wpg-job.tar.gz gen/testfodler

kubectl cp teams-${CONTROLLER_NAME}-0:/var/jenkins_home/jobs/  $GEN_DIR/teams-${CONTROLLER_NAME}-jobs/
kubectl cp $GEN_DIR/teams-${CONTROLLER_NAME}-jobs/. ${CONTROLLER_NAME}-0:/var/jenkins_home/jobs/


# EXPORT FOLDER CREDENTIALS
echo "------------------  IMPORT FOLDER CREDENTIALS  ------------------"
curl -o ./credentials-migration/export-credentials-folder-level.groovy https://raw.githubusercontent.com/cloudbees/jenkins-scripts/master/credentials-migration/export-credentials-folder-level.groovy
curl --data-urlencode "script=$(cat ./credentials-migration/export-credentials-folder-level.groovy)" \
--user $TOKEN ${BASE_URL}/teams-${CONTROLLER_NAME}/scriptText  -o $GEN_DIR/test-folder.creds
tail -n 1  test-folder.creds | sed  -e "s#\[\"##g"  -e "s#\"\]##g"  | tee  $GEN_DIR/folder-imports.txt

# IMPORT FOLDER CREDENTIALS
echo "------------------  IMPORT FOLDER CREDENTIALS  ------------------"
kubectl cp folder-imports.txt ${CONTROLLER_NAME}-0:/var/jenkins_home/
curl -o ./credentials-migration/update-credentials-folder-level.groovy https://raw.githubusercontent.com/cloudbees/jenkins-scripts/master/credentials-migration/update-credentials-folder-level.groovy  
cat ./credentials-migration/update-credentials-folder-level.groovy | sed  "s#^\/\/ encoded.*#encoded = [new File(\"/var\/jenkins_home\/folder-imports.txt\").text]#g" >  $GEN_DIR/update-credentials-folder-level.groovy
curl --data-urlencode "script=$(cat $GEN_DIR/update-credentials-folder-level.groovy)" \
--user $TOKEN ${BASE_URL}/${CONTROLLER_NAME}/scriptText

# EXPORT SYSTEM CREDENTIALS
echo "------------------  IMPORT SYSTEM CREDENTIALS  ------------------"
curl -o ./credentials-migration/export-credentials-system-level.groovy https://raw.githubusercontent.com/cloudbees/jenkins-scripts/master/credentials-migration/export-credentials-system-level.groovy

curl --data-urlencode "script=$(cat ./credentials-migration/export-credentials-system-level.groovy)" \
--user $TOKEN ${BASE_URL}/teams-${CONTROLLER_NAME}/scriptText  -o $GEN_DIR/test-system-folder.creds
tail -n 1  $GEN_DIR/test-system-folder.creds | sed  -e "s#\[\"##g"  -e "s#\"\]##g"  | tee  $GEN_DIR/system-imports.txt

# IMPORT SYSTEM CREDENTIALS
echo "-------------------- IMPORT SYSTEM CREDENTIALS  ------------------"
kubectl cp $GEN_DIR/system-imports.txt ${CONTROLLER_NAME}-0:/var/jenkins_home/
curl -o ./credentials-migration/update-credentials-system-level.groovy https://raw.githubusercontent.com/cloudbees/jenkins-scripts/master/credentials-migration/update-credentials-system-level.groovy

cat ./credentials-migration/update-credentials-system-level.groovy | sed  "s#^\/\/ encoded.*#encoded = [new File(\"/var\/jenkins_home\/system-imports.txt\").text]#g" >  $GEN_DIR/update-credentials-folder-level.groovy
curl --data-urlencode "script=$(cat $GEN_DIR/update-credentials-folder-level.groovy)" \
--user $TOKEN ${BASE_URL}/${CONTROLLER_NAME}/scriptText

# curl --data-urlencode "script=$(cat /tmp/system-message-example.groovy)" -v --user ${TOKEN_TEAM_LUIGI} ${BASE_URL}/teams-luigi/scriptText
kctl exec -ti pod -- tar - xvzf /tmp/jobs.tar.gp   -C /var/jenkins_home/jobs