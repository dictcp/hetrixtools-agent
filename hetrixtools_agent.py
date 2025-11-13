#!/usr/bin/env python3
#
#
#	HetrixTools Server Monitoring Agent
#	version 1.5.9
#	Copyright 2015 - 2020 @  HetrixTools
#	For support, please open a ticket on our website https://hetrixtools.com
#
#
#		DISCLAIMER OF WARRANTY
#
#	The Software is provided "AS IS" and "WITH ALL FAULTS," without warranty of any kind, 
#	including without limitation the warranties of merchantability, fitness for a particular purpose and non-infringement. 
#	HetrixTools makes no warranty that the Software is free of defects or is suitable for any particular purpose. 
#	In no event shall HetrixTools be responsible for loss or damages arising from the installation or use of the Software, 
#	including but not limited to any indirect, punitive, special, incidental or consequential damages of any character including, 
#	without limitation, damages for loss of goodwill, work stoppage, computer failure or malfunction, or any and all other commercial damages or losses. 
#	The entire risk as to the quality and performance of the Software is borne by you, the user.
#
#

import os
import sys
import time
import base64
import gzip
import re
import subprocess
import urllib.parse
import urllib.request
from pathlib import Path

##############
## Settings ##
##############

# Get script path
SCRIPT_PATH = os.path.dirname(os.path.abspath(__file__))

# Agent Version (do not change)
VERSION = "1.5.9"

# SID (Server ID - automatically assigned on installation, do not change this)
# DO NOT share this ID with anyone
SID = "SIDPLACEHOLDER"

# How frequently should the data be collected (do not modify this, unless instructed to do so)
COLLECT_EVERY_X_SECONDS = 3

# Runtime, in seconds (do not modify this, unless instructed to do so)
RUNTIME = 60

# Network Interfaces
# * if you leave this setting empty our agent will detect and monitor all of your active network interfaces
# * if you wish to monitor just one interface, fill its name down below (ie: "eth1")
# * if you wish to monitor just some specific interfaces, fill their names below separated by comma (ie: "eth0,eth1,eth2")
NETWORK_INTERFACES = ""

# Check Services
# * separate service names by comma (,) with a maximum of 10 services to be monitored (ie: "ssh,mysql,apache2,nginx")
# * NOTE: this will only check if the service is running, not its functionality
CHECK_SERVICES = ""

# Check Software RAID Health
# * checks the status/health of any software RAID (mdadm) setup on the server
# * agent must be run as 'root' or privileged user to fetch the RAID status
# * 0 - OFF (default) | 1 - ON
CHECK_SOFT_RAID = 0

# Check Drive Health
# * checks the health of any found drives on the system
# * requirements: 'S.M.A.R.T.' for HDD/SSD or 'nvme-cli' for NVMe
# * (these do not get installed by our agent, you must install them separately)
# * agent must be run as 'root' or privileged user to use this function
# * 0 - OFF
# WARN: Please do not enable it, since synology ds118 has lsblk command 
CHECK_DRIVE_HEALTH = 0

# View Running Processes
# * whether or not to record the server's running processes and display them in your HetrixTools dashboard
# * 0 - OFF (default) | 1 - ON
RUNNING_PROCESSES = 0

# Port Connections
# * track network connections to specific ports
# * supports up to 10 different ports, separated by comma (ie: "80,443,3306")
CONNECTION_PORTS = ""

################################################
## CAUTION: Do not edit any of the code below ##
################################################

def run_command(cmd, shell=True, capture_output=True):
    """Run a shell command and return output"""
    try:
        result = subprocess.run(cmd, shell=shell, capture_output=capture_output, text=True, timeout=30)
        return result.stdout.strip() if capture_output else ""
    except Exception:
        return ""

def service_status(service_name):
    """Check if a service is running"""
    # Check first via ps
    ps_output = run_command(f"ps -ef | grep -v grep | grep {service_name} | wc -l")
    if ps_output and int(ps_output) > 0:
        # Up
        return f"{base64.b64encode(service_name.encode()).decode()},1"
    else:
        # Down, try with systemctl (if available)
        if os.path.exists("/usr/bin/systemctl") or os.path.exists("/bin/systemctl"):
            result = subprocess.run(["systemctl", "is-active", "--quiet", service_name], 
                                    capture_output=True, timeout=10)
            if result.returncode == 0:
                # Up
                return f"{base64.b64encode(service_name.encode()).decode()},1"
            else:
                # Down
                return f"{base64.b64encode(service_name.encode()).decode()},0"
        else:
            # No systemctl, declare it down
            return f"{base64.b64encode(service_name.encode()).decode()},0"

def base64_prep(s):
    """Prepare base64 string for url encoding"""
    s = s.replace('+', '%2B')
    s = s.replace('/', '%2F')
    return s

