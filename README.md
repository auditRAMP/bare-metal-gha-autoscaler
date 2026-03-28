# Bare-Metal GitHub Actions Auto-Scaler

A lightweight, highly resilient bare-metal daemon that orchestrates ephemeral GitHub Actions runners natively on older, resource-constrained macOS and Linux hardware. 

## Why Build This? (Bare-Metal vs Kubernetes ARC)

While modern CI/CD workloads typically rely on **Kubernetes (K8s)** and the official **Actions Runner Controller (ARC)** for auto-scaling, orchestrating a full Minikube or Helm cluster requires immense underlying compute and memory. 

If you have an older Mac Mini, a spare Linux box, or vintage hardware, running a Kubernetes control plane simply to host runners will enthusiastically suffocate the machine. 

This project was built to bypass Kubernetes entirely. By directly manipulating native shell-scripts and directly communicating with the GitHub Actions REST API, this daemon brings sophisticated, Kubernetes-level auto-scaling to bare-metal systems, allowing you to breathe new life into older hardware with near-zero orchestration overhead.

## Core Capabilities

- **Intelligent API Polling:** The `autoscaler.sh` brain directly talks to `https://api.github.com/rate_limit` and `/actions/runners` to perfectly track the cluster's active capacity natively.
- **Zero-Downtime Hot Reloading:** Control bounds (`MAX_RUNNERS`, etc.) are read natively from a `.properties` file every 15 seconds. You can scale your runner fleet up or down live without interrupting jobs in flight.
- **Dynamic Binary Generation:** Detects native OS (`Darwin/Linux`) and architecture (`x64/arm64`) to automatically retrieve the exact pristine GitHub payload natively and spawn worker directories seamlessly.
- **Purely Ephemeral:** Guaranteeing clean environments, every worker loop utilizes GitHub's `--ephemeral` flag to absolutely annihilate state leakage between consecutive PR test runs.

## System Configuration (The Bare-Metal Tradeoff)

Because these workers execute directly on the host machine OS instead of inside isolated Docker containers, **your host machine MUST be pre-configured with the toolchains your repositories require**. The actions will natively inherit the `$PATH` and packages of the user running `autoscaler.sh`.

### Provisioning the Host Machine

Before throwing CI/CD jobs at this coordinator, ensure you have natively installed the runtimes needed for your specific repositories globally. We highly recommend using resilient version managers so standard actions (like `actions/setup-node`) can switch environments cleanly without fighting permissions:

1. **Node.js**: Install [`nvm`](https://github.com/nvm-sh/nvm) (Node Version Manager) into the runner user's local `~/.nvm` to allow javascript engines to transition dynamically.
2. **Java**: Install `openjdk` via `brew install openjdk` locally, or use [`SDKMAN!`](https://sdkman.io/) for fluid JDK switching inside workflow files.
3. **Rust**: Install [`rustup`](https://rustup.rs/) strictly under the executing user's profile to prevent compiler namespace mismatches (`cc` linker errors).
4. **C/C++ Build Tools**: Ensure `gcc`, `make`, and a native linker `cc` are available (`xcode-select --install` on macOS or `sudo apt install build-essential` on Ubuntu).
5. **Docker (macOS specifics):** If your workflows require `docker build` or Dockerized service containers, install Docker Desktop or [OrbStack](https://orbstack.dev/) natively, and ensure the docker daemon socket is properly bound to the shell's active `$PATH`.

## Quick Start Guide

### 1. Supply your API Token
You must export a highly-scoped Personal Access Token (PAT) so the core daemon can dynamically request one-time runner registration keys and monitor `/actions/runners`. 

**Required PAT Scopes:**
- **Classic PAT**: Must have the `admin:org` scope to manage organization-level runners.
- **Fine-Grained PAT**: Must grant **Read and Write** access to the Organization's **Self-hosted runners** permission.

```bash
export GH_RUNNER_PAT="github_pat_XXXXX..."
```

### 2. Tune your Hardware Capacities
Open `scaler.properties` and optimize the maximum compute limit for your specific hardware.
```properties
MAX_RUNNERS=5
MIN_IDLE=1
POLL_INTERVAL=15
```
*(You can modify this file dynamically while the system is actively running!)*

### 3. Ignition
Launch the autoscaler logic into the background. The script will dynamically download the needed tarballs if absent and build your initial fleet.
```bash
./start.sh
```

### 4. Stopping & Cleanup
Need to freeze the hardware or reboot? Use the `stop.sh` utility to securely execute a graceful `pkill` across the entire fleet and wipe any orphaned config states.
```bash
./stop.sh
```

## Monitoring the Brain

Watch the intelligence daemon dynamically make API polling decisions across the fleet live:
```bash
tail -f autoscaler.log
```
