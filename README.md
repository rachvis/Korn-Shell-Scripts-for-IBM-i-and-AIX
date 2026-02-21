# PowerVS Korn Shell Scripts — IBM i & AIX Native Cloud Management

A collection of **Korn shell (ksh) + cURL** scripts that allow you to manage IBM Cloud PowerVS resources (snapshots, clones, exports) **natively from AIX or IBM i**, without requiring the IBM Cloud CLI binary.

---

## The Problem

IBM Cloud provides a powerful CLI and REST API for managing PowerVS resources — creating snapshots, cloning volumes, exporting images, and more. For most platforms (Windows, Mac, Linux), this works great: install the CLI binary, authenticate once, and run simple commands like:

```sh
ibmcloud pi instance snapshot create <instance-id> --name my-snapshot
```

**But AIX and IBM i are a different story.**

The IBM Cloud CLI is written in Go and IBM does not ship a build for AIX or IBM i. This means there is no supported way to run IBM Cloud CLI commands natively on these operating systems. If you run workloads on Power Systems — particularly AIX or IBM i virtual machines in IBM Cloud PowerVS — you hit a hard wall the moment you want to automate cloud operations from within the OS itself.

### Why does running from within the OS matter?

For many critical operations, you need to coordinate OS-level actions with cloud API calls in a precise sequence. Take creating a consistent snapshot as a concrete example. It is not simply a matter of calling an API — it involves multiple steps that must happen in order:

1. **Quiesce the database** — suspend I/O so in-flight transactions are not split across a snapshot boundary
2. **Flush filesystem buffers** — run `sync` to ensure data is written from memory to disk
3. **Trigger the cloud snapshot** — call the PowerVS API while the system is in a known-good state
4. **Resume database operations** — unquiesce as quickly as possible to minimise application downtime
5. **Confirm the snapshot completed** — poll the API until the snapshot reaches `available` status

Steps 1, 2, and 4 are OS commands. Steps 3 and 5 are cloud API calls. You need a script that can do all five in one automated, reliable sequence — and that script needs to run **on the AIX or IBM i machine itself**.

A workaround like running the IBM Cloud CLI on a separate Linux jump host and SSHing to AIX for the OS steps adds fragile dependencies, network hops, credential sprawl, and SSH key management overhead. It also makes the scripts much harder to schedule, monitor, and maintain.

### Why not just write raw cURL calls?

The IBM Cloud REST API is fully capable and well-documented. But writing raw cURL commands is genuinely painful for the people who need these scripts:

- **Token management** — IBM Cloud APIs require a short-lived IAM bearer token. You cannot store your API key and use it directly in requests. You must first exchange the API key for a token, track when the token expires (usually 1 hour), and refresh it before it lapses. Getting this wrong silently breaks your scripts mid-run.
- **Request complexity** — a snapshot request requires constructing a JSON body with the correct volume IDs, instance IDs, CRN headers, and endpoint URLs. A single malformed field returns a cryptic 400 error.
- **Polling** — most PowerVS operations are asynchronous. The API returns immediately with a task or snapshot ID, but you must write a polling loop to wait for completion. Without polling, you have no way to know if the operation succeeded before moving on to the next step.
- **Script length** — even a "simple" snapshot with quiesce logic and completion polling runs to nearly 100 lines of raw cURL and shell. Multiply that by every operation your team needs to automate and it becomes a significant burden to write, debug, and maintain — especially across API version changes.

---

## The Solution

This repository provides a set of **Korn shell scripts** that wrap the IBM Cloud PowerVS REST API. They give you CLI-like simplicity for the operations that matter most on Power Systems workloads, while running natively on AIX and IBM i with zero binary dependencies.

```sh
# Instead of this (not possible on AIX/IBM i):
ibmcloud pi instance snapshot create <id> --name my-snapshot

# You run this — natively on AIX or IBM i:
./scripts/snapshot.ksh -n "my-snapshot"
```

The scripts handle everything that makes raw cURL difficult:

