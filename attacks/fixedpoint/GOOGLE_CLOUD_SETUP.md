# Google Cloud CPU Setup for KeeLoq Experiments

This guide runs the CPU fixed-point pipeline. A C2D instance has no NVIDIA GPU, so the GPU benchmark timings in [README.md](README.md) do not apply. The scanner generates all $2^{32}$ pairs from a known test key; this is a full-codebook experiment, not a short smoke test.

## Select a Project and Machine

Open [Cloud Shell](https://console.cloud.google.com/) and select your billing-enabled project:

```bash
gcloud config set project YOUR_PROJECT_ID
```

Check which zones offer the requested machine type:

```bash
gcloud compute machine-types list \
  --filter='name=c2d-highcpu-56' --format='table(name,zone)'
```

`c2d-highcpu-56` provides 56 vCPUs, not 56 physical cores. Choose an available zone from the listing and check your project's regional C2D quota. Smaller options include `c2d-highcpu-16` and `c2d-highcpu-32`; availability and quota still apply. See Google's [C2D specifications](https://docs.cloud.google.com/compute/docs/compute-optimized-machines) and [machine-type listing command](https://docs.cloud.google.com/sdk/gcloud/reference/compute/machine-types/list).

```bash
KEELOQ_ZONE=YOUR_SELECTED_ZONE
gcloud compute instances create keeloq-experiments \
  --zone="$KEELOQ_ZONE" \
  --machine-type=c2d-highcpu-56 \
  --image-family=ubuntu-2204-lts \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=50GB \
  --boot-disk-type=pd-ssd
```

## Transfer and Build

Clone the public repository in Cloud Shell, then copy the self-contained attack folder:

```bash
git clone https://github.com/hadipourh/KeeLoq.git
cd KeeLoq
gcloud compute scp --recurse attacks/fixedpoint \
  keeloq-experiments:~/ --zone="$KEELOQ_ZONE"
gcloud compute ssh keeloq-experiments --zone="$KEELOQ_ZONE"
```

If already cloned, enter that repository instead of cloning again. On the remote instance:

```bash
sudo apt-get update
sudo apt-get install -y build-essential python3-venv
cd ~/fixedpoint
python3 -m venv venv
source venv/bin/activate
python -m pip install python-sat
make build
nproc
```

`make build` compiles the CPU scanner and native singleton helper without starting the scan. Run one full experiment when ready:

```bash
make attack KEY=0x5CEC6701B79FD949 THREADS="$(nproc)"
```

For a multi-key experiment, `make benchmark THREADS="$(nproc)" BENCH_KEYS=100 BENCH_SEED=42` creates `fixedpoint_benchmark.csv` and `fixedpoint_benchmark.txt`. This runs 100 full scans and can take substantially longer. The expected presence rate is about 84.7%; some keys have no true fixed point and are expected to fail.

## Retrieve Results and Delete the Instance

Exit the SSH session to return to Cloud Shell. Copy the generated data back; the zone variable remains in the original Cloud Shell session:

```bash
exit
gcloud compute scp keeloq-experiments:~/fixedpoint/fixedpoint_data.txt \
  ./ --zone="$KEELOQ_ZONE"
```

If you ran the benchmark, also retrieve its outputs:

```bash
gcloud compute scp \
  keeloq-experiments:~/fixedpoint/fixedpoint_benchmark.csv \
  keeloq-experiments:~/fixedpoint/fixedpoint_benchmark.txt \
  ./ --zone="$KEELOQ_ZONE"
```

After checking the downloaded files, delete the experiment instance to stop its compute charges:

```bash
gcloud compute instances delete keeloq-experiments --zone="$KEELOQ_ZONE"
```

Check the deletion prompt for attached disks you want to retain; retained disks remain billable.

## Troubleshooting

- **Quota exceeded:** check the relevant regional C2D quota, reduce the requested size if it fits that quota, or request an increase.
- **Machine type unavailable:** choose a zone listed for that type; listed support does not guarantee spare capacity.
- **Instance name already exists:** connect to your existing experiment or choose another name consistently in the commands. Do not delete an unrelated instance to free the name.
- **CUDA not found:** use the CPU commands above. GPU experiments require a separately provisioned NVIDIA instance and CUDA setup.
