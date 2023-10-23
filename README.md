# CloudBees Team Controller to Managed Controller-Migration

# Objective

This repo is about the automation steps that are required to migrate CloudBees Team Controller (**TC**) to Managed Controllers (**MC**).
The scripts is just done for K8s Platforms, CI traditional has not been done yet. 

Read about the required steps and background here:

* https://docs.cloudbees.com/docs/cloudbees-ci-migration/latest/migrating-controllers/ 
* https://docs.cloudbees.com/docs/cloudbees-ci-kb/latest/client-and-managed-controllers/migrating-jenkins-instances 
* https://docs.cloudbees.com/docs/cloudbees-ci/latest/cloud-setup-guide/using-teams 

To automate the migration from TC to MC, the following phases are required (taken from he documentation links above) 

* CREATE MC
* ON MC: create target folder (where to migrate the Teams/teams root folder to )
* COPY JOBS FROM TC TO MC
* MIGRATE CREDENTIALS

if you see the [migrateTC2MC.sh script](./migrateTC2MC.sh), it contains the steps for the phases above.

# How to start

* Create a TC you want to migrate  to MC
  * Optional: For testing purposes, create some jobs on the TC (or use existing ones)
* copy `envvars.sh.template`  to `envvars.sh`
  * ``` cp envvars.sh.template envvars.sh```
  * Adjust your variables in your `envvars.sh` file, see [Envvars](##\ Envvars)
* Execute the migration script
  * ```./migrateTC2MC.sh ```
* See the `gen` dir and logs


## Envvars

| VARIABLE                         | VALUE/Example           | 
|----------------------------------|------------------------------| 
| `BASE_URL`                       | https://ci.example.com       | 
| `CJOC_URL`                       | ${BASE_URL}/cjoc             | 
| `CONTROLLER_NAME`                | ciController001              | 
| `CONTROLLER_IMAGE_VERSION`       | 2.401.2.5                    | 
| `TOKEN`                          | user:123XYZ                  | 
| `CREATE_MM_TEMPLATE_YAML`        | templates/create-mm.yaml     | 
| `CREATE_MM_FOLDER_TEMPLATE_YAML` | templates/create-folder.yaml | 


# JSON API 
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

