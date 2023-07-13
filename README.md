# CloudBees Team Controller to Managed Controller-Migration

# Objective

This repo is about the automation steps that are required to migrate CloudBees Team Controller (**TC**) to Managed Controllers (**MC**).
The scripts is just done for K8s Platforms, CI traditional has not been done yet. 

Read about the required steps and background here:

* https://docs.cloudbees.com/docs/cloudbees-ci-migration/latest/migrating-controllers/ 
* https://docs.cloudbees.com/docs/cloudbees-ci-kb/latest/client-and-managed-controllers/migrating-jenkins-instances 
* https://docs.cloudbees.com/docs/cloudbees-ci/latest/cloud-setup-guide/using-teams 

To automate the migration from TC to MC, the following steps are required (taken from he documentation links above) 

* CREATE TARGET MC
* ON MC: create target folder (where to migrate the Teams/teams root folder to )
* COPY JOBS (recursive and folders) FROM TC TO MC
* MIGRATE CREDENTIALS

if you see the `script.sh`it contains the steps for the phases above.

# How to start

* Create a TC you want to migrate  to MC
* Optional: create some jobs (or use existing ones)
* copy `envvars.sh.template`  to `envvars.sh`
  * ``` cp envvars.sh.template envvars.sj```
  * Adjust your variables, see the comments 
* Execute the migration script
  * ```./script.sh ```
* See the `gen` dir and logs


# JSON API 
* https://www.cloudbees.com/blog/taming-jenkins-json-api-depth-and-tree
* https://garygeorge84.medium.com/jenkins-api-with-node-4d3826322367

> curl -u $TOKEN "https://sda.acaternberg.flow-training.beescloud.com/cjoc/view/all/job/Teams/api/json&tree=jobs[name,lastBuild[number,duration,timestamp,result,changeSet[items[msg,author[fullName]]]]]"
> curl -u $TOKEN "https://sda.acaternberg.flow-training.beescloud.com/cjoc/view/all/job/Teams/api/json?depth=2&pretty=true?tree=jobs" | jq