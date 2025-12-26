# HetrixTools Server Monitoring Agent - Technical Specification

**Version**: 2.3.8  
**Last Updated**: 2025-12-26  
**Status**: Production

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Feature Points](#feature-points)
4. [Implementation Details](#implementation-details)
5. [Data Collection Workflow](#data-collection-workflow)
6. [Installation & Deployment](#installation--deployment)
7. [Configuration](#configuration)
8. [Data Format & API](#data-format--api)
9. [Security Considerations](#security-considerations)
10. [Extension Points](#extension-points)

---

## Overview

### Purpose

The HetrixTools Server Monitoring Agent is a lightweight, shell-based system monitoring solution designed to collect comprehensive server metrics and transmit them to the HetrixTools platform for analysis and alerting.

### Key Characteristics

- **Language**: Pure Bash shell script
- **Dependencies**: Minimal (wget, standard Linux utilities)
- **Deployment**: Single script with external configuration
- **Execution Model**: Cron/systemd scheduled (every minute)
- **Data Transmission**: HTTPS POST to HetrixTools API
- **Operating Systems**: Linux-based systems (Debian, Ubuntu, CentOS, RHEL, CloudLinux, etc.)

### Design Philosophy

1. **Minimal footprint**: No compiled binaries, minimal resource usage
2. **Self-contained**: All logic in a single executable script
3. **Configurable**: External configuration file for customization
4. **Resilient**: Handles errors gracefully, self-healing for hung processes
5. **Extensible**: Support for custom variables and plugins

---

## Architecture

### System Components

```
┌─────────────────────────────────────────────────────────────┐
│                    HetrixTools Platform                     │
│                   (sm.hetrixtools.net)                      │
└────────────────────────────┬────────────────────────────────┘
                             │ HTTPS POST (gzipped JSON)
                             │
┌────────────────────────────┴────────────────────────────────┐
│                   hetrixtools_agent.sh                      │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Main Control Loop (runs every minute)              │  │
│  ├──────────────────────────────────────────────────────┤  │
│  │  1. Process Management (kill hung instances)        │  │
│  │  2. Initialize Collectors                           │  │
│  │  3. Data Sampling Loop (configurable frequency)     │  │
│  │  4. Data Aggregation                                │  │
│  │  5. JSON Payload Construction                       │  │
│  │  6. Compression & Encoding                          │  │
│  │  7. HTTPS Transmission                              │  │
│  └──────────────────────────────────────────────────────┘  │
│                             │                               │
│  ┌──────────────────────────┴───────────────────────────┐  │
│  │         Configuration (hetrixtools.cfg)              │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                             │
         ┌───────────────────┴───────────────────┐
         │                                       │
┌────────┴─────────┐                   ┌────────┴─────────┐
│  System Metrics  │                   │  Health Checks   │
├──────────────────┤                   ├──────────────────┤
│ • CPU stats      │                   │ • RAID status    │
│ • Memory usage   │                   │ • Drive health   │
│ • Disk I/O       │                   │ • Service status │
│ • Network I/O    │                   │ • ZFS pools      │
│ • Load average   │                   │ • Temperature    │
│ • Uptime         │                   │ • Connections    │
└──────────────────┘                   └──────────────────┘
```

### File Structure

```
/etc/hetrixtools/
├── hetrixtools_agent.sh      # Main agent script
├── hetrixtools.cfg            # Configuration file
├── custom_variables.json      # Optional custom metrics
├── hetrixtools_agent.log      # Last POST data
├── hetrixtools_cron.log       # Execution logs (cron mode)
├── debug.log                  # Debug output (if enabled)
├── ping.txt                   # Temporary ping results
└── running_proc.txt           # Previous process snapshot
```

### Execution Models

#### 1. Cron-based Scheduling

```cron
* * * * * bash /etc/hetrixtools/hetrixtools_agent.sh >> /etc/hetrixtools/hetrixtools_cron.log 2>&1
```

- Runs every minute via crontab
- User: `root` or `hetrixtools` (configurable)
- Output logged to `hetrixtools_cron.log`

#### 2. Systemd-based Scheduling

**Service Unit** (`hetrixtools_agent.service`):
```ini
[Unit]
Description=HetrixTools Agent

[Service]
Type=oneshot
User=root|hetrixtools
ExecStart=/bin/bash /etc/hetrixtools/hetrixtools_agent.sh
```

**Timer Unit** (`hetrixtools_agent.timer`):
```ini
[Unit]
Description=Runs HetrixTools agent every minute

[Timer]
OnBootSec=1min
OnCalendar=*-*-* *:*:00 UTC
AccuracySec=1s
RandomizedDelaySec=0
Persistent=true
Unit=hetrixtools_agent.service

[Install]
WantedBy=timers.target
```

---

## Feature Points

### 1. System Metrics Collection

#### CPU Metrics
- **Usage percentage**: Overall CPU utilization
- **I/O Wait**: Time waiting for I/O operations
- **Steal Time**: Time stolen by hypervisor (virtualized environments)
- **User Time**: CPU time in user space
- **System Time**: CPU time in kernel space
- **Clock Speed**: Current CPU frequency (MHz)
- **Load Average**: 1-min, 5-min, 15-min load averages
- **Model Information**: CPU model, sockets, cores, threads

**Collection Method**: `vmstat`, `/proc/cpuinfo`, `/proc/loadavg`, `lscpu`

#### Memory Metrics
- **RAM Usage**: Active memory utilization percentage
- **Swap Usage**: Swap space utilization percentage
- **Buffer Usage**: Buffer cache percentage
- **Cache Usage**: Page cache percentage
- **Total RAM**: Total installed memory (KB)
- **Total Swap**: Total swap space (KB)

**Collection Method**: `vmstat`, `/proc/meminfo`

#### Disk Metrics
- **Usage**: Space used per filesystem (bytes)
- **Inode Usage**: Inode utilization per filesystem
- **I/O Operations**: Read/write bytes per second
- **Mount Points**: All mounted filesystems
- **Filesystem Types**: ext4, xfs, btrfs, zfs, etc.
- **Thin LVM Pools**: Detection and monitoring of thin-provisioned volumes

**Collection Method**: `df`, `lsblk`, `/proc/diskstats`, `lvs`, `pvs`

#### Network Metrics
- **Traffic**: Received/transmitted bytes per second
- **Interface Stats**: Per-interface statistics
- **IP Addresses**: IPv4 and IPv6 addresses per interface
- **Port Connections**: Active connections per port
- **Auto-detection**: Automatic network interface discovery

**Collection Method**: `/proc/net/dev`, `ip`, `ss`, `netstat`

### 2. Health Monitoring

#### Software RAID (mdadm)
- **Status**: Health state of each RAID array
- **Configuration**: RAID level, member disks
- **Degradation**: Detection of degraded arrays
- **Thin LVM Integration**: Detection of RAID under thin LVM pools

**Collection Method**: `/proc/mdstat`, `mdadm -D`

#### ZFS Pools
- **Health Status**: Pool state (online, degraded, faulted)
- **Capacity**: Used/available space
- **I/O Statistics**: Read/write operations
- **Integration**: Automatic detection and monitoring

**Collection Method**: `zpool status`, `zpool iostat`, `zfs get`

#### Drive Health (S.M.A.R.T.)
- **HDD/SSD Health**: S.M.A.R.T. attributes and overall health
- **NVMe Health**: NVMe-specific health metrics
- **RAID Controllers**: Support for MegaRAID, HP Smart Array
- **Drive Information**: Model, serial number, firmware

**Collection Method**: `smartctl`, `nvme smart-log`

#### Temperature Monitoring
- **Thermal Zones**: System thermal sensor readings
- **Sensors Command**: lm-sensors output parsing
- **IPMI**: BMC temperature readings via ipmitool
- **Multiple Sources**: Aggregated from all available sources

**Collection Method**: `/sys/class/thermal`, `sensors`, `ipmitool`

### 3. Service Monitoring

- **Process Check**: Detection via `ps` command
- **Systemd Status**: Service state via `systemctl`
- **Service Command**: Fallback via `service` command
- **Multiple Services**: Up to 10 services configurable
- **Status Reporting**: Binary up/down status

### 4. Outgoing Network Testing

- **ICMP Ping**: Outgoing ping tests to configurable targets
- **Packet Loss**: Percentage of lost packets
- **RTT Metrics**: Average round-trip time
- **Multiple Targets**: Up to 10 targets
- **Parallel Execution**: Non-blocking background execution

**Configuration Format**: `TargetName,TargetIP|TargetName2,TargetIP2`

### 5. Process Monitoring

- **Running Processes**: Complete process list with:
  - PID, PPID, UID
  - User name
  - CPU percentage
  - Memory percentage
  - CPU time
  - Elapsed time
  - Command name and full command line
- **Snapshot Comparison**: Current vs. previous snapshot
- **Efficient Encoding**: Base64-encoded process data

### 6. Custom Variables

- **JSON Format**: User-defined metrics in JSON file
- **Flexible Schema**: Any custom key-value pairs
- **Use Cases**: Application metrics, custom checks, business KPIs

### 7. Debug Mode

- **Detailed Logging**: Comprehensive debug output
- **Timestamped Entries**: Per-operation timing
- **Automatic Cleanup**: Daily log rotation at midnight
- **Troubleshooting**: Aid in diagnosing agent issues

---

## Implementation Details

### Language and Tools

**Primary Language**: Bash (v4.0+)

**Required Utilities**:
- `wget`: HTTP/HTTPS data transmission
- `bash`: Shell interpreter
- `awk`: Text processing
- `grep`: Pattern matching
- `sed`: Stream editing
- `base64`: Data encoding
- `gzip`: Data compression
- `vmstat`: Virtual memory statistics
- `df`: Disk filesystem information
- `lsblk`: Block device information

**Optional Utilities** (for extended features):
- `smartctl`: Drive health monitoring
- `nvme`: NVMe drive monitoring
- `mdadm`: Software RAID monitoring
- `zpool`/`zfs`: ZFS monitoring
- `lvs`/`pvs`: LVM monitoring
- `sensors`: Temperature monitoring
- `ipmitool`: IPMI temperature monitoring
- `ss`/`netstat`: Network statistics

### Data Collection Loop

#### Initialization Phase (Once per minute)

1. **Load Configuration**: Read `hetrixtools.cfg`
2. **Process Cleanup**: Kill hung agent processes (if >50 or >90s old)
3. **Initialize Counters**: Set up data aggregation variables
4. **Network Interface Detection**: Auto-detect or use configured interfaces
5. **Initial Network Stats**: Baseline for traffic calculation
6. **Port Detection**: Auto-detect listening ports if not configured
7. **Disk Device Mapping**: Map mount points to block devices
8. **ZFS Pool Setup**: Initialize ZFS iostat monitoring (if applicable)

#### Sampling Loop (Multiple iterations per minute)

**Configuration**: `CollectEveryXSeconds` (default: 3 seconds)  
**Iterations**: `RunTimes = 60 / CollectEveryXSeconds` (default: 20)

**Per-Sample Operations**:
1. **CPU Metrics**: `vmstat` for CPU%, IO wait, steal time
2. **Load Average**: Read `/proc/loadavg`
3. **Memory Metrics**: Extract from vmstat output
4. **Network Traffic**: Calculate delta from `/proc/net/dev`
5. **Port Connections**: Count connections per port
6. **Temperature**: Read thermal zones and sensors
7. **Minute Boundary Check**: Exit loop if minute changes

**Aggregation**: Sum all samples for averaging

#### Finalization Phase (Once per minute)

1. **Temperature Collection**: IPMI sensors (slow, run once)
2. **Average Calculation**: Divide accumulated values by sample count
3. **System Information**: OS, kernel, hostname, uptime
4. **CPU Details**: Model, sockets, cores, threads, speed
5. **Disk Operations**: Final IOPS calculation
6. **ZFS IOPS**: Read from background iostat processes
7. **RAID Status**: Query mdadm and zpool (if enabled)
8. **Drive Health**: S.M.A.R.T. and NVMe checks (if enabled)
9. **Service Status**: Check configured services
10. **Process Snapshot**: Capture running processes (if enabled)
11. **Custom Variables**: Read custom JSON file (if exists)
12. **Ping Results**: Collect outgoing ping test results

### Data Processing

#### Encoding Pipeline

```
Raw Data → JSON Construction → gzip Compression → Base64 Encoding → URL Encoding
```

**Example**:
```json
{
  "version": "2.3.8",
  "SID": "abc123...",
  "cpu": "15.3",
  "ram": "45.2",
  ...
}
```
↓ gzip ↓
```
[binary gzipped data]
```
↓ base64 ↓
```
H4sIAAAAAAAAA...
```
↓ URL encode ↓
```
j=H4sIAAAAAAAAA...
```

#### Transmission

```bash
wget --retry-connrefused --waitretry=1 -t 3 -T 15 \
  -qO- --post-file="$ScriptPath/hetrixtools_agent.log" \
  https://sm.hetrixtools.net/v2/
```

**Parameters**:
- `--retry-connrefused`: Retry on connection refused
- `--waitretry=1`: Wait 1 second between retries
- `-t 3`: Maximum 3 attempts
- `-T 15`: 15-second timeout
- `--post-file`: POST from file
- Optional: `--no-check-certificate` (if `SecuredConnection=0`)

### Self-Healing Mechanisms

#### Process Management

**Problem**: Agent processes may hang or accumulate  
**Solution**: Kill lingering processes before each run

```bash
# Kill all if >= 50 processes
if [ "$HTProcesses" -ge 50 ]; then
  pgrep -f hetrixtools_agent.sh | xargs -r kill -9
fi

# Kill processes running >= 90 seconds
if [ "$HTProcesses" -ge 10 ]; then
  for PID in $(pgrep -f hetrixtools_agent.sh); do
    if [ "$PID_TIME" -ge 90 ]; then
      kill -9 "$PID"
    fi
  done
fi
```

#### Timeout Protection

**Problem**: Commands may hang indefinitely  
**Solution**: Apply timeouts to potentially blocking operations

```bash
df_mount_output=$(timeout 3 df 2>/dev/null)
IPMIArray=$(timeout -s 9 5 ipmitool sdr type Temperature)
needs-restarting -r | grep -q 'Reboot is required' (with timeout)
```

#### Log Rotation

**Problem**: Debug/cron logs may grow unbounded  
**Solution**: Automatic daily cleanup

```bash
# Clear debug.log at midnight
if [ -z "$(date +%H)" ] && [ -z "$(date +%M)" ]; then
  rm -f "$ScriptPath"/debug.log
fi

# Clear hetrixtools_cron.log every hour (at minute 0)
if [ "$M" -eq 0 ]; then
  rm -f "$ScriptPath"/hetrixtools_cron.log
fi
```

### Parallel Execution

#### Outgoing Ping Tests

**Implementation**: Background processes for non-blocking execution

```bash
for i in "${OutgoingPingsArray[@]}"; do
  bash "$ScriptPath"/hetrixtools_agent.sh ping "${OutgoingPing[0]}" "${OutgoingPing[1]}" &
done
```

**Result Collection**: Read from shared `ping.txt` file at end

#### ZFS Pool Monitoring

**Challenge**: `zpool iostat` requires time-based sampling  
**Solution**: Background processes with named pipes

```bash
# Start iostat in background for each pool
for pool in "${zpoolsray[@]}"; do
  pipe=$(mktemp -u)
  mkfifo "$pipe"
  timeout 60 zpool iostat -v -p "$pool" "$remaining_seconds" 2 > "$pipe" &
  pids[$pool]=$!
  pipes[$pool]="$pipe"
done

# Later, read from pipes
for pool in "${zpoolsray[@]}"; do
  zpooloutput=$(<"${pipes[$pool]}")
  kill "${pids[$pool]}"
  rm "${pipes[$pool]}"
done
```

---

## Data Collection Workflow

### Minute-by-Minute Execution Flow

```
┌─────────────────────────────────────────────────────────────┐
│ Minute Start (00 seconds)                                   │
└────┬────────────────────────────────────────────────────────┘
     │
     ├─> Load Configuration (hetrixtools.cfg)
     │
     ├─> Process Management
     │   └─> Kill hung/excessive processes
     │
     ├─> Initialize Data Structures
     │   ├─> Network interface arrays
     │   ├─> Disk device mappings
     │   ├─> Temperature arrays
     │   └─> Connection counters
     │
     ├─> Baseline Measurements
     │   ├─> Initial network stats (/proc/net/dev)
     │   ├─> Initial disk stats (/proc/diskstats)
     │   └─> Auto-detect ports (if not configured)
     │
     ├─> Start Background Tasks
     │   ├─> Outgoing ping tests (parallel)
     │   └─> ZFS iostat monitoring (if applicable)
     │
     ├─> ╔═══════════════════════════════════════════════╗
     │   ║  Sampling Loop (multiple iterations)         ║
     │   ║  Runs every CollectEveryXSeconds (default: 3)║
     │   ╚═══════════════════════════════════════════════╝
     │   │
     │   ├─> Sample 1 (03s) ──┐
     │   ├─> Sample 2 (06s)   │
     │   ├─> Sample 3 (09s)   │  Accumulate:
     │   ├─> ...              │  • CPU metrics
     │   ├─> Sample N (57s)   │  • Memory metrics
     │   │                    │  • Network deltas
     │   │                    │  • Temperature readings
     │   └─> Break on minute  │  • Port connections
     │       boundary ─────────┘
     │
     ├─> One-Time Expensive Operations
     │   ├─> IPMI temperature (slow)
     │   ├─> System info (OS, kernel, uptime)
     │   └─> CPU details (model, cores, threads)
     │
     ├─> Calculate Averages
     │   └─> Divide accumulated values by sample count
     │
     ├─> Health Checks (if enabled)
     │   ├─> RAID status (mdadm, zpool)
     │   ├─> Drive health (smartctl, nvme)
     │   └─> Service status (systemctl, ps)
     │
     ├─> Finalize Metrics
     │   ├─> Disk IOPS calculation
     │   ├─> ZFS IOPS from background processes
     │   ├─> Network IP addresses
     │   ├─> Port connection averages
     │   └─> Process snapshot (if enabled)
     │
     ├─> Custom Data
     │   ├─> Read custom_variables.json
     │   └─> Collect ping test results
     │
     ├─> Data Preparation
     │   ├─> Construct JSON payload
     │   ├─> gzip compression
     │   ├─> Base64 encoding
     │   └─> URL encoding
     │
     ├─> Transmission
     │   └─> HTTPS POST to sm.hetrixtools.net/v2/
     │
     └─> Cleanup & Exit
         ├─> Save running_proc.txt
         └─> Exit (wait for next minute)

┌─────────────────────────────────────────────────────────────┐
│ Next Minute Start                                           │
└─────────────────────────────────────────────────────────────┘
```

### Timing Considerations

**Target**: Complete all operations within 60 seconds

**Time Budget Breakdown**:
- **Initialization**: ~1-2 seconds
- **Sampling Loop**: ~45-55 seconds (controlled by minute boundary)
- **Finalization**: ~5-10 seconds
- **Transmission**: ~1-3 seconds

**Optimization Strategies**:
1. **Sample count adapts**: If operations are slow, fewer samples are collected
2. **Minute boundary check**: Loop exits when minute changes
3. **Timeouts**: Prevent hanging on slow operations
4. **Parallel execution**: Background tasks don't block main loop

---

## Installation & Deployment

### Installation Process

#### Prerequisites Check

```bash
# Root privileges required
if [ "$EUID" -ne 0 ]; then
  echo "ERROR: Please run the install script as root."
  exit 1
fi

# wget required
command -v wget >/dev/null 2>&1 || {
  echo "ERROR: wget is required to run this agent."
  exit 1
}

# Scheduler required (cron or systemd)
# (detection logic in script)
```

#### Installation Steps

1. **Download Installation Script**:
   ```bash
   wget https://raw.githubusercontent.com/hetrixtools/agent/master/hetrixtools_install.sh
   ```

2. **Execute Installer**:
   ```bash
   bash hetrixtools_install.sh [branch] <SID> <run_as_root> [services] [raid] [drive_health] [processes] [ports]
   ```

   **Parameters**:
   - `branch` (optional): Git branch (default: master)
   - `SID` (required): 32-character Server ID from HetrixTools
   - `run_as_root` (required): 1 = root, 0 = hetrixtools user
   - `services` (optional): Comma-separated service names or "0"
   - `raid` (optional): 1 = enable, 0 = disable
   - `drive_health` (optional): 1 = enable, 0 = disable
   - `processes` (optional): 1 = enable, 0 = disable
   - `ports` (optional): Comma-separated ports or "0"

3. **Installation Actions**:
   ```
   Remove old installation → Create /etc/hetrixtools/ → 
   Download agent script → Download config → 
   Configure SID → Apply settings → 
   Create hetrixtools user → Set permissions → 
   Setup scheduler (cron or systemd) → 
   Start agent → Notify HetrixTools platform
   ```

#### User Account Setup

**hetrixtools User**:
- **Type**: System user (`useradd -r`)
- **Home**: `/etc/hetrixtools`
- **Shell**: `/bin/false` (no login)
- **Purpose**: Security isolation, limited privileges

**Permissions**:
```bash
chown -R hetrixtools:hetrixtools /etc/hetrixtools
chmod -R 700 /etc/hetrixtools
```

### Update Process

#### Update Script

```bash
bash hetrixtools_update.sh [branch]
```

**Actions**:
1. Detect existing installation
2. Extract current configuration
3. Download new agent and config
4. Restore configuration settings
5. Refresh scheduler configuration
6. Cleanup and restart

**Configuration Preservation**:
- Server ID (SID)
- Network interfaces
- Service monitoring
- RAID monitoring
- Drive health monitoring
- Process monitoring
- Port monitoring
- Custom variables
- Connection security
- Collection frequency
- Outgoing pings

### Uninstallation Process

```bash
bash hetrixtools_uninstall.sh [SID]
```

**Actions**:
1. Remove `/etc/hetrixtools/` directory
2. Kill running agent processes
3. Delete hetrixtools user
4. Remove systemd service/timer
5. Remove cron jobs
6. Notify HetrixTools platform
7. Self-cleanup

---

## Configuration

### Configuration File: `hetrixtools.cfg`

#### Server Identification

```bash
# Server ID - automatically assigned on installation
# DO NOT share this ID with anyone
SID=""
```
- **Type**: 32-character alphanumeric string
- **Purpose**: Unique identifier for this server
- **Security**: Treat as secret credential

#### Network Configuration

```bash
# Network Interfaces
# * if empty: auto-detect all active interfaces
# * single interface: "eth1"
# * multiple interfaces: "eth0,eth1,eth2"
NetworkInterfaces=""
```
- **Default**: Auto-detect
- **Format**: Comma-separated interface names
- **Detection**: Interfaces in "state UP" with BROADCAST

#### Service Monitoring

```bash
# Check Services
# * comma-separated service names
# * maximum 10 services
# * example: "ssh,mysql,apache2,nginx"
CheckServices=""
```
- **Limit**: 10 services
- **Method**: Process check → systemctl → service command
- **Format**: Service names as recognized by system

#### RAID Monitoring

```bash
# Check Software RAID Health
# * 0 - OFF (default) | 1 - ON
# * requires root/privileged user
CheckSoftRAID=0
```
- **Supported**: mdadm software RAID, ZFS pools
- **Requirements**: Root privileges
- **Detection**: Automatic discovery of arrays

#### Drive Health Monitoring

```bash
# Check Drive Health
# * 0 - OFF (default) | 1 - ON
# * requires 'smartctl' for HDD/SSD or 'nvme-cli' for NVMe
# * requires root/privileged user
CheckDriveHealth=0
```
- **Tools**: `smartctl` (S.M.A.R.T.), `nvme` (NVMe)
- **Controllers**: MegaRAID, HP Smart Array support
- **Requirements**: Root privileges

#### Process Monitoring

```bash
# View Running Processes
# * 0 - OFF (default) | 1 - ON
RunningProcesses=0
```
- **Data**: PID, user, CPU%, memory%, command
- **Method**: `ps` command snapshot
- **Storage**: Compared with previous snapshot

#### Port Monitoring

```bash
# Port Connections
# * if empty: auto-detect active listening ports
# * manual: "80,443,3306"
ConnectionPorts=""
```
- **Default**: Auto-detect (up to 30 ports)
- **Format**: Comma-separated port numbers
- **Metric**: Active connection count per port

#### Custom Variables

```bash
# Custom Variables
# * JSON file with custom metrics
CustomVars="custom_variables.json"
```
- **Format**: JSON file
- **Location**: Same directory as agent
- **Schema**: Flexible, user-defined

#### Connection Security

```bash
# Secured Connection
# * 0 - OFF | 1 - ON (default)
# * disable only for old servers with SSL issues
SecuredConnection=1
```
- **Default**: Enabled (SSL verification)
- **Disable**: Only for old systems with SSL problems
- **Impact**: `--no-check-certificate` flag

#### Collection Frequency

```bash
# How frequently should data samples be collected
# * recommended: 2-10 seconds
# * lower = more accurate, higher CPU usage
# * higher = less accurate, lower CPU usage
CollectEveryXSeconds=3
```
- **Default**: 3 seconds
- **Range**: 2-10 seconds recommended
- **Impact**: Number of samples = 60 / CollectEveryXSeconds

#### Debug Mode

```bash
# DEBUG Mode
# * 0 - OFF (default) | 1 - ON
# * outputs to /etc/hetrixtools/debug.log
# * WARNING: generates large logs
DEBUG=0
```
- **Output**: `/etc/hetrixtools/debug.log`
- **Rotation**: Daily at midnight
- **Use Case**: Troubleshooting agent issues

#### Outgoing Ping Tests

```bash
# Outgoing PING
# * format: "Name1,IP1|Name2,IP2"
# * example: "Google,8.8.8.8|Cloudflare,1.1.1.1"
# * maximum 10 targets
OutgoingPings=""

# Outgoing PING count
# * default: 20 | range: 10-40
OutgoingPingsCount=20
```
- **Limit**: 10 targets
- **Name Format**: Alphanumerics, dots, dashes, underscores
- **Metrics**: Packet loss %, average RTT
- **Execution**: Parallel, non-blocking

---

## Data Format & API

### JSON Payload Structure

```json
{
  "version": "2.3.8",
  "SID": "abc123...",
  "agent": "0",
  "user": "hetrixtools",
  "os": "VWJ1bnR1IDIwLjA0...",
  "kernel": "NS40LjAtNDgtZ2VuZXJpYw==",
  "hostname": "c2VydmVyMS5leGFtcGxlLmNvbQ==",
  "time": "MjAyMy0xMi0yNiAxMjozNDo1NiBVVEM=",
  "reqreboot": "0",
  "uptime": "864000",
  "cpumodel": "SW50ZWwgWGVvbiBFNS0yNjcwIEAgMi42MEdo...",
  "cpusockets": "1",
  "cpucores": "4",
  "cputhreads": "1",
  "cpuspeed": "2600",
  "cpu": "23.45",
  "wa": "1.23",
  "st": "0.00",
  "us": "15.32",
  "sy": "8.13",
  "load1": "0.45",
  "load5": "0.52",
  "load15": "0.48",
  "ramsize": "8388608",
  "ram": "42.35",
  "ramswapsize": "2097152",
  "ramswap": "5.23",
  "rambuff": "3.45",
  "ramcache": "25.67",
  "disks": "Lyx0bXA...",
  "inodes": "Lyx0bXA...",
  "iops": "Lyx0bXA...",
  "raid": "Lyx0bXA...",
  "zp": "Lyx0bXA...",
  "dh": "Lyx0bXA...",
  "nics": "ZXRoMCwxMjM0NTY3ODkwLDk4NzY1NDMyMTA7...",
  "ipv4": "ZXRoMCwxOTIuMTY4LjEuMTAwOw==",
  "ipv6": "ZXRoMCwyMDAxOmRiODo6MTs=",
  "conn": "ODAsNTA7NDQzLDEyMzs=",
  "temp": "QWxsQ29yZUF2Zyw0NTAwMDs=",
  "serv": "c3NoLDE7bmdpbngsMTs=",
  "cust": "eyJjdXN0b21fbWV0cmljIjogMTIzfQ==",
  "oping": "R29vZ2xlLDguOC44LjgsMCw1MDs=",
  "rps1": "...",
  "rps2": "..."
}
```

### Field Descriptions

#### System Information
- `version`: Agent version
- `SID`: Server ID (unique identifier)
- `agent`: Agent type (0 = standard)
- `user`: User running the agent
- `os`: Base64-encoded OS name
- `kernel`: Base64-encoded kernel version
- `hostname`: Base64-encoded hostname
- `time`: Base64-encoded current timestamp
- `reqreboot`: Reboot required flag (0/1)
- `uptime`: Server uptime in seconds

#### CPU Metrics
- `cpumodel`: Base64-encoded CPU model
- `cpusockets`: Number of physical CPUs
- `cpucores`: Number of CPU cores
- `cputhreads`: Threads per core
- `cpuspeed`: CPU speed in MHz
- `cpu`: CPU usage percentage (average)
- `wa`: I/O wait percentage
- `st`: Steal time percentage
- `us`: User time percentage
- `sy`: System time percentage
- `load1`, `load5`, `load15`: Load averages

#### Memory Metrics
- `ramsize`: Total RAM in KB
- `ram`: RAM usage percentage
- `ramswapsize`: Total swap in KB
- `ramswap`: Swap usage percentage
- `rambuff`: Buffer usage percentage
- `ramcache`: Cache usage percentage

#### Disk Metrics (Base64-encoded)
- `disks`: Mount point, type, total, used, available (semicolon-separated)
- `inodes`: Mount point, type, total, used (semicolon-separated)
- `iops`: Mount point, read bytes/s, write bytes/s (semicolon-separated)

#### RAID Metrics (Base64-encoded)
- `raid`: Mount point, device, mdadm output (semicolon-separated)
- `zp`: Mount point, pool name, zpool status (semicolon-separated)

#### Drive Health (Base64-encoded)
- `dh`: Type (1=SMART, 2=NVMe), device, health data, model, serial (semicolon-separated)

#### Network Metrics (Base64-encoded)
- `nics`: Interface, RX bytes/s, TX bytes/s (semicolon-separated)
- `ipv4`: Interface, IPv4 addresses (comma-separated)
- `ipv6`: Interface, IPv6 addresses (comma-separated)
- `conn`: Port, connection count (semicolon-separated)

#### Temperature (Base64-encoded)
- `temp`: Sensor name, temperature in millidegrees (semicolon-separated)

#### Services (Base64-encoded)
- `serv`: Service name, status (0/1) (semicolon-separated)

#### Custom & Additional (Base64-encoded)
- `cust`: Custom variables JSON
- `oping`: Target name, IP, packet loss %, RTT microseconds (semicolon-separated)
- `rps1`: Previous process snapshot (base64)
- `rps2`: Current process snapshot (base64)

### Encoding Details

#### Base64-Encoded Fields

Most complex fields are base64-encoded after construction:

```bash
# Example: Disk usage
DISKs="$DISKs$mount_point,$filesystem_type,$total_size,$used_size,$available_size;"
DISKs=$(echo -ne "$DISKs" | base64 | tr -d '\n\r\t ')
```

Decoded format (semicolon-separated records):
```
/,ext4,100000000000,50000000000,50000000000;/home,ext4,200000000000,100000000000,100000000000;
```

#### Compression & URL Encoding

```bash
# Construct JSON
json='{"version":"'$Version'","SID":"'$SID'",...}'

# Compress and encode
jsoncomp=$(echo -ne "$json" | gzip -cf | base64 -w 0 | sed 's/ //g' | sed 's/\//%2F/g' | sed 's/+/%2B/g')

# Save to file
echo "j=$jsoncomp" > "$ScriptPath"/hetrixtools_agent.log
```

### API Endpoint

**URL**: `https://sm.hetrixtools.net/v2/`

**Method**: POST

**Content-Type**: `application/x-www-form-urlencoded`

**Payload**: `j=<compressed_base64_json>`

**Response**: Expected to be empty or acknowledgment

**Retry Logic**:
- Retry on connection refused
- Wait 1 second between retries
- Maximum 3 attempts
- 15-second timeout per attempt

---

## Security Considerations

### Authentication & Authorization

1. **Server ID (SID)**:
   - 32-character unique identifier
   - Acts as API key for server authentication
   - Must be kept confidential
   - Generated by HetrixTools platform

2. **User Isolation**:
   - Option to run as dedicated `hetrixtools` user
   - Limited privileges (no login shell)
   - Home directory: `/etc/hetrixtools` (700 permissions)

3. **Root Requirements**:
   - Some features require root:
     - RAID monitoring (mdadm access)
     - Drive health (smartctl, nvme)
     - Low-level disk operations
   - Trade-off: Functionality vs. security isolation

### Data Transmission Security

1. **HTTPS Encryption**:
   - All data transmitted over TLS/SSL
   - Default: SSL certificate verification enabled
   - Option to disable for legacy systems

2. **Data Compression**:
   - gzip compression reduces data size
   - Side benefit: Obscures plain text from casual inspection

3. **No Sensitive Data**:
   - No passwords or credentials collected
   - System metrics only
   - User-defined custom variables (user responsibility)

### Input Validation

1. **Configuration Validation**:
   ```bash
   # Validate ping target name (alphanumerics, dots, dashes, underscores)
   if ! [[ "$TargetName" =~ ^[A-Za-z0-9._-]+$ ]]; then
     exit 1
   fi
   
   # Validate ping target (alphanumerics, colons, dots, dashes, underscores)
   if ! [[ "$PingTarget" =~ ^[A-Za-z0-9.:_-]+$ ]]; then
     exit 1
   fi
   
   # Validate ping count (10-40)
   if ! [[ "$OutgoingPingsCount" =~ ^[0-9]+$ ]] || (( OutgoingPingsCount < 10 || OutgoingPingsCount > 40 )); then
     exit 1
   fi
   ```

2. **Command Injection Prevention**:
   - Variables used in commands are validated
   - Use of `grep -w` for exact matches
   - Quoted variables to prevent word splitting

### File System Security

1. **Permission Model**:
   ```
   /etc/hetrixtools/           drwx------  hetrixtools:hetrixtools
   ├── hetrixtools_agent.sh    -rwx------
   ├── hetrixtools.cfg         -rw-------
   ├── custom_variables.json   -rw-------
   └── *.log                   -rw-------
   ```

2. **Temporary Files**:
   - Minimal use of temp files
   - Created in agent directory with restricted permissions
   - Cleaned up after use

3. **Log Files**:
   - Automatic rotation/cleanup
   - Limited size (debug mode generates more)

### Network Security

1. **Outbound Only**:
   - Agent only makes outbound connections
   - No listening ports opened
   - No remote control capability

2. **Single Endpoint**:
   - Connects only to `sm.hetrixtools.net`
   - Hardcoded in script (not configurable)

3. **Firewall Considerations**:
   - Requires outbound HTTPS (443) to HetrixTools
   - Optional: Outbound ICMP for ping tests

### Privilege Management

1. **Principle of Least Privilege**:
   - Run as `hetrixtools` user when possible
   - Escalate to root only for specific features
   - Consider sudo rules for specific commands:
     ```
     hetrixtools ALL=(ALL) NOPASSWD: /sbin/mdadm
     hetrixtools ALL=(ALL) NOPASSWD: /usr/sbin/smartctl
     ```

2. **Feature Gating**:
   - Privileged features default to OFF
   - Explicit opt-in via configuration
   - Documented requirements

### Security Best Practices

1. **Installation**:
   - Verify script source (official GitHub repository)
   - Review script before execution
   - Use HTTPS for downloads

2. **Configuration**:
   - Protect `hetrixtools.cfg` (contains SID)
   - Limit read access to necessary users
   - Regular configuration audits

3. **Monitoring**:
   - Review agent logs for anomalies
   - Monitor agent resource usage
   - Check for unexpected network connections

4. **Updates**:
   - Regular agent updates for security patches
   - Review changelog before updating
   - Test updates in non-production first

---

## Extension Points

### Custom Variables

**Purpose**: Inject custom metrics into monitoring

**Implementation**:
1. Create JSON file: `/etc/hetrixtools/custom_variables.json`
2. Define key-value pairs:
   ```json
   {
     "custom_metric_1": 123,
     "custom_metric_2": "active",
     "application_version": "2.5.0",
     "license_days_remaining": 45
   }
   ```
3. Agent reads and includes in payload

**Use Cases**:
- Application-specific metrics
- Business KPIs
- License/subscription status
- Custom health checks

**Limitations**:
- File must be valid JSON
- Base64-encoded when transmitted
- No complex data structures

### Custom Monitoring Scripts

**Approach**: Write custom scripts that update `custom_variables.json`

**Example**:
```bash
#!/bin/bash
# /etc/hetrixtools/custom_metrics.sh

# Calculate custom metric
ACTIVE_USERS=$(who | wc -l)
DB_CONNECTIONS=$(mysql -e "SHOW STATUS LIKE 'Threads_connected';" | awk 'NR==2 {print $2}')

# Update custom variables
cat > /etc/hetrixtools/custom_variables.json <<EOF
{
  "active_users": $ACTIVE_USERS,
  "db_connections": $DB_CONNECTIONS
}
EOF
```

**Scheduling**: Run before agent execution (e.g., via cron at :59 seconds)

### Integration with External Tools

#### Log Shipping
```bash
# Ship agent logs to centralized logging
if [ "$DEBUG" -eq 1 ]; then
  tail -n 100 /etc/hetrixtools/debug.log | logger -t hetrixtools-agent
fi
```

#### Alerting Integration
```bash
# Check for specific conditions and alert
if [ "$CheckSoftRAID" -gt 0 ]; then
  RAID_STATUS=$(echo "$RAID" | base64 -d)
  if echo "$RAID_STATUS" | grep -qi "degraded"; then
    # Send alert via external system
    curl -X POST https://alerts.example.com/webhook -d "raid_degraded=true"
  fi
fi
```

#### Metrics Export
```bash
# Export metrics to Prometheus pushgateway
cat <<EOF | curl --data-binary @- http://pushgateway:9091/metrics/job/hetrixtools
cpu_usage $CPU
ram_usage $RAM
disk_usage $DISKUsagePercent
EOF
```

### Fork/Modify Considerations

**Modification Points**:
1. **Collection Functions**: Add new metric collectors
2. **Data Format**: Extend JSON schema
3. **Transmission**: Change endpoint or protocol
4. **Scheduling**: Adjust timing or triggers

**Recommended Approach**:
1. Fork repository
2. Modify in separate functions
3. Maintain compatibility with HetrixTools API (if still using platform)
4. Document changes thoroughly
5. Test extensively

**Example: Add Custom Collector**:
```bash
# Add after line 595 (after temperature collection)

# Custom Application Metrics
APP_STATUS=""
if [ "$CheckCustomApp" -gt 0 ]; then
  APP_STATUS=$(curl -s http://localhost:8080/health)
  APP_STATUS=$(echo -ne "$APP_STATUS" | base64 | tr -d '\n\r\t ')
fi

# Add to JSON at line 1298
json='{"version":"'"$Version"'", ... "app":"'"$APP_STATUS"'", ...}'
```

---

## Appendix

### Glossary

- **SID**: Server ID, unique identifier for the monitored server
- **IOPS**: Input/Output Operations Per Second
- **RTT**: Round-Trip Time for network packets
- **mdadm**: Multiple Device Administration (software RAID management)
- **S.M.A.R.T.**: Self-Monitoring, Analysis, and Reporting Technology
- **ZFS**: Zettabyte File System
- **LVM**: Logical Volume Manager
- **IPMI**: Intelligent Platform Management Interface
- **NVMe**: Non-Volatile Memory Express

### Supported Linux Distributions

**Tested**:
- Ubuntu 18.04+
- Debian 9+
- CentOS 7+
- RHEL 7+
- CloudLinux 7+
- Fedora 30+

**Requirements**:
- Bash 4.0+
- Kernel 3.10+
- Systemd or Cron

### Troubleshooting

#### Agent Not Running
1. Check scheduler:
   - Cron: `crontab -u hetrixtools -l` or `crontab -u root -l`
   - Systemd: `systemctl status hetrixtools_agent.timer`
2. Check permissions: `ls -la /etc/hetrixtools/`
3. Enable debug mode: `DEBUG=1` in config
4. Review logs: `tail -f /etc/hetrixtools/debug.log`

#### No Data in Dashboard
1. Verify SID is correct: `grep SID /etc/hetrixtools/hetrixtools.cfg`
2. Check connectivity: `wget -qO- https://sm.hetrixtools.net/`
3. Review last payload: `cat /etc/hetrixtools/hetrixtools_agent.log`
4. Check for SSL issues: Try `SecuredConnection=0`

#### High CPU Usage
1. Increase `CollectEveryXSeconds` (e.g., to 5 or 10)
2. Disable expensive features:
   - `CheckDriveHealth=0`
   - `RunningProcesses=0`
3. Check for hung processes: `ps aux | grep hetrixtools`

#### Missing Metrics
1. Verify feature is enabled in config
2. Check required tools are installed:
   - RAID: `mdadm`, `zpool`
   - Drive Health: `smartctl`, `nvme`
   - Temperature: `sensors`, `ipmitool`
3. Verify user has sufficient privileges
4. Enable debug mode and review output

### Performance Characteristics

**Resource Usage** (typical):
- CPU: <1% average, <5% during collection
- Memory: 10-50 MB
- Disk I/O: Minimal (<1 MB/min)
- Network: ~5-20 KB per minute (compressed)

**Scalability**:
- Single server: Designed for individual server monitoring
- Fleet: Deploy one agent per server
- Overhead: Negligible on modern systems

### References

- **Official Documentation**: https://docs.hetrixtools.com/category/server-monitor/
- **GitHub Repository**: https://github.com/hetrixtools/agent
- **Support**: https://hetrixtools.com (open ticket)

---

## Implementation Checklist

For developers implementing this specification:

### Core Agent
- [ ] Implement configuration loading (`hetrixtools.cfg`)
- [ ] Implement process management (kill hung instances)
- [ ] Implement sampling loop with configurable frequency
- [ ] Implement minute boundary detection
- [ ] Implement data aggregation and averaging
- [ ] Implement JSON payload construction
- [ ] Implement compression and encoding pipeline
- [ ] Implement HTTP transmission with retry logic

### Metric Collectors
- [ ] CPU metrics (usage, I/O wait, steal, user, system)
- [ ] Memory metrics (RAM, swap, buffers, cache)
- [ ] Disk metrics (usage, inodes, IOPS)
- [ ] Network metrics (traffic, IP addresses)
- [ ] Load average
- [ ] System information (OS, kernel, hostname, uptime)

### Health Checks
- [ ] Software RAID monitoring (mdadm)
- [ ] ZFS pool monitoring
- [ ] Drive health (S.M.A.R.T., NVMe)
- [ ] Temperature monitoring (thermal zones, sensors, IPMI)
- [ ] Service status checking
- [ ] Port connection monitoring

### Advanced Features
- [ ] Outgoing ping tests (parallel execution)
- [ ] Process monitoring (snapshot comparison)
- [ ] Custom variables (JSON file reading)
- [ ] Thin LVM pool monitoring
- [ ] RAID controller support (MegaRAID, HP Smart Array)
- [ ] Debug mode with logging

### Installation System
- [ ] Install script with parameter parsing
- [ ] Configuration migration (v1 → v2)
- [ ] User creation and permission setup
- [ ] Scheduler configuration (cron or systemd)
- [ ] Update script with config preservation
- [ ] Uninstall script with cleanup

### Testing
- [ ] Unit tests for metric collectors
- [ ] Integration tests for data transmission
- [ ] Performance tests (resource usage)
- [ ] Compatibility tests (various distributions)
- [ ] Security tests (input validation, privilege escalation)
- [ ] Stress tests (high load scenarios)

---

**Document Version**: 1.0  
**Last Reviewed**: 2025-12-26  
**Next Review**: Upon major version change (3.0.0)

---

This specification provides a complete blueprint for understanding and implementing the HetrixTools Server Monitoring Agent. Developers can use this document to:

1. **Understand** the agent's architecture and design decisions
2. **Implement** new features consistent with existing patterns
3. **Extend** the agent with custom functionality
4. **Maintain** the codebase with full context
5. **Troubleshoot** issues with detailed knowledge of internals
6. **Integrate** with other systems and tools
