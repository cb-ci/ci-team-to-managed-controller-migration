# CloudBees Team Controller to Managed Controller Migration

This repository provides scripts and resources to automate the migration of Jenkins instances from CloudBees Team Controllers (TC) to Managed Controllers (MC) on Kubernetes platforms.

## Objective

The primary goal is to automate the steps required to migrate a Team Controller and its data to a new Managed Controller. This includes creating the new controller, migrating jobs, and handling credentials.

---

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Configuration](#configuration)
- [Usage](#usage)
  - [EFS Method](#efs-method)
  - [EBS Method](#ebs-method)
- [Performance Benchmarks](#performance-benchmarks)
- [Future Work](#future-work)
- [Appendix](#appendix)
  - [Technical Notes](#technical-notes)
  - [Helpful Links](#helpful-links)

---

## Overview

The migration process involves several phases, based on the official CloudBees documentation:

1.  **Create MC**: A new destination Managed Controller is created.
2.  **Create Target Folder**: A folder is created on the new MC to house the migrated data.
3.  **Copy Jobs**: Job configurations and history are copied from the TC to the MC.
4.  **Migrate Credentials**: Credentials are exported from the TC and imported into the MC.
5.  **Reload Configuration**: The MC is reloaded to apply the new changes.

This repository provides two main approaches for the "Copy Jobs" phase, depending on your underlying storage solution:

*   **EFS**: Uses a temporary "rescue" Pod to mount the EFS-based Persistent Volume Claims (PVCs) from both the source TC and the target MC to perform the copy.
*   **EBS**: Clones the source EBS-based volume using a snapshot and attaches it to the new MC.

---

## Prerequisites

Before starting the migration, ensure you have the following tools installed and configured:

*   `kubectl`: To interact with your Kubernetes cluster.
*   `oc`: (If using OpenShift) The OpenShift Command-Line Interface.
*   `aws-cli`: (If using AWS services like EFS DataSync) The AWS Command-Line Interface.
*   Access to the Kubernetes cluster where CloudBees CI is running.

---

## Configuration

The migration scripts rely on environment variables set in a dedicated file.

1.  **Create the configuration file:**
    Copy the template to create your own environment file.

    ```bash
    cp envvars.sh.template envvars.sh
    ```

2.  **Edit `envvars.sh`:**
    Update the variables in `envvars.sh` to match your environment.

| Variable                 | Description                                                                                             |
| ------------------------ | ------------------------------------------------------------------------------------------------------- |
| `AWS_DEFAULT_REGION`     | The AWS region where your cluster is located.                                                           |
| `BASE_URL`               | The base URL for your CloudBees CI instance (e.g., `https://your-cloudbees.example.com`).                 |
| `CJOC_URL`               | The full URL for the CloudBees CI Operations Center. Defaults to `${BASE_URL}/cjoc`.                      |
| `TOKEN`                  | Your Jenkins API token in the format `USER:APITOKEN`.                                                     |
| `GENDIR`                 | The directory where generated artifacts will be stored. Defaults to `generated`.                          |
| `CONTROLLER_IMAGE_VERSION` | The Docker image version to use for the new Managed Controller (e.g., `2.426.2.2`).                     |
| `BUNDLE_NAME`            | The CasC bundle name for the new controller (e.g., `master/controller-base`).                             |
| `STORAGE_CLASS`          | The Kubernetes StorageClass to use for the new controller's persistent volume (e.g., `efs-sc`).         |

---

## Usage

After configuring your `envvars.sh` file, you can run the migration scripts. The scripts will create a `generated` directory containing logs and temporary files.

### EFS Method

This method is for environments where Jenkins home directories are stored on **EFS**. It works by creating a rescue pod that mounts both the source and destination PVCs to copy the data.

**Script:** `migrateTC2MC-separateNamespaceByEFS.sh`

**Parameters:**

1.  `TC_NAME`: Name of the source Team Controller.
2.  `MC_NAME`: Name for the target Managed Controller.
3.  `TC_NAMESPACE`: Kubernetes namespace of the source TC.
4.  `MC_NAMESPACE`: Kubernetes namespace for the target MC.

**Example:**

```bash
# Source your environment variables
source ./envvars.sh

# Run the migration
./migrateTC2MC-separateNamespaceByEFS.sh myteam-tc myteam-mc cloudbees-core cloudbees-controllers
```

### EBS Method

This method is for environments where Jenkins home directories are stored on **EBS**. It uses an EBS snapshot to clone the data.

**Script:** `migrateTC2MC-separateNamespaceByEBSSnapshot.sh`

**Parameters:**

1.  `TC_NAME`: Name of the source Team Controller.
2.  `MC_NAME`: Name for the target Managed Controller.
3.  `TC_NAMESPACE`: Kubernetes namespace of the source TC.
4.  `MC_NAMESPACE`: Kubernetes namespace for the target MC.

**Example:**

```bash
# Source your environment variables
source ./envvars.sh

# Run the migration
./migrateTC2MC-separateNamespaceByEBSSnapshot.sh myteam-tc myteam-mc cloudbees-core cloudbees-controllers
```

---

## Performance Benchmarks

Performance testing was conducted to compare different data transfer methods.

### Test Data Generation

A large number of jobs were generated for testing purposes:

*   **To create test data:** `for i in {1..25000}; do cp -Rf testjob testjob-$i; done`
*   **To count files:** `find $JENKINS_HOME/jobs -type f | wc -l`

### EFS Rescue Pod Approach

*   **Test Load**: 2,500 simple pipeline jobs (~30,000 files, ~250 MB).
*   **Time Taken**: **~13 minutes**.

```
real	12m56.919s
user	0m0.560s
sys  	0m0.226s
```

### AWS EFS DataSync Approach

*   **Test Load**: 20,491 jobs (~246,000 files, ~2 GB).
*   **Time Taken**: **~11 minutes** (including verification).

### Conclusion

**AWS DataSync is significantly faster** than the rescue pod approach. It transferred over 8 times the amount of data in less time. AWS documentation suggests it can be up to 10x faster than other methods.

---

## Future Work

- [ ] Add a script to automate migration using **AWS DataSync**.

---

## Appendix

### Technical Notes

*   **Migrating PVCs:** For manual PVC migration between namespaces, see this article: [Recreate an existing PVC in a new namespace](https://webera.blog/recreate-an-existing-pvc-in-a-new-namespace-but-reusing-the-same-pv-without-data-loss-2c7326c0035a).
*   **Jenkins JSON API:** The Jenkins API can be used to query information about jobs and controllers.
    *   Example: Get a list of all teams.
        ```bash
        curl -u $TOKEN "https://$BASE_URL/cjoc/view/all/job/Teams/api/json?pretty=true&tree=jobs[name,url]"
        ```

### Helpful Links

*   **CloudBees Documentation**
    *   [Migrating Controllers](https://docs.cloudbees.com/docs/cloudbees-ci-migration/latest/migrating-controllers/)
    *   [KB: Migrating Jenkins Instances](https://docs.cloudbees.com/docs/cloudbees-ci-kb/latest/client-and-managed-controllers/migrating-jenkins-instances)
    *   [Splitting Controllers on Modern Platforms](https://docs.cloudbees.com/docs/cloudbees-ci-migration/latest/splitting-controllers/modern-platforms#migrating-data)
    *   [Using Teams](https://docs.cloudbees.com/docs/cloudbees-ci/latest/cloud-setup-guide/using-teams)
*   **AWS Documentation**
    *   [Using AWS DataSync to transfer data between Amazon EFS file systems](https://aws.amazon.com/about-aws/whats-new/2019/05/aws-datasync-now-supports-efs-to-efs-transfer/)
    *   [Configure data verification options with DataSync](https://docs.aws.amazon.com/datasync/latest/userguide/configure-data-verification-options.html)
    *   [Pattern: Synchronize data between Amazon EFS file systems](https://docs.aws.amazon.com/prescriptive-guidance/latest/patterns/synchronize-data-between-amazon-efs-file-systems-in-different-aws-regions-by-using-aws-datasync.html)