def compress_and_encode(data):
    """Compress data with gzip and encode to base64"""
    if isinstance(data, str):
        data = data.encode()
    compressed = gzip.compress(data)
    encoded = base64.b64encode(compressed).decode()
    return base64_prep(encoded)

# Kill any lingering agent processes
def kill_lingering_processes():
    """Kill lingering agent processes if too many are running"""
    try:
        ps_output = run_command("ps -eo user= | sort | uniq -c | grep hetrixtools")
        if ps_output:
            count = int(ps_output.split()[0])
            if count > 300:
                run_command("ps aux | grep -ie hetrixtools_agent | awk '{print $2}' | xargs kill -9")
    except Exception:
        pass

kill_lingering_processes()

# Calculate how many times per minute should the data be collected
run_times = RUNTIME // COLLECT_EVERY_X_SECONDS

# Start timers
start_time = time.time()
t_time_diff = 0
M = int(time.strftime('%M').lstrip('0') or 0)

# Clear the hetrixtools_cron.log every hour
if M == 0:
    log_file = os.path.join(SCRIPT_PATH, 'hetrixtools_cron.log')
    if os.path.exists(log_file):
        os.remove(log_file)

# Network interfaces
network_interfaces_array = []
if NETWORK_INTERFACES:
    # Use the network interfaces specified in Settings
    network_interfaces_array = NETWORK_INTERFACES.split(',')
else:
    # Automatically detect the network interfaces
    ip_output = run_command("ip a | grep BROADCAST | grep 'state UP' | awk '{print $2}' | awk -F ':' '{print $1}' | awk -F '@' '{print $1}'")
    if ip_output:
        network_interfaces_array = ip_output.split('\n')

# Get the initial network usage
net_dev = open('/proc/net/dev').read()
a_rx = {}
a_tx = {}
t_rx = {}
t_tx = {}

# Loop through network interfaces
for nic in network_interfaces_array:
    for line in net_dev.split('\n'):
        if f'{nic}:' in line:
            parts = line.split()
            a_rx[nic] = int(parts[1])
            a_tx[nic] = int(parts[9])
            t_rx[nic] = 0
            t_tx[nic] = 0
            break

# Port connections
connections = {}
if CONNECTION_PORTS:
    connection_ports_array = CONNECTION_PORTS.split(',')
    netstat_output = run_command("netstat -ntu | awk '{print $4}'")
    for c_port in connection_ports_array:
        count = netstat_output.count(f':{c_port}\n')
        connections[c_port] = count

# Disks IOPS
# Hardcoded since lsblk is not available on synology ds118
v_disks = {
    '/': 'sda1',
    '/volume1': 'sda3'
}

iops_read = {}
iops_write = {}
diskstats = open('/proc/diskstats').read()
for mount_point, disk in v_disks.items():
    for line in diskstats.split('\n'):
        if disk in line:
            parts = line.split()
            iops_read[mount_point] = int(parts[5])
            iops_write[mount_point] = int(parts[9])
            break

# Collect data loop
t_cpu = 0
t_iow = 0
t_ram = 0

for X in range(1, run_times + 1):
    # Get vmstat info
    vmstat_output = run_command(f"vmstat {COLLECT_EVERY_X_SECONDS} 2 | tail -1")
    vmstat_parts = vmstat_output.split()
    
    # Get CPU Load
    cpu = 100 - int(vmstat_parts[14])
    t_cpu += cpu
    
    # Get IO Wait
    iow = int(vmstat_parts[15])
    t_iow += iow
    
    # Get RAM Usage
    a_ram = int(vmstat_parts[3]) + int(vmstat_parts[4]) + int(vmstat_parts[5])
    mem_total = int(run_command("grep MemTotal /proc/meminfo | awk '{print $2}'"))
    ram = 100 - (a_ram * 100 / mem_total)
    t_ram += ram
    
    # Get Network Usage
    net_dev = open('/proc/net/dev').read()
    end_time = time.time()
    time_diff = end_time - start_time
    t_time_diff += time_diff
    start_time = time.time()
    
    # Loop through network interfaces
    for nic in network_interfaces_array:
        for line in net_dev.split('\n'):
            if f'{nic}:' in line:
                parts = line.split()
                # Received Traffic
                rx = (int(parts[1]) - a_rx[nic]) / time_diff
                rx = int(rx)
                a_rx[nic] = int(parts[1])
                t_rx[nic] += rx
                # Transferred Traffic
                tx = (int(parts[9]) - a_tx[nic]) / time_diff
                tx = int(tx)
                a_tx[nic] = int(parts[9])
                t_tx[nic] += tx
                break
    
    # Port connections
    if CONNECTION_PORTS:
        netstat_output = run_command("netstat -ntu | awk '{print $4}'")
        for c_port in connection_ports_array:
            count = netstat_output.count(f':{c_port}\n')
            connections[c_port] += count
    
    # Check if minute changed, so we can end the loop
    MM = int(time.strftime('%M').lstrip('0') or 0)
    if MM > M:
        break

