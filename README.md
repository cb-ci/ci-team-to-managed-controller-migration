# CloudBees Team Controller to Managed Controller-Migration

# Objective

This repo is about the automation steps that are required to migrate CloudBees Team Controller (**TC**) to Managed Controllers (**MC**).
The scripts is just done for K8s Platforms, CI traditional has not been done yet. 

Read about the required steps and background here:

* https://docs.cloudbees.com/docs/cloudbees-ci-migration/latest/migrating-controllers/ 
* https://docs.cloudbees.com/docs/cloudbees-ci-kb/latest/client-and-managed-controllers/migrating-jenkins-instances 
* https://docs.cloudbees.com/docs/cloudbees-ci-migration/latest/splitting-controllers/modern-platforms#migrating-data
* https://docs.cloudbees.com/docs/cloudbees-ci/latest/cloud-setup-guide/using-teams 
* https://repost.aws/knowledge-center/efs-copy-data-in-parallel
* https://aws.amazon.com/about-aws/whats-new/2019/05/aws-datasync-now-supports-efs-to-efs-transfer/

To automate the migration from TC to MC, the following phases are required (taken from he documentation links above) 

* CREATE MC: create a destination Managed Controller
* ON MC: create target folder (where to migrate the Teams/teams root folder to )
* COPY JOBS FROM TC TO MC 
* MIGRATE CREDENTIALS
* RELOAD MC configuration from disk


# How to start

* Create a TC that you want to migrate to MC
  * Optional: For testing purposes, create some jobs on the TC (or use existing ones)
* copy `envvars.sh.template`  to `envvars.sh`
  * ``` cp envvars.sh.template envvars.sh```
  * Adjust your variables in your `envvars.sh` file
* Execute the migration script, see below
* See the `gen` dir and logs


## EFS: Migrate from TC to MC in a new namespace, using a rescue POD 
see `./migrateTC2MC-separateNamespaceByEFS.sh`

Params:
* 1: name of existing Team Controller
* 2: name of target Managed Controller
* 3: name of Team Controller namespace
* 4: name of Managed Controller namespace

Example
```
./migrateTC2MC-separateNamespaceByEFS.sh  myteam-tc myteam-mc cloudbees-core cloudbees-controllers
``` 

## EBS: Migrate from TC to MC in a new namespace, using a rescue POD and EBS Snapshot

see `./migrateTC2MC-separateNamespaceByEBSSnapshot.sh`

Params:
* 1: name of existing Team Controller
* 2: name of target Managed Controller
* 3: name of Team Controller namespace
* 4: name of Managed Controller namespace

Example
```
./migrateTC2MC-separateNamespaceByEBSSnapshot.sh  myteam-tc myteam-mc cloudbees-core cloudbees-controllers
```


# Benchmark for rescue Pod approach

Tested with EFS:

* For testing purpose 2500 test jobs have been created on a Team Controller, see [templates/testjob.yaml](templates/testjob.yaml)
* 2500 simple Pipeline jobs with 1 entry in the build history result in ~ 30.000 files  overall
* The job dir size is ~250 MB

Time consumed for a copy using a rescue PVC/POD
```
real	12m56.919s
user	0m0.560s
sys  	0m0.226s
```

# Next Steps

* Verify if S3 backup /restore is faster 

# Extra stuff,not related to the migration script

## Migrate PVC to another namespace

see example https://webera.blog/recreate-an-existing-pvc-in-a-new-namespace-but-reusing-the-same-pv-without-data-loss-2c7326c0035a 

## JSON API 
* https://www.cloudbees.com/blog/taming-jenkins-json-api-depth-and-tree
* https://gist.github.com/justlaputa/5634984
* https://garygeorge84.medium.com/jenkins-api-with-node-4d3826322367

## Examples

```
 curl -u $TOKEN "https://$BASSE_URL/cjoc/view/all/job/Teams/api/json?pretty=true&tree=jobs\[name,url\]"
{
  "_class" : "com.cloudbees.hudson.plugins.folder.Folder",
  "jobs" : [
    {
      "_class" : "com.cloudbees.opscenter.server.model.ManagedMaster",
      "name" : "team1",
      "url" : "https://example.com/cjoc/view/all/job/Teams/job/team1/"
    }
  ]
}
```

````
curl -u $TOKEN "https://$BASSE_URL/cjoc/view/all/job/Teams/api/json?depth=2&pretty=true?tree=jobs" | jq
````




