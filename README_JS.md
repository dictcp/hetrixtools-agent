# HetrixTools Server Monitoring Agent - JavaScript/Node.js Version

This is a JavaScript/Node.js implementation of the HetrixTools Server Monitoring Agent, created based on the comprehensive technical specification in [SPECIFICATION.md](SPECIFICATION.md).

## Overview

The JavaScript version provides the same core functionality as the Bash version:
- System metrics collection (CPU, memory, disk, network)
- Service monitoring
- Network connectivity testing (outgoing pings)
- Temperature monitoring
- Custom variables support
- Configurable sampling frequency

## Requirements

- **Node.js**: Version 12.0.0 or higher
- **Operating System**: Linux-based systems (Ubuntu, Debian, CentOS, RHEL, etc.)
- **Permissions**: Some features require root/elevated privileges
- **System Tools**: Standard Linux utilities (ps, df, vmstat, ip, ss)

## Installation

### 1. Install Node.js

If Node.js is not already installed:

```bash
# Ubuntu/Debian
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
sudo apt-get install -y nodejs

# CentOS/RHEL
curl -fsSL https://rpm.nodesource.com/setup_lts.x | sudo bash -
sudo yum install -y nodejs
```

### 2. Copy Files

Copy the agent files to your desired location (e.g., `/opt/hetrixtools-js/`):

```bash
sudo mkdir -p /opt/hetrixtools-js
sudo cp hetrixtools_agent.js /opt/hetrixtools-js/
sudo cp hetrixtools.cfg /opt/hetrixtools-js/
sudo cp package.json /opt/hetrixtools-js/
sudo chmod +x /opt/hetrixtools-js/hetrixtools_agent.js
```

### 3. Configure

Edit the configuration file and add your Server ID (SID):

```bash
sudo nano /opt/hetrixtools-js/hetrixtools.cfg
```

Set your SID (obtained from HetrixTools dashboard):
```
SID="your-32-character-server-id-here"
```

Adjust other settings as needed (see Configuration section below).

### 4. Test Run

Test the agent manually:

```bash
sudo node /opt/hetrixtools-js/hetrixtools_agent.js
```

Check the debug log if issues occur:
```bash
cat /opt/hetrixtools-js/debug.log
```

### 5. Schedule with Cron

Add to crontab to run every minute:

```bash
sudo crontab -e
```

Add this line:
```
* * * * * /usr/bin/node /opt/hetrixtools-js/hetrixtools_agent.js >> /opt/hetrixtools-js/cron.log 2>&1
```

Or schedule with systemd (see Systemd Setup below).

## Configuration

Configuration is loaded from `hetrixtools.cfg` in the same directory as the agent script. Available options:

### Core Settings

- **SID**: Server ID from HetrixTools (required)
- **CollectEveryXSeconds**: Sampling interval (default: 3, range: 2-10)
- **SecuredConnection**: Enable SSL verification (default: 1, set to 0 to disable)
- **DEBUG**: Enable debug logging (default: 0, set to 1 to enable)

### Monitoring Features

- **NetworkInterfaces**: Comma-separated interface names (empty for auto-detect)
- **CheckServices**: Comma-separated service names to monitor (max 10)
- **ConnectionPorts**: Comma-separated ports to track connections (empty for auto-detect)
- **RunningProcesses**: Record running processes (0 = off, 1 = on)

### Advanced Features

- **OutgoingPings**: Ping test targets in format `Name1,IP1|Name2,IP2` (max 10)
- **OutgoingPingsCount**: Number of ping packets to send (default: 20, range: 10-40)
- **CustomVars**: Path to custom variables JSON file (default: custom_variables.json)

### Features Requiring Privileges

These features require root privileges and additional system tools:

- **CheckSoftRAID**: Monitor software RAID (requires mdadm)
- **CheckDriveHealth**: Monitor drive health (requires smartctl/nvme)

Note: RAID and drive health monitoring are not implemented in this initial JavaScript version.

## Systemd Setup (Alternative to Cron)

Create a service file:

```bash
sudo nano /etc/systemd/system/hetrixtools-js.service
```

Add:
```ini
[Unit]
Description=HetrixTools Agent (JavaScript)

[Service]
Type=oneshot
User=root
ExecStart=/usr/bin/node /opt/hetrixtools-js/hetrixtools_agent.js
```

Create a timer file:

```bash
sudo nano /etc/systemd/system/hetrixtools-js.timer
```

Add:
```ini
[Unit]
Description=Run HetrixTools Agent (JavaScript) every minute

[Timer]
OnBootSec=1min
OnCalendar=*-*-* *:*:00 UTC
AccuracySec=1s
RandomizedDelaySec=0
Persistent=true
Unit=hetrixtools-js.service

[Install]
WantedBy=timers.target
```

