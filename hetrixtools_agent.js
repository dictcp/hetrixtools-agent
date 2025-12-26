#!/usr/bin/env node

/**
 * HetrixTools Server Monitoring Agent - Node.js Implementation
 * Copyright 2015 - 2025 @ HetrixTools
 * For support, please open a ticket on our website https://hetrixtools.com
 * 
 * DISCLAIMER OF WARRANTY
 * 
 * The Software is provided "AS IS" and "WITH ALL FAULTS," without warranty of any kind,
 * including without limitation the warranties of merchantability, fitness for a particular purpose and non-infringement.
 * HetrixTools makes no warranty that the Software is free of defects or is suitable for any particular purpose.
 * In no event shall HetrixTools be responsible for loss or damages arising from the installation or use of the Software,
 * including but not limited to any indirect, punitive, special, incidental or consequential damages of any character including,
 * without limitation, damages for loss of goodwill, work stoppage, computer failure or malfunction, or any and all other commercial damages or losses.
 * The entire risk as to the quality and performance of the Software is borne by you, the user.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execSync, spawn } = require('child_process');
const https = require('https');
const zlib = require('zlib');

// Agent Version
const VERSION = '2.3.8-js';

// Script path
const SCRIPT_PATH = __dirname;

// Configuration file path
const CONFIG_FILE = path.join(SCRIPT_PATH, 'hetrixtools.cfg');

// Load configuration
function loadConfig() {
    const config = {
        SID: '',
        NetworkInterfaces: '',
        CheckServices: '',
        CheckSoftRAID: 0,
        CheckDriveHealth: 0,
        RunningProcesses: 0,
        ConnectionPorts: '',
        CustomVars: 'custom_variables.json',
        SecuredConnection: 1,
        CollectEveryXSeconds: 3,
        DEBUG: 0,
        OutgoingPings: '',
        OutgoingPingsCount: 20
    };

    try {
        const content = fs.readFileSync(CONFIG_FILE, 'utf8');
        const lines = content.split('\n');
        
        for (const line of lines) {
            const trimmed = line.trim();
            if (trimmed && !trimmed.startsWith('#')) {
                const match = trimmed.match(/^(\w+)=(.*)$/);
                if (match) {
                    const key = match[1];
                    let value = match[2].replace(/^["']|["']$/g, '');
                    
                    // Convert numeric values
                    if (['CheckSoftRAID', 'CheckDriveHealth', 'RunningProcesses', 
                         'SecuredConnection', 'CollectEveryXSeconds', 'DEBUG', 
                         'OutgoingPingsCount'].includes(key)) {
                        value = parseInt(value, 10) || 0;
                    }
                    
                    config[key] = value;
                }
            }
        }
    } catch (error) {
        console.error('Error loading config:', error.message);
        process.exit(1);
    }

    if (!config.SID) {
        console.error('ERROR: SID not configured in hetrixtools.cfg');
        process.exit(1);
    }

    return config;
}

const CONFIG = loadConfig();

// Script start time
const SCRIPT_START_TIME = new Date();

// Debug logging
function debug(message) {
    if (CONFIG.DEBUG) {
        const timestamp = new Date().toISOString().replace('T', ' ').replace('Z', '');
        const logFile = path.join(SCRIPT_PATH, 'debug.log');
        const logMessage = `[${SCRIPT_START_TIME.toISOString()}]-[${timestamp}] ${message}\n`;
        fs.appendFileSync(logFile, logMessage);
    }
}

debug(`Starting HetrixTools Agent v${VERSION}`);

// Execute command with timeout
function execCommand(command, timeout = 10000) {
    try {
        return execSync(command, { 
            timeout, 
            encoding: 'utf8',
            maxBuffer: 10 * 1024 * 1024 
        }).trim();
    } catch (error) {
        return '';
    }
}

// Check service status
function checkServiceStatus(serviceName) {
    try {
        // Check via ps
        const psResult = execCommand(`ps -ef | grep -E "[/]${serviceName}([^/]|$)" | grep -v grep`);
        if (psResult) {
            return 1;
        }

        // Try systemctl
        try {
            execSync(`systemctl is-active --quiet ${serviceName}`, { timeout: 5000 });
            return 1;
        } catch (e) {
            // Try service command
            try {
                execSync(`service ${serviceName} status`, { timeout: 5000 });
                return 1;
            } catch (e2) {
                return 0;
            }
        }
    } catch (error) {
        return 0;
    }
}

// Ping test function
async function performPingTest(targetName, targetIP, count) {
    return new Promise((resolve) => {
        try {
            // Validate inputs
            if (!/^[A-Za-z0-9._-]+$/.test(targetName)) {
                debug(`Invalid PING target name: ${targetName}`);
                resolve('');
                return;
            }
            if (!/^[A-Za-z0-9.:_-]+$/.test(targetIP)) {
                debug(`Invalid PING target: ${targetIP}`);
                resolve('');
                return;
            }

            debug(`Starting PING: ${targetName} (${targetIP}) ${count} times`);

            const pingOutput = execCommand(`ping ${targetIP} -c ${count}`, 60000);
            
            if (!pingOutput) {
                resolve('');
                return;
            }

            // Extract packet loss
            const lossMatch = pingOutput.match(/(\d+)% packet loss/);
            const packetLoss = lossMatch ? lossMatch[1] : '100';

            // Extract RTT
            const rttMatch = pingOutput.match(/rtt min\/avg\/max\/mdev = [\d.]+\/([\d.]+)/);
            let avgRTT = '0';
            if (rttMatch) {
                avgRTT = Math.round(parseFloat(rttMatch[1]) * 1000).toString();
            }

            debug(`PING ${targetName}: Loss=${packetLoss}%, RTT=${avgRTT}us`);
            resolve(`${targetName},${targetIP},${packetLoss},${avgRTT};`);
        } catch (error) {
            debug(`PING error for ${targetName}: ${error.message}`);
            resolve('');
        }
    });
}

// Get network interfaces
function getNetworkInterfaces() {
    if (CONFIG.NetworkInterfaces) {
        return CONFIG.NetworkInterfaces.split(',').map(i => i.trim());
    }

    // Auto-detect
    try {
        const result = execCommand("ip a | grep BROADCAST | grep 'state UP' | grep -v 'SLAVE' | awk '{print $2}' | awk -F ':' '{print $1}' | awk -F '@' '{print $1}'");
        if (result) {
            return result.split('\n').filter(i => i);
        }
    } catch (error) {
        debug(`Error detecting network interfaces: ${error.message}`);
    }

    return [];
}

// Get network stats
function getNetworkStats(interfaces) {
    const stats = {};
    try {
        const netDev = fs.readFileSync('/proc/net/dev', 'utf8');
        const lines = netDev.split('\n');
        
        for (const iface of interfaces) {
            const line = lines.find(l => l.trim().startsWith(iface + ':'));
            if (line) {
                const parts = line.trim().split(/\s+/);
                stats[iface] = {
                    rx: parseInt(parts[1], 10) || 0,
                    tx: parseInt(parts[9], 10) || 0
                };
            }
        }
    } catch (error) {
        debug(`Error reading network stats: ${error.message}`);
    }
    return stats;
}

// Get disk stats
function getDiskStats() {
    const stats = {};
    try {
        const diskstats = fs.readFileSync('/proc/diskstats', 'utf8');
        const lines = diskstats.split('\n');
        
        for (const line of lines) {
            const parts = line.trim().split(/\s+/);
            if (parts.length >= 14) {
                const device = parts[2];
                stats[device] = {
                    readSectors: parseInt(parts[5], 10) || 0,
                    writeSectors: parseInt(parts[9], 10) || 0
                };
            }
        }
    } catch (error) {
        debug(`Error reading disk stats: ${error.message}`);
    }
    return stats;
}

// Get CPU temperature
function getCPUTemperature() {
    const temps = {};
    
    try {
        // Try thermal zones
        const thermalPath = '/sys/class/thermal';
        if (fs.existsSync(thermalPath)) {
            const zones = fs.readdirSync(thermalPath).filter(f => f.startsWith('thermal_zone'));
            for (const zone of zones) {
                try {
                    const typePath = path.join(thermalPath, zone, 'type');
                    const tempPath = path.join(thermalPath, zone, 'temp');
                    if (fs.existsSync(typePath) && fs.existsSync(tempPath)) {
                        const type = fs.readFileSync(typePath, 'utf8').trim();
                        const temp = parseInt(fs.readFileSync(tempPath, 'utf8').trim(), 10);
                        if (type && !isNaN(temp)) {
                            temps[type] = (temps[type] || 0) + temp;
                        }
                    }
                } catch (e) {
                    // Ignore individual zone errors
                }
            }
        }
    } catch (error) {
        debug(`Error reading temperature: ${error.message}`);
    }
    
    return temps;
}

// Main sampling loop
async function collectMetrics() {
    const runTimes = Math.floor(60 / CONFIG.CollectEveryXSeconds);
    const startMinute = new Date().getMinutes();
    
    debug(`Collecting data for ${runTimes} loops`);

    // Initialize accumulators
    let totalCPU = 0, totalCPUwa = 0, totalCPUst = 0, totalCPUus = 0, totalCPUsy = 0;
    let totalRAM = 0, totalRAMSwap = 0, totalRAMBuff = 0, totalRAMCache = 0;
    let totalLoad1 = 0, totalLoad5 = 0, totalLoad15 = 0;
    let totalCPUSpeed = 0;
    const networkStats = {};
    const diskStats = {};
    const connectionCounts = {};
    const temperatureReadings = {};
    let sampleCount = 0;

    // Get network interfaces
    const networkInterfaces = getNetworkInterfaces();
    debug(`Network Interfaces: ${networkInterfaces.join(', ')}`);

    // Initial network stats
    let prevNetStats = getNetworkStats(networkInterfaces);
    let prevDiskStats = getDiskStats();
    let prevTime = Date.now();

    // Initialize network accumulators
    for (const iface of networkInterfaces) {
        networkStats[iface] = { rx: 0, tx: 0 };
    }

    // Get port list
    let ports = [];
    if (CONFIG.ConnectionPorts) {
        ports = CONFIG.ConnectionPorts.split(',').map(p => p.trim());
    } else {
        // Auto-detect listening ports
        try {
            const portList = execCommand("ss -Htnl 2>/dev/null | awk '{print $4}' | grep -E ':[0-9]+$' | grep -Ev '^(127\\.|::1|\\[::1\\])' | sed -E 's/.*:([0-9]+)$/\\1/' | sort -n | uniq | head -30");
            if (portList) {
                ports = portList.split('\n').filter(p => p);
            }
        } catch (error) {
            debug(`Error detecting ports: ${error.message}`);
        }
    }

    if (ports.length > 0) {
        debug(`Monitoring ports: ${ports.join(', ')}`);
        for (const port of ports) {
            connectionCounts[port] = 0;
        }
    }

    // Sampling loop
    for (let i = 0; i < runTimes; i++) {
        try {
            // Get vmstat data
            const vmstat = execCommand(`vmstat ${CONFIG.CollectEveryXSeconds} 2 | tail -1`);
            if (!vmstat) continue;

            const vmstatParts = vmstat.trim().split(/\s+/);
            if (vmstatParts.length < 17) continue;

            // CPU metrics
            const idleCPU = parseFloat(vmstatParts[14]) || 0;
            const cpu = 100 - idleCPU;
            const cpuwa = parseFloat(vmstatParts[15]) || 0;
            const cpust = parseFloat(vmstatParts[16]) || 0;
            const cpuus = parseFloat(vmstatParts[12]) || 0;
            const cpusy = parseFloat(vmstatParts[13]) || 0;

            totalCPU += cpu;
            totalCPUwa += cpuwa;
            totalCPUst += cpust;
            totalCPUus += cpuus;
            totalCPUsy += cpusy;

            // Memory metrics
            const meminfo = fs.readFileSync('/proc/meminfo', 'utf8');
            const memTotal = parseInt(meminfo.match(/MemTotal:\s+(\d+)/)?.[1] || 0, 10);
            const memFree = parseInt(vmstatParts[3], 10) || 0;
            const memBuff = parseInt(vmstatParts[4], 10) || 0;
            const memCache = parseInt(vmstatParts[5], 10) || 0;
            
            if (memTotal > 0) {
                const memUsed = 100 - ((memFree + memBuff + memCache) * 100 / memTotal);
                totalRAM += memUsed;
                totalRAMBuff += (memBuff * 100 / memTotal);
                totalRAMCache += (memCache * 100 / memTotal);
            }

            // Swap
            const swapTotal = parseInt(meminfo.match(/SwapTotal:\s+(\d+)/)?.[1] || 0, 10);
            const swapUsed = parseInt(vmstatParts[2], 10) || 0;
            if (swapTotal > 0) {
                totalRAMSwap += (swapUsed * 100 / swapTotal);
            }

            // Load average
            const loadavg = fs.readFileSync('/proc/loadavg', 'utf8').split(' ');
            totalLoad1 += parseFloat(loadavg[0]) || 0;
            totalLoad5 += parseFloat(loadavg[1]) || 0;
            totalLoad15 += parseFloat(loadavg[2]) || 0;

            // CPU speed
            try {
                const cpuinfo = fs.readFileSync('/proc/cpuinfo', 'utf8');
                const speeds = cpuinfo.match(/cpu MHz\s+:\s+([\d.]+)/g);
                if (speeds) {
                    const speedSum = speeds.reduce((sum, s) => {
                        const speed = parseFloat(s.split(':')[1]);
                        return sum + (isNaN(speed) ? 0 : speed);
                    }, 0);
                    totalCPUSpeed += speedSum;
                }
            } catch (e) {
                // Ignore
            }

            // Network stats
            const currentTime = Date.now();
            const timeDiff = (currentTime - prevTime) / 1000;
            if (timeDiff > 0) {
                const currentNetStats = getNetworkStats(networkInterfaces);
                for (const iface of networkInterfaces) {
                    if (currentNetStats[iface] && prevNetStats[iface]) {
                        const rxDelta = currentNetStats[iface].rx - prevNetStats[iface].rx;
                        const txDelta = currentNetStats[iface].tx - prevNetStats[iface].tx;
                        networkStats[iface].rx += rxDelta / timeDiff;
                        networkStats[iface].tx += txDelta / timeDiff;
                    }
                }
                prevNetStats = currentNetStats;
                prevTime = currentTime;
            }

            // Port connections
            if (ports.length > 0) {
                try {
                    const connections = execCommand("ss -ntu | awk '{print $5}'");
                    for (const port of ports) {
                        const count = (connections.match(new RegExp(`:${port}$`, 'g')) || []).length;
                        connectionCounts[port] += count;
                    }
                } catch (error) {
                    debug(`Error counting connections: ${error.message}`);
                }
            }

            // Temperature
            const temps = getCPUTemperature();
            for (const [sensor, value] of Object.entries(temps)) {
                temperatureReadings[sensor] = (temperatureReadings[sensor] || 0) + value;
            }

            sampleCount++;

            // Check if minute changed
            if (new Date().getMinutes() !== startMinute) {
                debug('Minute changed, ending loop');
                break;
            }
        } catch (error) {
            debug(`Error in sampling loop: ${error.message}`);
        }
    }

    if (sampleCount === 0) {
        sampleCount = 1; // Prevent division by zero
    }

    debug(`Completed ${sampleCount} samples`);

    // Calculate averages
    const metrics = {
        cpu: (totalCPU / sampleCount).toFixed(2),
        cpuwa: (totalCPUwa / sampleCount).toFixed(2),
        cpust: (totalCPUst / sampleCount).toFixed(2),
        cpuus: (totalCPUus / sampleCount).toFixed(2),
        cpusy: (totalCPUsy / sampleCount).toFixed(2),
        ram: (totalRAM / sampleCount).toFixed(2),
        ramswap: (totalRAMSwap / sampleCount).toFixed(2),
        rambuff: (totalRAMBuff / sampleCount).toFixed(2),
        ramcache: (totalRAMCache / sampleCount).toFixed(2),
        load1: (totalLoad1 / sampleCount).toFixed(2),
        load5: (totalLoad5 / sampleCount).toFixed(2),
        load15: (totalLoad15 / sampleCount).toFixed(2),
        sampleCount
    };

    // Average network stats
    for (const iface of networkInterfaces) {
        networkStats[iface].rx = Math.round(networkStats[iface].rx / sampleCount);
        networkStats[iface].tx = Math.round(networkStats[iface].tx / sampleCount);
    }

    // Average connection counts
    for (const port of ports) {
        connectionCounts[port] = Math.round(connectionCounts[port] / sampleCount);
    }

    return { metrics, networkStats, networkInterfaces, connectionCounts, temperatureReadings, sampleCount };
}

// Get system information
function getSystemInfo() {
    const info = {
        user: os.userInfo().username,
        hostname: Buffer.from(os.hostname()).toString('base64'),
        uptime: Math.floor(os.uptime()),
        cpuModel: Buffer.from(os.cpus()[0]?.model || 'Unknown').toString('base64'),
        cpuCores: os.cpus().length,
        cpuThreads: 1,
        cpuSockets: 1,
        ramSize: Math.floor(os.totalmem() / 1024),
        ramSwapSize: 0
    };

    // Get OS info
    try {
        let osInfo = execCommand("lsb_release -s -d") || 
                     execCommand("cat /etc/redhat-release") ||
                     execCommand("grep '^PRETTY_NAME=' /etc/os-release | cut -d'\"' -f2") ||
                     os.type();
        info.os = Buffer.from(osInfo).toString('base64');
    } catch (error) {
        info.os = Buffer.from(os.type()).toString('base64');
    }

    // Get kernel
    info.kernel = Buffer.from(os.release()).toString('base64');

    // Get CPU sockets
    try {
        const sockets = execCommand("grep -i 'physical id' /proc/cpuinfo | sort -u | wc -l");
        if (sockets) {
            info.cpuSockets = parseInt(sockets, 10) || 1;
        }
    } catch (error) {
        // Keep default
    }

    // Get swap size
    try {
        const meminfo = fs.readFileSync('/proc/meminfo', 'utf8');
        const swapMatch = meminfo.match(/SwapTotal:\s+(\d+)/);
        if (swapMatch) {
            info.ramSwapSize = parseInt(swapMatch[1], 10);
        }
    } catch (error) {
        // Keep default
    }

    // Check reboot required
    info.reqreboot = fs.existsSync('/var/run/reboot-required') ? 1 : 0;

    return info;
}

// Get disk information
function getDiskInfo() {
    const disks = [];
    const inodes = [];
    
    try {
        const dfOutput = execCommand('df -TPB1 2>/dev/null || df -l -TPB1 2>/dev/null', 5000);
        if (dfOutput) {
            const lines = dfOutput.split('\n').slice(1); // Skip header
            for (const line of lines) {
                const parts = line.trim().split(/\s+/);
                if (parts.length >= 7 && !parts[1].includes('tmpfs')) {
                    const mountPoint = parts[parts.length - 1];
                    const fsType = parts[1];
                    const total = parts[2];
                    const used = parts[3];
                    const available = parts[4];
                    disks.push(`${mountPoint},${fsType},${total},${used},${available};`);
                }
            }
        }

        const dfInodesOutput = execCommand('df -Ti 2>/dev/null || df -l -Ti 2>/dev/null', 5000);
        if (dfInodesOutput) {
            const lines = dfInodesOutput.split('\n').slice(1);
            for (const line of lines) {
                const parts = line.trim().split(/\s+/);
                if (parts.length >= 7 && !parts[1].includes('tmpfs')) {
                    const mountPoint = parts[parts.length - 1];
                    const fsType = parts[1];
                    const inodesTotal = parts[2];
                    const inodesUsed = parts[3];
                    inodes.push(`${mountPoint},${fsType},${inodesTotal},${inodesUsed};`);
                }
            }
        }
    } catch (error) {
        debug(`Error getting disk info: ${error.message}`);
    }

    return {
        disks: Buffer.from(disks.join('')).toString('base64'),
        inodes: Buffer.from(inodes.join('')).toString('base64')
    };
}

// Get service status
function getServicesStatus() {
    const services = [];
    
    if (CONFIG.CheckServices) {
        const serviceList = CONFIG.CheckServices.split(',').map(s => s.trim()).slice(0, 10);
        for (const service of serviceList) {
            const status = checkServiceStatus(service);
            services.push(`${service},${status};`);
            debug(`Service ${service} status: ${status}`);
        }
    }

    return Buffer.from(services.join('')).toString('base64');
}

// Main execution
async function main() {
    try {
        debug('Starting data collection');

        // Start ping tests in background
        const pingPromises = [];
        if (CONFIG.OutgoingPings) {
            const pingTargets = CONFIG.OutgoingPings.split('|');
            for (const target of pingTargets) {
                const [name, ip] = target.split(',').map(s => s.trim());
                if (name && ip) {
                    pingPromises.push(performPingTest(name, ip, CONFIG.OutgoingPingsCount));
                }
            }
        }

        // Collect metrics
        const { metrics, networkStats, networkInterfaces, connectionCounts, temperatureReadings, sampleCount } = await collectMetrics();

        // Get system information
        const sysInfo = getSystemInfo();

        // Get disk information
        const diskInfo = getDiskInfo();

        // Get service status
        const servicesStatus = getServicesStatus();

        // Build network info
        const nics = [];
        const ipv4 = [];
        const ipv6 = [];
        
        for (const iface of networkInterfaces) {
            const stats = networkStats[iface];
            nics.push(`${iface},${stats.rx},${stats.tx};`);
            
            // Get IP addresses
            try {
                const ipv4Addrs = execCommand(`ip -4 addr show ${iface} | grep -oP 'inet \\K[\\d.]+'`);
                if (ipv4Addrs) {
                    ipv4.push(`${iface},${ipv4Addrs.split('\n').join(',')};`);
                }
                
                const ipv6Addrs = execCommand(`ip -6 addr show ${iface} | grep -w "global" | grep -oP 'inet6 \\K[0-9a-fA-F:]+'`);
                if (ipv6Addrs) {
                    ipv6.push(`${iface},${ipv6Addrs.split('\n').join(',')};`);
                }
            } catch (error) {
                debug(`Error getting IPs for ${iface}: ${error.message}`);
            }
        }

        // Build connection info
        const conn = [];
        for (const [port, count] of Object.entries(connectionCounts)) {
            conn.push(`${port},${count};`);
        }

        // Build temperature info
        const temp = [];
        for (const [sensor, value] of Object.entries(temperatureReadings)) {
            const avgValue = Math.round(value / sampleCount);
            temp.push(`${sensor},${avgValue};`);
        }

        // Wait for ping tests
        const pingResults = await Promise.all(pingPromises);
        const oping = pingResults.filter(r => r).join('');

        // Read custom variables
        let customVars = '';
        if (CONFIG.CustomVars) {
            try {
                const customPath = path.join(SCRIPT_PATH, CONFIG.CustomVars);
                if (fs.existsSync(customPath)) {
                    customVars = fs.readFileSync(customPath, 'utf8');
                }
            } catch (error) {
                debug(`Error reading custom variables: ${error.message}`);
            }
        }

        // Get running processes
        let rps2 = '';
        if (CONFIG.RunningProcesses) {
            try {
                const processes = execCommand('ps -Ao pid,ppid,uid,user:20,pcpu,pmem,cputime,etime,comm,cmd --no-headers', 5000);
                rps2 = Buffer.from(processes).toString('base64');
            } catch (error) {
                debug(`Error getting processes: ${error.message}`);
            }
        }

        // Construct JSON payload
        const currentTime = Buffer.from(new Date().toISOString().replace('T', ' ').replace('Z', ' UTC')).toString('base64');
        
        const payload = {
            version: VERSION,
            SID: CONFIG.SID,
            agent: '0',
            user: sysInfo.user,
            os: sysInfo.os,
            kernel: sysInfo.kernel,
            hostname: sysInfo.hostname,
            time: currentTime,
            reqreboot: sysInfo.reqreboot,
            uptime: sysInfo.uptime,
            cpumodel: sysInfo.cpuModel,
            cpusockets: sysInfo.cpuSockets,
            cpucores: sysInfo.cpuCores,
            cputhreads: sysInfo.cpuThreads,
            cpuspeed: '0', // Not easily available in Node.js
            cpu: metrics.cpu,
            wa: metrics.cpuwa,
            st: metrics.cpust,
            us: metrics.cpuus,
            sy: metrics.cpusy,
            load1: metrics.load1,
            load5: metrics.load5,
            load15: metrics.load15,
            ramsize: sysInfo.ramSize,
            ram: metrics.ram,
            ramswapsize: sysInfo.ramSwapSize,
            ramswap: metrics.ramswap,
            rambuff: metrics.rambuff,
            ramcache: metrics.ramcache,
            disks: diskInfo.disks,
            inodes: diskInfo.inodes,
            iops: '', // Simplified for initial implementation
            raid: '', // Requires elevated privileges
            zp: '', // Requires ZFS
            dh: '', // Requires smartctl/nvme
            nics: Buffer.from(nics.join('')).toString('base64'),
            ipv4: Buffer.from(ipv4.join('')).toString('base64'),
            ipv6: Buffer.from(ipv6.join('')).toString('base64'),
            conn: Buffer.from(conn.join('')).toString('base64'),
            temp: Buffer.from(temp.join('')).toString('base64'),
            serv: servicesStatus,
            cust: customVars ? Buffer.from(customVars).toString('base64') : '',
            oping: oping ? Buffer.from(oping).toString('base64') : '',
            rps1: '', // Previous snapshot (not implemented in this version)
            rps2: rps2
        };

        const jsonStr = JSON.stringify(payload);
        debug(`JSON payload size: ${jsonStr.length} bytes`);

        // Compress and encode
        const compressed = zlib.gzipSync(jsonStr);
        const encoded = compressed.toString('base64')
            .replace(/\//g, '%2F')
            .replace(/\+/g, '%2B');

        const postData = `j=${encoded}`;

        // Save to log file
        const logFile = path.join(SCRIPT_PATH, 'hetrixtools_agent.log');
        fs.writeFileSync(logFile, postData);

        debug('Posting data to HetrixTools');

        // Send data
        const options = {
            hostname: 'sm.hetrixtools.net',
            port: 443,
            path: '/v2/',
            method: 'POST',
            headers: {
                'Content-Type': 'application/x-www-form-urlencoded',
                'Content-Length': Buffer.byteLength(postData)
            },
            rejectUnauthorized: CONFIG.SecuredConnection === 1
        };

        const req = https.request(options, (res) => {
            let responseData = '';
            res.on('data', (chunk) => {
                responseData += chunk;
            });
            res.on('end', () => {
                debug(`Response status: ${res.statusCode}`);
                if (CONFIG.DEBUG && responseData) {
                    debug(`Response: ${responseData}`);
                }
            });
        });

        req.on('error', (error) => {
            debug(`Error posting data: ${error.message}`);
        });

        req.write(postData);
        req.end();

        debug('Data posted successfully');

    } catch (error) {
        console.error('Fatal error:', error);
        debug(`Fatal error: ${error.message}\n${error.stack}`);
        process.exit(1);
    }
}

// Run main function
main().catch(error => {
    console.error('Unhandled error:', error);
    process.exit(1);
});