# Disks IOPS
iops_str = ""
diskstats = open('/proc/diskstats').read()
for mount_point, disk in v_disks.items():
    for line in diskstats.split('\n'):
        if disk in line:
            parts = line.split()
            read_val = ((int(parts[5]) - iops_read[mount_point]) * 512) / t_time_diff
            write_val = ((int(parts[9]) - iops_write[mount_point]) * 512) / t_time_diff
            iops_str += f"|{mount_point};{int(read_val)};{int(write_val)}"
            break

iops_data = compress_and_encode(iops_str)

# Check if system requires reboot
requires_reboot = 0
if os.path.exists('/var/run/reboot-required'):
    requires_reboot = 1

# Get Operating System and Kernel
os_info = ""
# Check via lsb_release if possible
if os.path.exists('/usr/bin/lsb_release'):
    os_info = run_command("lsb_release -s -d")
# Check if it's Debian
elif os.path.exists('/etc/debian_version'):
    debian_version = open('/etc/debian_version').read().strip()
    os_info = f"Debian {debian_version}"
# Check if it's CentOS/Fedora
elif os.path.exists('/etc/redhat-release'):
    os_info = open('/etc/redhat-release').read().strip()
    # Check if system requires reboot (Only supported in CentOS/RHEL 7 and later, with yum-utils installed)
    needs_restart = run_command("needs-restarting -r 2>/dev/null | grep 'Reboot is required'")
    if needs_restart:
        requires_reboot = 1
# If all else fails, get Kernel name
else:
    os_info = run_command("uname -s") + " " + run_command("uname -r")

kernel_version = run_command("uname -r")
os_encoded = base64.b64encode(f"{os_info}|{kernel_version}|{requires_reboot}".encode()).decode()

# Get the server uptime
uptime = open('/proc/uptime').read().split()[0]

# Get CPU model
cpu_info = open('/proc/cpuinfo').read()
cpu_model = ""
for line in cpu_info.split('\n'):
    if 'model name' in line:
        cpu_model = line.split(': ')[1]
        break
cpu_model_encoded = base64.b64encode(cpu_model.encode()).decode()

# Get CPU speed (MHz)
cpu_speed = ""
for line in cpu_info.split('\n'):
    if 'cpu MHz' in line:
        cpu_speed = line.split(': ')[1]
        break
cpu_speed_encoded = base64.b64encode(cpu_speed.encode()).decode()

# Get number of cores
cpu_cores = cpu_info.count('processor')

# Calculate average CPU Usage
cpu_avg = t_cpu / X

# Calculate IO Wait
iow_avg = t_iow / X

# Get system memory (RAM)
ram_size = run_command("grep ^MemTotal: /proc/meminfo | awk '{print $2}'")

# Calculate RAM Usage
ram_avg = t_ram / X

# Get the Swap Size
swap_size = run_command("grep ^SwapTotal: /proc/meminfo | awk '{print $2}'")

# Calculate Swap Usage
swap_free = run_command("grep ^SwapFree: /proc/meminfo | awk '{print $2}'")
if int(swap_size) > 0:
    swap_usage = 100 - ((int(swap_free) / int(swap_size)) * 100)
else:
    swap_usage = 0

# Get all disks usage
df_output = run_command("df -PB1 | awk '$1 ~ /\\// {print}' | awk '{ print $(NF)\",\"$2\",\"$3\",\"$4\";\" }'")
disks_data = compress_and_encode(df_output)

# Get all disks inodes
dfi_output = run_command("df -i | awk '$1 ~ /\\// {print}' | awk '{ print $(NF)\",\"$2\",\"$3\",\"$4\";\" }'")
diski_data = compress_and_encode(dfi_output)

# Calculate Total Network Usage (bytes)
nics_str = ""
for nic in network_interfaces_array:
    rx_avg = int(t_rx[nic] / X)
    tx_avg = int(t_tx[nic] / X)
    nics_str += f"|{nic};{rx_avg};{tx_avg};"

nics_data = compress_and_encode(nics_str)

# Port connections
conn_str = ""
if CONNECTION_PORTS:
    for c_port in connection_ports_array:
        con_avg = int(connections[c_port] / X)
        conn_str += f"|{c_port};{con_avg}"

conn_data = base64_prep(base64.b64encode(conn_str.encode()).decode())

# Check Services (if any are set to be checked)
service_status_string = ""
if CHECK_SERVICES:
    check_services_array = CHECK_SERVICES.split(',')
    for service in check_services_array:
        service_status_string += service_status(service) + ";"

