# Google Cloud Server Setup Guide

## How to Create a High CPU Server for KeeLoq Experiments

### Step 1: Open Google Cloud Shell

1. Go to https://console.cloud.google.com
2. Click the terminal icon in the top right toolbar
3. Wait for Cloud Shell to start

### Step 2: Set Your Project

Check your current project:
```bash
gcloud config get-value project
```

If you need to change it:
```bash
gcloud config set project YOUR_PROJECT_ID
```

### Step 3: Create the Server

For a 56 CPU server (recommended):
```bash
gcloud compute instances create keeloq-experiments \
  --zone=us-central1-a \
  --machine-type=c2d-highcpu-56 \
  --image-family=ubuntu-2204-lts \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=50GB \
  --boot-disk-type=pd-ssd
```

### Step 4: Transfer Files to the Server

Copy your project files from Cloud Shell to the server:
```bash
gcloud compute scp --recurse ./fixedpoint keeloq-experiments:~/ --zone=us-central1-a
```

Or copy a single file:
```bash
gcloud compute scp myfile.py keeloq-experiments:~/ --zone=us-central1-a
```

### Step 5: Connect to the Server

```bash
gcloud compute ssh keeloq-experiments --zone=us-central1-a
```

When it asks about SSH keys, press Enter to accept defaults.

### Step 6: Check Your Server

Once connected, verify CPU count:
```bash
nproc
```

This should show 56 (or your chosen CPU count).

## Other Options

### Different CPU Counts

Replace `c2d-highcpu-56` with:
- `c2d-highcpu-32` for 32 CPUs
- `c2d-highcpu-16` for 16 CPUs

### Different Zones

If one zone is full, try:
- `us-central1-b`
- `us-central1-c` 
- `us-west1-a`

### Delete the Server When Done

Before deleting, copy results back to Cloud Shell:
```bash
gcloud compute scp keeloq-experiments:~/results.txt ./ --zone=us-central1-a
```

Then delete the server:
```bash
gcloud compute instances delete keeloq-experiments --zone=us-central1-a
```

## Common Problems

**Quota exceeded**: Choose a smaller machine type
**Machine type not found**: Try a different zone
**Already exists**: Delete the old one first

## Cost Warning

High CPU servers cost money! Always delete them when finished.