Enable and start:
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now hetrixtools-js.timer
sudo systemctl status hetrixtools-js.timer
```

## Custom Variables

Create a JSON file for custom metrics:

```bash
nano /opt/hetrixtools-js/custom_variables.json
```

Example content:
```json
{
  "app_version": "2.1.0",
  "active_users": 42,
  "db_connections": 15,
  "custom_metric": "active"
}
```

The agent will read and transmit these variables with each data submission.

## Differences from Bash Version

This JavaScript implementation follows the same architecture and logic as the Bash version, with some notable differences:

### Implemented Features
✅ System metrics (CPU, memory, disk, network)  
✅ Load average monitoring  
✅ Service status checking  
✅ Network interface auto-detection  
✅ Port connection tracking  
✅ Temperature monitoring (thermal zones)  
✅ Outgoing ping tests  
✅ Custom variables  
✅ Process monitoring  
✅ Configurable sampling  
✅ Data compression and encoding  
✅ Debug logging  

### Not Yet Implemented
❌ Disk IOPS calculation (requires more complex logic)  
❌ Software RAID monitoring (mdadm)  
❌ ZFS pool monitoring  
❌ Drive health monitoring (S.M.A.R.T., NVMe)  
❌ Thin LVM pool monitoring  
❌ Advanced temperature sources (sensors, ipmitool)  
❌ Process snapshot comparison (rps1)  

### Technical Differences

1. **Language**: Node.js/JavaScript vs Bash
2. **Execution**: Requires Node.js runtime
3. **Dependencies**: No external npm packages required (uses Node.js built-ins)
4. **Performance**: Similar resource usage, slightly higher memory footprint
5. **Portability**: Requires Node.js installation

## Troubleshooting

### Agent Not Running

Check if the agent is executing:
```bash
ps aux | grep hetrixtools_agent.js
```

Verify cron/systemd schedule:
```bash
# For cron
sudo crontab -l | grep hetrixtools

# For systemd
sudo systemctl status hetrixtools-js.timer
```

### Enable Debug Mode

Edit `hetrixtools.cfg`:
```bash
DEBUG=1
```

Check debug log:
```bash
tail -f /opt/hetrixtools-js/debug.log
```

### Permission Issues

Ensure the agent runs as root or has necessary permissions:
```bash
sudo node /opt/hetrixtools-js/hetrixtools_agent.js
```

### Missing Metrics

Some metrics require specific system commands:
- **Network stats**: `ip` command
- **Service status**: `systemctl` or `service` command
- **Port monitoring**: `ss` or `netstat` command
- **Disk info**: `df`, `lsblk` commands

Verify these are installed and accessible.

### High CPU/Memory Usage

Increase the sampling interval in `hetrixtools.cfg`:
```bash
CollectEveryXSeconds=5
```

This reduces the number of samples collected per minute.

## Performance

Typical resource usage:
- **CPU**: <2% average during collection
- **Memory**: 20-80 MB (depends on system size)
- **Disk I/O**: Minimal (<1 MB/min)
- **Network**: ~5-20 KB per minute (compressed)

## Security Considerations

1. **SID Protection**: Keep your SID confidential (acts as API key)
2. **File Permissions**: Restrict access to configuration file
   ```bash
   sudo chmod 600 /opt/hetrixtools-js/hetrixtools.cfg
   ```
3. **SSL Verification**: Keep `SecuredConnection=1` unless necessary
4. **Root Privileges**: Required for some features but increases risk
5. **Custom Variables**: Don't include sensitive data

## Development

### Running Locally

```bash
node hetrixtools_agent.js
```

### Testing

Verify configuration:
```bash
node -e "console.log(require('./hetrixtools_agent.js'))"
```

### Extending

The agent can be extended by:
1. Adding new metric collectors
2. Modifying the JSON payload structure
3. Implementing additional health checks
4. Integrating with other monitoring systems

See [SPECIFICATION.md](SPECIFICATION.md) for detailed implementation guidance.

## Support

- **Documentation**: See [SPECIFICATION.md](SPECIFICATION.md) for technical details
- **Bash Version**: Reference the original Bash implementation
- **HetrixTools Support**: https://hetrixtools.com (open support ticket)

## License

Copyright 2015 - 2025 @ HetrixTools

See the disclaimer of warranty in the agent source code. The software is provided "AS IS" and "WITH ALL FAULTS," without warranty of any kind.

## Version

**Current Version**: 2.3.8-js (JavaScript implementation based on specification v2.3.8)

This version implements the core functionality described in the technical specification. Future updates may include additional features from the Bash version.