- **Automatic token management** — your API key is exchanged for an IAM bearer token on first use and cached in `/tmp`. The token is transparently refreshed before it expires, so long-running operations never fail mid-way through a polling loop.
- **No external dependencies** — the only tools required are `ksh` and `curl`, both of which are native to AIX 7.x+ and available in IBM i PASE. There is no Go runtime, no Node.js, no Python, no package manager.
- **JSON parsing with `awk`** — IBM Cloud API responses are JSON. Rather than requiring `jq` (not available on AIX/IBM i by default), all parsing is done with `awk`, which is built into every AIX and IBM i system.
- **Crash-consistent snapshots** — the snapshot script coordinates DB2 quiesce, filesystem sync, the API call, and DB2 unquiesce in the correct order. Database downtime is minimised to only the seconds between quiesce and snapshot trigger.
- **Async polling built in** — every long-running operation (snapshots, clones, exports) has a polling loop with configurable timeout and interval. The script does not return until the operation completes or fails.
- **Structured logging** — every run produces a timestamped log file in `/tmp` so you have an audit trail for scheduled jobs and incident diagnosis.

The scripts are designed to be readable and adaptable. If IBM updates an API endpoint or you need to add a step to the quiesce sequence for your specific database, the code is straightforward shell — no compilation, no framework knowledge required.

---

---

## Repository Structure

```
powervs-ksh-scripts/
├── config/
│   └── powervs.conf.template   # Configuration template (copy → powervs.conf)
├── lib/
│   ├── auth.ksh                # IAM token acquisition and caching
│   └── utils.ksh               # Logging, JSON parsing, API call wrapper, polling
├── scripts/
│   ├── snapshot.ksh            # Create a crash-consistent snapshot (with DB quiesce)
│   ├── clone.ksh               # Clone volumes attached to a PowerVS VM
│   ├── export.ksh              # Export a snapshot to IBM Cloud Object Storage
│   └── list-snapshots.ksh      # List all snapshots for a VM
├── .gitignore
└── README.md
```

---

## Prerequisites

### On Your AIX or IBM i System

| Requirement | Version | How to Check |
|---|---|---|
| Korn shell | Any | `ksh --version` |
| curl | 7.x or later | `curl --version` |
| awk | Any | `awk --version` |
| date with `%s` support | AIX 7.1+ | `date +%s` |

**IBM i (OS/400) note:** Run all scripts from the **PASE** (Portable App Solutions Environment) shell, not from a 5250 session. Open PASE with `CALL QP2TERM` or SSH directly to the IBM i system.

On IBM i, ensure curl is installed:
```sh
# Check if curl is available in PASE
/QOpenSys/usr/bin/curl --version
```
If curl is missing, install it via IBM i Access for Web or the open-source package manager (ACS or `yum` for IBM i).

### In IBM Cloud

You need an active **IBM Cloud account** with at least one **PowerVS workspace** and a running **AIX or IBM i virtual server instance**.

---

## Part 1 — IBM Cloud Account & PowerVS Setup

> **Skip to Part 2 if you already have a PowerVS workspace and VM running.**

### Step 1.1 — Create an IBM Cloud Account