# Check Software RAID
raid_str = ""
if CHECK_SOFT_RAID > 0:
    df_output = run_command("df -PB1 | awk '$1 ~ /\\// {print}' | awk '{ print $1 }'")
    for device in df_output.split('\n'):
        if device:
            mdadm_output = run_command(f"mdadm -D {device} 2>/dev/null")
            if mdadm_output:
                mnt = run_command(f"df -PB1 | grep {device} | awk '{{ print $(NF) }}'")
                raid_str += f"|{mnt};{device};{mdadm_output};"

raid_data = compress_and_encode(raid_str)

# Check Drive Health
dh_str = ""
if CHECK_DRIVE_HEALTH > 0:
    # Using S.M.A.R.T. (for regular HDD/SSD)
    if os.path.exists('/usr/sbin/smartctl') or os.path.exists('/usr/bin/smartctl'):
        lsblk_output = run_command("lsblk -l | grep 'disk' | awk '{ print $1 }'")
        for disk in lsblk_output.split('\n'):
            if disk:
                d_health = run_command(f"smartctl -A /dev/{disk}")
                if 'Attribute' in d_health:
                    d_health_full = run_command(f"smartctl -H /dev/{disk}") + "\n" + d_health
                    dh_str += f"|1\n{disk}\n{d_health_full}\n"
                else:
                    # If initial read has failed, see if drives are behind hardware raid
                    megaraid = run_command("smartctl --scan | grep megaraid | awk '{ print $(3) }'")
                    if megaraid:
                        megaraid_ids = megaraid.split('\n')
                        megaraid_n = 0
                        for megaraid_id in megaraid_ids:
                            if megaraid_id:
                                d_health = run_command(f"smartctl -A -d {megaraid_id} /dev/{disk}")
                                if 'Attribute' in d_health:
                                    megaraid_n += 1
                                    d_health_full = run_command(f"smartctl -H -d {megaraid_id} /dev/{disk}") + "\n" + d_health
                                    dh_str += f"|1\n{disk}[{megaraid_n}]\n{d_health_full}\n"
                        break
    
    # Using nvme-cli (for NVMe)
    if os.path.exists('/usr/sbin/nvme') or os.path.exists('/usr/bin/nvme'):
        lsblk_output = run_command("lsblk -l | grep 'disk' | awk '{ print $1 }'")
        for disk in lsblk_output.split('\n'):
            if disk:
                d_health = run_command(f"nvme smart-log /dev/{disk}")
                if 'NVME' in d_health:
                    if os.path.exists('/usr/sbin/smartctl') or os.path.exists('/usr/bin/smartctl'):
                        disk_base = disk[:-2] if len(disk) > 2 else disk
                        smart_output = run_command(f"smartctl -H /dev/{disk_base}")
                        d_health = smart_output + "\n" + d_health
                    dh_str += f"|2\n{disk}\n{d_health}\n"

dh_data = compress_and_encode(dh_str)

# Running Processes
rps1 = ""
rps2 = ""
if RUNNING_PROCESSES > 0:
    # Get initial 'running processes' snapshot, saved from last run
    running_proc_file = os.path.join(SCRIPT_PATH, 'running_proc.txt')
    if os.path.exists(running_proc_file):
        with open(running_proc_file, 'r') as f:
            rps1 = f.read().strip()
    
    # Get the current 'running processes' snapshot
    rps2_output = run_command("ps -Ao pid,ppid,uid,user:20,pcpu,pmem,cputime,etime,comm,cmd --no-headers")
    rps2 = compress_and_encode(rps2_output)
    
    # Save the current snapshot for next run
    with open(running_proc_file, 'w') as f:
        f.write(rps2)

# Prepare data
data = f"{os_encoded}|{uptime}|{cpu_model_encoded}|{cpu_speed_encoded}|{cpu_cores}|{cpu_avg}|{iow_avg}|{ram_size}|{ram_avg}|{swap_size}|{swap_usage}|{disks_data}|{nics_data}|{service_status_string}|{raid_data}|{dh_data}|{rps1}|{rps2}|{iops_data}|{conn_data}|{diski_data}"
post_data = f"v={VERSION}&s={SID}&d={data}"

# Save data to file
agent_log_file = os.path.join(SCRIPT_PATH, 'hetrixtools_agent.log')
with open(agent_log_file, 'w') as f:
    f.write(post_data)

# Post data
try:
    with open(agent_log_file, 'rb') as f:
        post_bytes = f.read()
    
    req = urllib.request.Request(
        'https://sm.hetrixtools.net/',
        data=post_bytes,
        headers={'Content-Type': 'application/x-www-form-urlencoded'}
    )
    
    # Disable SSL certificate verification (equivalent to --no-check-certificate)
    import ssl
    context = ssl._create_unverified_context()
    
    urllib.request.urlopen(req, context=context, timeout=30)
except Exception as e:
    # Silently fail like the bash version does with &> /dev/null
    pass
