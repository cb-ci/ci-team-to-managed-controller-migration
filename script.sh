#!/bin/bash
export BASE_URL="https://cloudbees.luigi-lab.worldpay.io"
export CJOC_URL=${BASE_URL}"/cjoc"

export CONTROLLER_NAME="wpg"
export CONTROLLER_URL=${BASE_URL}"/"${CONTROLLER_NAME}
export CONTROLLER_IMAGE_VERSION="2.346.4.1"
export BUNDLE_NAME="wpg"
export TOKEN=""
export TOKEN_TEAM_LUIGI=""

# cat create-mm.yaml 
envsubst < create-mm.yaml > ${CONTROLLER_NAME}.yaml
envsubst < create-folder.yaml > ${CONTROLLER_NAME}-folder.yaml

#CREATE CONTROLLER
curl -XPOST \
    --user $TOKEN \
    "${CJOC_URL}/casc-items/create-items" \
     -H "Content-Type:text/yaml" \
    --data-binary @${CONTROLLER_NAME}.yaml

# sleep 180

curl -XPOST \
    --user $TOKEN \
    "${CONTROLLER_URL}/casc-items/create-items" \
     -H "Content-Type:text/yaml" \
    --data-binary @${CONTROLLER_NAME}-folder.yaml

# curl  -XPOST -u ${TOKEN} ${CONTROLLER_URL}/casc-items/create-items -d @${CONTROLLER_NAME}-folder.yaml
# curl  -XPOST -u admin:authto113527cd5c2db897c8b6eb59b3ab803f24ken ${CJOC_URL}/casc-items/create-items -d @${CONTROLLER_NAME}.yaml

# sleep 180

# COPY CREDENTIAL IMPORT SCRIPT TO TARGET POD
# kubectl cp credentials-migration/export-credentials-system-level.groovy teams-${CONTROLLER_NAME}-0:/var/jenkins_home/ -n cloudbees-core
# kubectl cp credentials-migration/export-credentials-folder-level.groovy teams-${CONTROLLER_NAME}-0:/var/jenkins_home/ -n cloudbees-core

# COPY CREDENTIAL EXPORT SCRIPT TO TARGET POD
# kubectl cp credentials-migration/update-credentials-system-level.groovy ${CONTROLLER_NAME}-0:/var/jenkins_home/ -n cloudbees-core
# kubectl cp credentials-migration/update-credentials-folder-level.groovy ${CONTROLLER_NAME}-0:/var/jenkins_home/ -n cloudbees-core

# EXPORT CREDENTIALS
curl --data-urlencode "script=$(cat ./credentials-migration/export-credentials-folder-level.groovy)" \
--user $TOKEN ${BASE_URL}/teams-${CONTROLLER_NAME}/scriptText  -o test-folder.creds
tail -n 1  test-folder.creds | sed  -e "s#\[\"##g"  -e "s#\"\]##g"  | tee  folder-imports.txt

# IMPORT CREDENTIALS
kubectl cp folder-imports.txt ${CONTROLLER_NAME}-0:/var/jenkins_home/ -n cloudbees-core
curl -o ./credentials-migration/update-credentials-folder-level.groovy https://raw.githubusercontent.com/cloudbees/jenkins-scripts/master/credentials-migration/update-credentials-folder-level.groovy  
cat ./credentials-migration/update-credentials-folder-level.groovy | sed "s#^\/\/ encoded.*#encoded = [new File(\"/var/jenkins_home/folder-imports.txt\").text]#"
# encoded = [new File("/home/jenkins/credentials.txt").text]

curl --data-urlencode "script=$(cat ./credentials-migration/update-credentials-folder-level.groovy)" \
--user $TOKEN ${BASE_URL}/${CONTROLLER_NAME}/scriptText



# curl --data-urlencode "script=$(cat /tmp/system-message-example.groovy)" -v --user ${TOKEN_TEAM_LUIGI} ${BASE_URL}/teams-luigi/scriptText