1. Go to [https://cloud.ibm.com/registration](https://cloud.ibm.com/registration)
2. Fill in your details and verify your email.
3. Log in to [https://cloud.ibm.com](https://cloud.ibm.com).

### Step 1.2 — Create a PowerVS Workspace

A PowerVS *workspace* is the container for all your Power Virtual Server resources in a given region.

1. From the IBM Cloud console, click **☰ Menu → PowerVS → Workspaces**.
2. Click **Create workspace**.
3. Fill in:
   - **Name**: e.g., `my-powervs-workspace`
   - **Region**: Choose the region closest to you (e.g., `us-east`, `eu-de`).
   - **Resource group**: Select or create one.
4. Click **Create**. The workspace takes 1–3 minutes to provision.
5. Once created, click the workspace name to open its details page. **Note your workspace GUID** from the URL or the details panel — you will need it as `CLOUD_INSTANCE_ID`.

### Step 1.3 — Create a Subnet (Private Network)

1. Inside your workspace, go to **Subnets → Create subnet**.
2. Set a name (e.g., `aix-subnet`), CIDR (e.g., `192.168.100.0/24`), and DNS server (`9.9.9.9`).
3. Click **Create**.

### Step 1.4 — Upload or Import an AIX / IBM i Image

If you don't have an existing AIX or IBM i boot image, you can use a stock image from IBM:

1. In your workspace, go to **Boot images → Stock images**.
2. Select an AIX or IBM i image (e.g., `AIX-7300-01-01`).
3. Click **Import to workspace**. This may take several minutes.

### Step 1.5 — Create a Virtual Server Instance

1. In your workspace, go to **Virtual server instances → Create instance**.
2. Configure:
   - **Name**: e.g., `my-aix-server`
   - **SSH key**: Upload a public key (used to SSH into the VM).
   - **Boot image**: Select the AIX or IBM i image imported in Step 1.4.
   - **Machine type**: `s922` or `e980` — choose based on your workload.
   - **Storage tier**: `Tier 1` for production, `Tier 3` for dev/test.
   - **Network**: Attach the subnet created in Step 1.3.
3. Click **Create**. The instance takes 5–20 minutes to boot.
4. Once the instance is **Active**, click it to view its details. **Copy the Instance ID** (shown as *PVM Instance ID*). This is your `PVM_INSTANCE_ID`.

### Step 1.6 — Set Up IBM Cloud Object Storage (for Exports only)

Required only if you plan to use `export.ksh`.

1. From the IBM Cloud catalog, search for **Object Storage** and create an instance.
2. Create a **bucket** (e.g., `powervs-snapshot-exports`) in the same region as your PowerVS workspace.
3. Go to **Service credentials → New credential**, enable **HMAC credentials**.
4. Expand the credential and copy the `access_key_id` and `secret_access_key` values. These become `COS_ACCESS_KEY` and `COS_SECRET_KEY` in your config.

---

## Part 2 — Getting an IBM Cloud API Key

All scripts authenticate with IBM Cloud via an **API key**, which is exchanged for a short-lived IAM bearer token automatically.

### Step 2.1 — Create an API Key

1. Go to [https://cloud.ibm.com/iam/apikeys](https://cloud.ibm.com/iam/apikeys).
2. Click **Create an IBM Cloud API key**.
3. Give it a name (e.g., `powervs-ksh-scripts-key`) and click **Create**.
4. **Immediately copy the API key value** — it is only shown once.

### Step 2.2 — Assign IAM Permissions

The API key's service ID or user must have these minimum permissions on your PowerVS workspace:

| Service | Role Required |
|---|---|
| Power Systems Virtual Server | **Editor** or **Manager** |
| IBM Cloud Object Storage (export only) | **Writer** on the target bucket |

To assign roles:
1. Go to [https://cloud.ibm.com/iam/users](https://cloud.ibm.com/iam/users) → your user → **Access** tab.
2. Click **Assign access** → **PowerVS** → select your workspace → **Editor** role.
3. Repeat for COS if needed.

---

## Part 3 — Installing the Scripts on AIX / IBM i

### Step 3.1 — Transfer the Scripts

From your workstation, copy the repo to the AIX or IBM i system using `scp`:

```sh
scp -r powervs-ksh-scripts/ root@<your-aix-ip>:/opt/powervs-ksh-scripts/
```

Or clone directly on the AIX system if `git` is available:

```sh
git clone https://github.com/your-org/powervs-ksh-scripts.git /opt/powervs-ksh-scripts
```

On IBM i, place files under `/QOpenSys/home/` or any directory accessible from PASE.

### Step 3.2 — Set Execute Permissions

```sh
cd /opt/powervs-ksh-scripts
chmod 750 scripts/*.ksh lib/*.ksh
chmod 640 config/powervs.conf.template
```

### Step 3.3 — Create the Configuration File

Copy the template and populate it with your values:

```sh
cp config/powervs.conf.template config/powervs.conf
chmod 600 config/powervs.conf    # restrict access — file contains credentials
vi config/powervs.conf
```

Fill in each value:

```sh
# Your IBM Cloud API key (from Step 2.1)
IBMCLOUD_API_KEY="abc123..."

# CRN of your PowerVS workspace
# Found in IBM Cloud Console → Resource List → your workspace → Details
POWER_CRN="crn:v1:bluemix:public:power-iaas:us-east:a/ACCT_ID:WS_GUID::"

# Workspace GUID (the WS_GUID part of the CRN)
CLOUD_INSTANCE_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

# Regional API endpoint matching your workspace region
POWER_API_ENDPOINT="https://us-east.power-iaas.cloud.ibm.com"

# PVM Instance ID of your AIX/IBM i VM
PVM_INSTANCE_ID="yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy"

# (Export only) IBM Cloud Object Storage HMAC credentials
COS_ACCESS_KEY="..."
COS_SECRET_KEY="..."
```

**Where to find the CRN:**
1. IBM Cloud Console → **Resource list** → your PowerVS workspace → click the name.
2. In the details panel, click **Details** and copy the full CRN string.

**Where to find the PVM Instance ID:**
1. IBM Cloud Console → PowerVS workspace → **Virtual server instances** → click your VM.
2. The Instance ID is shown in the details panel, or in the URL: `.../pvm-instances/<PVM_INSTANCE_ID>`.

### Step 3.4 — Verify curl Connectivity

Test that your AIX or IBM i system can reach the IBM Cloud IAM endpoint:

```sh
curl -s -o /dev/null -w "%{http_code}" https://iam.cloud.ibm.com/identity/token
# Expected output: 400 (bad request, but connectivity is confirmed)
```

If you see a connection error, check that your system's network allows HTTPS outbound to `*.cloud.ibm.com`. Configure proxy settings in `config/powervs.conf` if required:

```sh
# Add to config/powervs.conf if a proxy is required
export https_proxy="http://proxy.example.com:8080"
export no_proxy="localhost,127.0.0.1"
```

---

## Part 4 — Using the Scripts

### 4.1 — Create a Snapshot (with Database Quiesce)

Creates a crash-consistent snapshot of a PowerVS VM. The script automatically:
- Quiesces DB2 (on AIX, if configured) and flushes filesystem buffers
- Calls the PowerVS API to capture the snapshot
- Immediately resumes database operations
- Polls until the snapshot reaches `available` state

```sh
cd /opt/powervs-ksh-scripts

# Basic snapshot — captures all attached volumes
./scripts/snapshot.ksh -n "pre-patch-$(date +%Y%m%d)"

# Snapshot with description
./scripts/snapshot.ksh -n "weekly-backup" -d "Weekly consistent backup"

# Snapshot of specific volumes only (comma-separated volume IDs)
./scripts/snapshot.ksh -n "data-vol-snap" -v "vol-id-001,vol-id-002"
```

**DB2 quiesce setup (AIX only):**
Set the `DB2_INSTANCE` variable in `config/powervs.conf` to enable automatic DB2 quiesce/unquiesce:

```sh
# Add to config/powervs.conf
DB2_INSTANCE="db2inst1"    # the OS user that owns your DB2 instance
```

If `DB2_INSTANCE` is not set, the DB2 quiesce step is skipped and only an OS-level `sync` is run.

**Expected output:**

```
[2025-08-21 10:32:01] [INFO]  ========================================================
[2025-08-21 10:32:01] [INFO]  PowerVS Snapshot Script Starting
[2025-08-21 10:32:01] [INFO]  Snapshot Name : pre-patch-20250821
[2025-08-21 10:32:01] [INFO]  STEP 1: Quiescing database and syncing filesystem...
[2025-08-21 10:32:03] [INFO]    DB2 quiesce successful.
[2025-08-21 10:32:03] [INFO]    Filesystem sync complete.
[2025-08-21 10:32:03] [INFO]  STEP 2: Building snapshot API request...
[2025-08-21 10:32:03] [INFO]  STEP 3: Calling PowerVS API to create snapshot...
[2025-08-21 10:32:05] [INFO]    Snapshot creation initiated. Snapshot ID: snap-abc123
[2025-08-21 10:32:05] [INFO]  STEP 4: Resuming database operations...
[2025-08-21 10:32:06] [INFO]    DB2 unquiesce successful. Database is back online.
[2025-08-21 10:32:06] [INFO]  STEP 5: Waiting for snapshot to become available...
[2025-08-21 10:32:26] [INFO]    Status at 20s: in_progress
[2025-08-21 10:32:46] [INFO]    Status at 40s: available
[2025-08-21 10:32:46] [INFO]  SUCCESS: Snapshot 'pre-patch-20250821' is available.
```

### 4.2 — List Snapshots

List all snapshots associated with your configured VM:

```sh
./scripts/list-snapshots.ksh

# List snapshots for a different VM
./scripts/list-snapshots.ksh -s "other-pvm-instance-id"
```

Sample output:
```
Snapshots for VM: yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy
-------------------------------------------------------------------
ID: snap-abc123   Name: pre-patch-20250821    Status: available    Created: 2025-08-21T10:32:46Z
ID: snap-def456   Name: weekly-backup         Status: available    Created: 2025-08-14T02:00:12Z
-------------------------------------------------------------------
```

### 4.3 — Clone a VM's Volumes

Clones all storage volumes attached to a PowerVS VM. Cloned volumes can then be attached to a new VM instance for dev/test isolation or migration.

```sh
# Clone all volumes of the configured VM
./scripts/clone.ksh -n "prod-clone-$(date +%Y%m%d)"

# Clone a different VM's volumes
./scripts/clone.ksh -n "staging-clone" -s "other-pvm-instance-id"

# Clone with replication enabled on the cloned volumes
./scripts/clone.ksh -n "dr-clone" -r true
```

**Expected output:**

```
[2025-08-21 11:00:01] [INFO]  STEP 1: Retrieving volumes attached to source VM...
[2025-08-21 11:00:02] [INFO]    Attached volumes: vol-id-001,vol-id-002
[2025-08-21 11:00:02] [INFO]  STEP 2: Syncing filesystems before clone operation...
[2025-08-21 11:00:02] [INFO]  STEP 3: Calling PowerVS API to start volume clone...
[2025-08-21 11:00:03] [INFO]    Clone task initiated. Task ID: task-xyz789
[2025-08-21 11:00:03] [INFO]  STEP 4: Waiting for clone task to complete...
[2025-08-21 11:02:43] [INFO]    Clone status at 160s: completed (100% complete)
[2025-08-21 11:02:43] [INFO]  SUCCESS: Volume clone 'prod-clone-20250821' is complete.
```

### 4.4 — Export a Snapshot to Cloud Object Storage

Exports an existing snapshot to an IBM Cloud Object Storage bucket for long-term retention or cross-region DR.

```sh
# First, get the snapshot ID
./scripts/list-snapshots.ksh

# Export the snapshot
./scripts/export.ksh \
  -i "snap-abc123" \
  -b "my-backup-bucket" \
  -r "us-south"

# Export with a custom object prefix
./scripts/export.ksh \
  -i "snap-abc123" \
  -b "dr-bucket" \
  -r "eu-de" \
  -p "aix-server-1/exports/"
```

> **Note:** Exports can take 10–60 minutes depending on volume size. The script polls every 30 seconds and logs progress. Do not interrupt the script — the export continues in IBM Cloud even if the script is killed; check the IBM Cloud Console under your PowerVS workspace > **Jobs**.

### 4.5 — Running as a Cron Job

Schedule regular snapshots using `cron` on AIX:

```sh
# Edit crontab
crontab -e

# Add: Take a snapshot every day at 2:00 AM
0 2 * * * /opt/powervs-ksh-scripts/scripts/snapshot.ksh -n "daily-$(date +\%Y\%m\%d)" >> /var/log/powervs_cron.log 2>&1
```

On IBM i, use the IBM i Job Scheduler (`ADDJOBSCDE`) or PASE cron:

```sh
# In PASE
crontab -e
0 2 * * * /opt/powervs-ksh-scripts/scripts/snapshot.ksh -n "daily-$(date +%Y%m%d)" >> /tmp/powervs_cron.log 2>&1
```

---

## Part 5 — Troubleshooting

### IAM Token Errors

**Symptom:** `ERROR: Failed to acquire IAM token. HTTP Status: 400`

- Verify `IBMCLOUD_API_KEY` in `config/powervs.conf` is correct and has not been deleted.
- Check that the key has the required IAM permissions (Part 2, Step 2.2).
- Test the API key manually:

```sh
curl -X POST https://iam.cloud.ibm.com/identity/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=urn:ibm:params:oauth:grant-type:apikey&apikey=YOUR_KEY_HERE"
```

### cURL SSL Errors on AIX

**Symptom:** `curl: (60) SSL certificate problem: unable to get local issuer certificate`

AIX may not have IBM Cloud CA certificates in its trust store. Update the CA bundle:

```sh
# Download the Mozilla CA bundle
curl -k -o /etc/ssl/certs/cacert.pem https://curl.se/ca/cacert.pem
export CURL_CA_BUNDLE=/etc/ssl/certs/cacert.pem
```

Add the `export` line to your `.profile` or `config/powervs.conf` to make it permanent.

### API 401 / 403 Errors

**Symptom:** `API call failed. Status: 401` or `Status: 403`

- 401: Token expired mid-run (unlikely — auth.ksh refreshes proactively). Re-run the script.
- 403: The API key's user or service ID lacks the required role on the PowerVS workspace. Check IAM permissions.

### `date +%s` Not Working (Older AIX)

On AIX versions before 7.1, `date +%s` may not be supported. The auth library uses it for token expiry tracking. If you see errors, set a static large value for EXPIRY in `lib/auth.ksh` or upgrade to AIX 7.1+:

```sh
# Workaround: always re-fetch the token (remove expiry check)
# In lib/auth.ksh, replace ensure_valid_token() body with:
ensure_valid_token() {
    get_iam_token
}
```

### IBM i PASE: `ksh` Not Found

On some IBM i systems, ksh may be at a non-standard path. Use:

```sh
/QOpenSys/usr/bin/ksh ./scripts/snapshot.ksh -n "test"
```

Or add `/QOpenSys/usr/bin` to your PATH in `.profile`:

```sh
export PATH=/QOpenSys/usr/bin:/QOpenSys/usr/bin/X11:$PATH
```

---

## Security Considerations

- **Never commit `config/powervs.conf`** — it contains your API key. The `.gitignore` already excludes it.
- Set file permissions to `600` on `powervs.conf`: `chmod 600 config/powervs.conf`
- Consider using **IBM Cloud Secrets Manager** to store the API key and retrieve it at runtime via a cURL call, rather than storing it in a flat file.
- Rotate your IBM Cloud API key periodically from [https://cloud.ibm.com/iam/apikeys](https://cloud.ibm.com/iam/apikeys).
- The IAM token cache files are written to `/tmp` with a process-specific suffix and are deleted on script exit via a `trap` handler.

---

## Reference

| Resource | URL |
|---|---|
| PowerVS API Reference | https://cloud.ibm.com/apidocs/power-cloud |
| IBM Cloud IAM API | https://cloud.ibm.com/apidocs/iam-identity-token-api |
| PowerVS Regions & Endpoints | https://cloud.ibm.com/docs/power-iaas?topic=power-iaas-regions |
| IBM i PASE Overview | https://www.ibm.com/docs/en/i/7.5?topic=administration-pase |
| AIX curl documentation | https://www.ibm.com/docs/en/aix |
