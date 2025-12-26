## HetrixTools Server Monitoring Agent - Nim Implementation
## Copyright 2015 - 2025 @ HetrixTools
## For support, please open a ticket on our website https://hetrixtools.com
##
## DISCLAIMER OF WARRANTY
##
## The Software is provided "AS IS" and "WITH ALL FAULTS," without warranty of any kind,
## including without limitation the warranties of merchantability, fitness for a particular purpose and non-infringement.
## HetrixTools makes no warranty that the Software is free of defects or is suitable for any particular purpose.
## In no event shall HetrixTools be responsible for loss or damages arising from the installation or use of the Software,
## including but not limited to any indirect, punitive, special, incidental or consequential damages of any character including,
## without limitation, damages for loss of goodwill, work stoppage, computer failure or malfunction, or any and all other commercial damages or losses.
## The entire risk as to the quality and performance of the Software is borne by you, the user.

import std/[os, osproc, strutils, times, httpclient, json, base64, tables, parseutils, strformat, sequtils]
import std/[nativesockets]

const VERSION = "2.3.8-nim"

type
  Config = object
    SID: string
    NetworkInterfaces: string
    CheckServices: string
    CheckSoftRAID: int
    CheckDriveHealth: int
    RunningProcesses: int
    ConnectionPorts: string
    CustomVars: string
    SecuredConnection: int
    CollectEveryXSeconds: int
    DEBUG: int
    OutgoingPings: string
    OutgoingPingsCount: int

  MetricSample = object
    cpu, cpuwa, cpust, cpuus, cpusy: float
    ram, ramswap, rambuff, ramcache: float
    load1, load5, load15: float

  NetworkStats = Table[string, tuple[rx: int64, tx: int64]]

var
  config: Config
  scriptPath: string
  scriptStartTime: DateTime
  debugEnabled: bool

# Debug logging
proc debug(message: string) =
  if debugEnabled:
    let timestamp = now().format("yyyy-MM-dd HH:mm:ss")
    let logFile = scriptPath / "debug.log"
    let logMessage = fmt"[{scriptStartTime.format(\"yyyy-MM-dd HH:mm:ss\")}]-[{timestamp}] {message}" & "\n"
    try:
      let f = open(logFile, fmAppend)
      f.write(logMessage)
      f.close()
    except:
      discard

# Load configuration from hetrixtools.cfg
proc loadConfig(): Config =
  let configFile = scriptPath / "hetrixtools.cfg"
  var cfg = Config(
    SID: "",
    NetworkInterfaces: "",
    CheckServices: "",
    CheckSoftRAID: 0,
    CheckDriveHealth: 0,
    RunningProcesses: 0,
    ConnectionPorts: "",
    CustomVars: "custom_variables.json",
    SecuredConnection: 1,
    CollectEveryXSeconds: 3,
    DEBUG: 0,
    OutgoingPings: "",
    OutgoingPingsCount: 20
  )

  if not fileExists(configFile):
    echo "ERROR: Configuration file not found: ", configFile
    quit(1)

  for line in lines(configFile):
    let trimmed = line.strip()
    if trimmed.len > 0 and not trimmed.startsWith("#"):
      let parts = trimmed.split('=', 1)
      if parts.len == 2:
        let key = parts[0].strip()
        var value = parts[1].strip()
        # Remove quotes
        if value.startsWith("\"") and value.endsWith("\""):
          value = value[1..^2]
        
        case key
        of "SID": cfg.SID = value
        of "NetworkInterfaces": cfg.NetworkInterfaces = value
        of "CheckServices": cfg.CheckServices = value
        of "CheckSoftRAID": cfg.CheckSoftRAID = parseInt(value)
        of "CheckDriveHealth": cfg.CheckDriveHealth = parseInt(value)
        of "RunningProcesses": cfg.RunningProcesses = parseInt(value)
        of "ConnectionPorts": cfg.ConnectionPorts = value
        of "CustomVars": cfg.CustomVars = value
        of "SecuredConnection": cfg.SecuredConnection = parseInt(value)
        of "CollectEveryXSeconds": cfg.CollectEveryXSeconds = parseInt(value)
        of "DEBUG": cfg.DEBUG = parseInt(value)
        of "OutgoingPings": cfg.OutgoingPings = value
        of "OutgoingPingsCount": cfg.OutgoingPingsCount = parseInt(value)
        else: discard

  if cfg.SID.len == 0:
    echo "ERROR: SID not configured in hetrixtools.cfg"
    quit(1)

  result = cfg

# Execute command with timeout
proc execCommand(cmd: string, timeout: int = 10000): string =
  try:
    let process = startProcess(cmd, options={poUsePath, poStdErrToStdOut, poEvalCommand})
    let startTime = epochTime()
    var output = ""
    
    while process.running:
      if (epochTime() - startTime) * 1000 > timeout.float:
        process.kill()
        break
      sleep(10)
    
    output = process.outputStream.readAll()
    process.close()
    return output.strip()
  except:
    return ""

# Check service status
proc checkServiceStatus(serviceName: string): int =
  try:
    # Check via ps
    let psResult = execCommand(fmt"ps -ef | grep -E '[/]{serviceName}([^/]|$)' | grep -v grep", 5000)
    if psResult.len > 0:
      return 1

    # Try systemctl
    let exitCode = execCmd(fmt"systemctl is-active --quiet {serviceName}")
    if exitCode == 0:
      return 1

    # Try service command
    let serviceCode = execCmd(fmt"service {serviceName} status > /dev/null 2>&1")
    if serviceCode == 0:
      return 1
  except:
    discard
  
  return 0

# Perform ping test
proc performPingTest(targetName, targetIP: string, count: int): string =
  try:
    # Validate inputs
    if not targetName.match(re"^[A-Za-z0-9._-]+$"):
      debug(fmt"Invalid PING target name: {targetName}")
      return ""
    if not targetIP.match(re"^[A-Za-z0-9.:_-]+$"):
      debug(fmt"Invalid PING target: {targetIP}")
      return ""

    debug(fmt"Starting PING: {targetName} ({targetIP}) {count} times")

    let pingOutput = execCommand(fmt"ping {targetIP} -c {count}", 60000)
    
    if pingOutput.len == 0:
      return ""

    # Extract packet loss
    var packetLoss = "100"
    for line in pingOutput.splitLines():
      if "% packet loss" in line:
        let parts = line.split()
        for i, part in parts:
          if part.endsWith("%"):
            packetLoss = part[0..^2]
            break

    # Extract RTT
    var avgRTT = "0"
    for line in pingOutput.splitLines():
      if line.startsWith("rtt min/avg/max/mdev"):
        let parts = line.split('=')
        if parts.len >= 2:
          let values = parts[1].strip().split('/')
          if values.len >= 2:
            try:
              avgRTT = $(int(parseFloat(values[1]) * 1000.0))
            except:
              avgRTT = "0"

    debug(fmt"PING {targetName}: Loss={packetLoss}%, RTT={avgRTT}us")
    return fmt"{targetName},{targetIP},{packetLoss},{avgRTT};"
  except:
    debug(fmt"PING error for {targetName}")
    return ""

# Get network interfaces
proc getNetworkInterfaces(): seq[string] =
  if config.NetworkInterfaces.len > 0:
    return config.NetworkInterfaces.split(',').mapIt(it.strip())

  # Auto-detect
  try:
    let output = execCommand("ip a | grep BROADCAST | grep 'state UP' | grep -v 'SLAVE' | awk '{print $2}' | awk -F ':' '{print $1}' | awk -F '@' '{print $1}'")
    if output.len > 0:
      return output.splitLines().filterIt(it.len > 0)
  except:
    debug("Error detecting network interfaces")
  
  return @[]

# Get network stats from /proc/net/dev
proc getNetworkStats(interfaces: seq[string]): NetworkStats =
  var stats = initTable[string, tuple[rx: int64, tx: int64]]()
  
  try:
    let content = readFile("/proc/net/dev")
    for line in content.splitLines():
      for iface in interfaces:
        if line.strip().startsWith(iface & ":"):
          let parts = line.strip().split()
          if parts.len >= 10:
            stats[iface] = (rx: parseBiggestInt(parts[1]), tx: parseBiggestInt(parts[9]))
  except:
    debug("Error reading network stats")
  
  return stats

# Get disk stats from /proc/diskstats
proc getDiskStats(): Table[string, tuple[readSectors: int64, writeSectors: int64]] =
  var stats = initTable[string, tuple[readSectors: int64, writeSectors: int64]]()
  
  try:
    let content = readFile("/proc/diskstats")
    for line in content.splitLines():
      let parts = line.strip().split()
      if parts.len >= 14:
        let device = parts[2]
        stats[device] = (
          readSectors: parseBiggestInt(parts[5]),
          writeSectors: parseBiggestInt(parts[9])
        )
  except:
    debug("Error reading disk stats")
  
  return stats

# Get CPU temperature
proc getCPUTemperature(): Table[string, int64] =
  var temps = initTable[string, int64]()
  
  try:
    let thermalPath = "/sys/class/thermal"
    if dirExists(thermalPath):
      for kind, path in walkDir(thermalPath):
        if kind == pcDir and path.lastPathPart.startsWith("thermal_zone"):
          let typePath = path / "type"
          let tempPath = path / "temp"
          if fileExists(typePath) and fileExists(tempPath):
            try:
              let typeVal = readFile(typePath).strip()
              let tempVal = parseBiggestInt(readFile(tempPath).strip())
              if typeVal.len > 0:
                if temps.hasKey(typeVal):
                  temps[typeVal] = temps[typeVal] + tempVal
                else:
                  temps[typeVal] = tempVal
            except:
              discard
  except:
    debug("Error reading temperature")
  
  return temps

# Main metric collection loop
proc collectMetrics(): tuple[
  metrics: MetricSample,
  networkStats: NetworkStats,
  networkInterfaces: seq[string],
  connectionCounts: Table[string, int],
  temperatureReadings: Table[string, int64],
  sampleCount: int
] =
  let runTimes = int(60 div config.CollectEveryXSeconds)
  let startMinute = now().minute
  
  debug(fmt"Collecting data for {runTimes} loops")

  # Initialize accumulators
  var totalCPU, totalCPUwa, totalCPUst, totalCPUus, totalCPUsy: float = 0.0
  var totalRAM, totalRAMSwap, totalRAMBuff, totalRAMCache: float = 0.0
  var totalLoad1, totalLoad5, totalLoad15: float = 0.0
  var networkStats = initTable[string, tuple[rx: int64, tx: int64]]()
  var connectionCounts = initTable[string, int]()
  var temperatureReadings = initTable[string, int64]()
  var sampleCount = 0

  # Get network interfaces
  let networkInterfaces = getNetworkInterfaces()
  debug(fmt"Network Interfaces: {networkInterfaces.join(\", \")}")

  # Initialize network accumulators
  for iface in networkInterfaces:
    networkStats[iface] = (rx: 0'i64, tx: 0'i64)

  # Get ports
  var ports: seq[string] = @[]
  if config.ConnectionPorts.len > 0:
    ports = config.ConnectionPorts.split(',').mapIt(it.strip())
  else:
    # Auto-detect
    try:
      let portList = execCommand("ss -Htnl 2>/dev/null | awk '{print $4}' | grep -E ':[0-9]+$' | sed -E 's/.*:([0-9]+)$/\\1/' | sort -n | uniq | head -30")
      if portList.len > 0:
        ports = portList.splitLines().filterIt(it.len > 0)
    except:
      debug("Error detecting ports")

  if ports.len > 0:
    debug(fmt"Monitoring ports: {ports.join(\", \")}")
    for port in ports:
      connectionCounts[port] = 0

  # Initial stats
  var prevNetStats = getNetworkStats(networkInterfaces)
  var prevTime = epochTime()

  # Sampling loop
  for i in 0..<runTimes:
    try:
      # Get vmstat data
      let vmstat = execCommand(fmt"vmstat {config.CollectEveryXSeconds} 2 | tail -1")
      if vmstat.len == 0:
        continue

      let vmstatParts = vmstat.strip().split()
      if vmstatParts.len < 17:
        continue

      # CPU metrics
      let idleCPU = parseFloat(vmstatParts[14])
      let cpu = 100.0 - idleCPU
      let cpuwa = parseFloat(vmstatParts[15])
      let cpust = parseFloat(vmstatParts[16])
      let cpuus = parseFloat(vmstatParts[12])
      let cpusy = parseFloat(vmstatParts[13])

      totalCPU += cpu
      totalCPUwa += cpuwa
      totalCPUst += cpust
      totalCPUus += cpuus
      totalCPUsy += cpusy

      # Memory metrics
      let meminfo = readFile("/proc/meminfo")
      var memTotal, swapTotal: int64 = 0
      for line in meminfo.splitLines():
        if line.startsWith("MemTotal:"):
          discard parseInt(line.split()[1], memTotal)
        elif line.startsWith("SwapTotal:"):
          discard parseInt(line.split()[1], swapTotal)

      let memFree = parseBiggestInt(vmstatParts[3])
      let memBuff = parseBiggestInt(vmstatParts[4])
      let memCache = parseBiggestInt(vmstatParts[5])

      if memTotal > 0:
        let memUsed = 100.0 - (float(memFree + memBuff + memCache) * 100.0 / float(memTotal))
        totalRAM += memUsed
        totalRAMBuff += (float(memBuff) * 100.0 / float(memTotal))
        totalRAMCache += (float(memCache) * 100.0 / float(memTotal))

      # Swap
      let swapUsed = parseBiggestInt(vmstatParts[2])
      if swapTotal > 0:
        totalRAMSwap += (float(swapUsed) * 100.0 / float(swapTotal))

      # Load average
      let loadavg = readFile("/proc/loadavg").split()
      totalLoad1 += parseFloat(loadavg[0])
      totalLoad5 += parseFloat(loadavg[1])
      totalLoad15 += parseFloat(loadavg[2])

      # Network stats
      let currentTime = epochTime()
      let timeDiff = currentTime - prevTime
      if timeDiff > 0:
        let currentNetStats = getNetworkStats(networkInterfaces)
        for iface in networkInterfaces:
          if currentNetStats.hasKey(iface) and prevNetStats.hasKey(iface):
            let rxDelta = currentNetStats[iface].rx - prevNetStats[iface].rx
            let txDelta = currentNetStats[iface].tx - prevNetStats[iface].tx
            networkStats[iface] = (
              rx: networkStats[iface].rx + int64(float(rxDelta) / timeDiff),
              tx: networkStats[iface].tx + int64(float(txDelta) / timeDiff)
            )
        prevNetStats = currentNetStats
        prevTime = currentTime

      # Port connections
      if ports.len > 0:
        try:
          let connections = execCommand("ss -ntu | awk '{print $5}'")
          for port in ports:
            var count = 0
            for line in connections.splitLines():
              if line.endsWith(":" & port):
                inc count
            connectionCounts[port] = connectionCounts[port] + count
        except:
          debug("Error counting connections")

      # Temperature
      let temps = getCPUTemperature()
      for sensor, value in temps:
        if temperatureReadings.hasKey(sensor):
          temperatureReadings[sensor] = temperatureReadings[sensor] + value
        else:
          temperatureReadings[sensor] = value

      inc sampleCount

      # Check if minute changed
      if now().minute != startMinute:
        debug("Minute changed, ending loop")
        break

    except:
      debug("Error in sampling loop")

  if sampleCount == 0:
    sampleCount = 1

  debug(fmt"Completed {sampleCount} samples")

  # Calculate averages
  let avgMetrics = MetricSample(
    cpu: totalCPU / float(sampleCount),
    cpuwa: totalCPUwa / float(sampleCount),
    cpust: totalCPUst / float(sampleCount),
    cpuus: totalCPUus / float(sampleCount),
    cpusy: totalCPUsy / float(sampleCount),
    ram: totalRAM / float(sampleCount),
    ramswap: totalRAMSwap / float(sampleCount),
    rambuff: totalRAMBuff / float(sampleCount),
    ramcache: totalRAMCache / float(sampleCount),
    load1: totalLoad1 / float(sampleCount),
    load5: totalLoad5 / float(sampleCount),
    load15: totalLoad15 / float(sampleCount)
  )

  # Average network stats
  for iface in networkInterfaces:
    if networkStats.hasKey(iface):
      networkStats[iface] = (
        rx: networkStats[iface].rx div sampleCount,
        tx: networkStats[iface].tx div sampleCount
      )

  # Average connection counts
  for port in ports:
    if connectionCounts.hasKey(port):
      connectionCounts[port] = connectionCounts[port] div sampleCount

  return (avgMetrics, networkStats, networkInterfaces, connectionCounts, temperatureReadings, sampleCount)

# Get system information
proc getSystemInfo(): JsonNode =
  var info = newJObject()
  
  # User
  info["user"] = %getCurrentDir().split('/')[^1] # Simplified
  try:
    info["user"] = %execCommand("whoami")
  except:
    discard

  # Hostname
  let hostname = execCommand("hostname")
  info["hostname"] = %encode(hostname)

  # Uptime
  try:
    let uptime = readFile("/proc/uptime").split()[0]
    info["uptime"] = %int(parseFloat(uptime))
  except:
    info["uptime"] = %0

  # CPU info
  try:
    let cpuinfo = readFile("/proc/cpuinfo")
    var cpuModel = "Unknown"
    var cpuCores = 0
    
    for line in cpuinfo.splitLines():
      if line.startsWith("model name"):
        cpuModel = line.split(':')[1].strip()
      elif line.startsWith("processor"):
        inc cpuCores
    
    info["cpumodel"] = %encode(cpuModel)
    info["cpucores"] = %cpuCores
    info["cputhreads"] = %1
    info["cpusockets"] = %1
    
    # Try to get socket count
    let sockets = execCommand("grep -i 'physical id' /proc/cpuinfo | sort -u | wc -l")
    if sockets.len > 0:
      info["cpusockets"] = %parseInt(sockets)
  except:
    info["cpumodel"] = %encode("Unknown")
    info["cpucores"] = %1
    info["cputhreads"] = %1
    info["cpusockets"] = %1

  # RAM
  try:
    let meminfo = readFile("/proc/meminfo")
    var memTotal, swapTotal: int64 = 0
    for line in meminfo.splitLines():
      if line.startsWith("MemTotal:"):
        discard parseInt(line.split()[1], memTotal)
      elif line.startsWith("SwapTotal:"):
        discard parseInt(line.split()[1], swapTotal)
    
    info["ramsize"] = %memTotal
    info["ramswapsize"] = %swapTotal
  except:
    info["ramsize"] = %0
    info["ramswapsize"] = %0

  # OS
  var osInfo = "Linux"
  try:
    osInfo = execCommand("lsb_release -s -d")
    if osInfo.len == 0:
      osInfo = execCommand("cat /etc/redhat-release")
    if osInfo.len == 0:
      osInfo = execCommand("grep '^PRETTY_NAME=' /etc/os-release | cut -d'\"' -f2")
  except:
    discard
  info["os"] = %encode(osInfo)

  # Kernel
  try:
    let kernel = execCommand("uname -r")
    info["kernel"] = %encode(kernel)
  except:
    info["kernel"] = %encode("Unknown")

  # Reboot required
  info["reqreboot"] = %ord(fileExists("/var/run/reboot-required"))

  return info

# Get disk information
proc getDiskInfo(): tuple[disks: string, inodes: string] =
  var disks: seq[string] = @[]
  var inodes: seq[string] = @[]
  
  try:
    let dfOutput = execCommand("df -TPB1 2>/dev/null || df -l -TPB1 2>/dev/null", 5000)
    if dfOutput.len > 0:
      let lines = dfOutput.splitLines()[1..^1] # Skip header
      for line in lines:
        let parts = line.strip().split()
        if parts.len >= 7 and "tmpfs" notin parts[1]:
          let mountPoint = parts[^1]
          let fsType = parts[1]
          let total = parts[2]
          let used = parts[3]
          let available = parts[4]
          disks.add(fmt"{mountPoint},{fsType},{total},{used},{available};")

    let dfInodesOutput = execCommand("df -Ti 2>/dev/null || df -l -Ti 2>/dev/null", 5000)
    if dfInodesOutput.len > 0:
      let lines = dfInodesOutput.splitLines()[1..^1]
      for line in lines:
        let parts = line.strip().split()
        if parts.len >= 7 and "tmpfs" notin parts[1]:
          let mountPoint = parts[^1]
          let fsType = parts[1]
          let inodesTotal = parts[2]
          let inodesUsed = parts[3]
          inodes.add(fmt"{mountPoint},{fsType},{inodesTotal},{inodesUsed};")
  except:
    debug("Error getting disk info")

  return (encode(disks.join("")), encode(inodes.join("")))

# Get service status
proc getServicesStatus(): string =
  var services: seq[string] = @[]
  
  if config.CheckServices.len > 0:
    let serviceList = config.CheckServices.split(',').mapIt(it.strip())[0..<min(10, config.CheckServices.split(',').len)]
    for service in serviceList:
      let status = checkServiceStatus(service)
      services.add(fmt"{service},{status};")
      debug(fmt"Service {service} status: {status}")

  return encode(services.join(""))

# Main execution
proc main() =
  try:
    scriptPath = getAppDir()
    scriptStartTime = now()
    config = loadConfig()
    debugEnabled = config.DEBUG == 1

    debug(fmt"Starting HetrixTools Agent v{VERSION}")
    debug("Starting data collection")

    # Start ping tests (simplified - sequential for Nim version)
    var pingResults: seq[string] = @[]
    if config.OutgoingPings.len > 0:
      let pingTargets = config.OutgoingPings.split('|')
      for target in pingTargets:
        let parts = target.split(',')
        if parts.len >= 2:
          let name = parts[0].strip()
          let ip = parts[1].strip()
          if name.len > 0 and ip.len > 0:
            pingResults.add(performPingTest(name, ip, config.OutgoingPingsCount))

    # Collect metrics
    let (metrics, networkStats, networkInterfaces, connectionCounts, temperatureReadings, sampleCount) = collectMetrics()

    # Get system information
    let sysInfo = getSystemInfo()

    # Get disk information
    let diskInfo = getDiskInfo()

    # Get service status
    let servicesStatus = getServicesStatus()

    # Build network info
    var nics: seq[string] = @[]
    var ipv4: seq[string] = @[]
    var ipv6: seq[string] = @[]
    
    for iface in networkInterfaces:
      if networkStats.hasKey(iface):
        let stats = networkStats[iface]
        nics.add(fmt"{iface},{stats.rx},{stats.tx};")
        
        # Get IP addresses
        try:
          let ipv4Addrs = execCommand(fmt"ip -4 addr show {iface} | grep -oP 'inet \\K[\\d.]+'")
          if ipv4Addrs.len > 0:
            ipv4.add(fmt"{iface},{ipv4Addrs.replace(\"\n\", \",\")};")
          
          let ipv6Addrs = execCommand(fmt"ip -6 addr show {iface} | grep -w 'global' | grep -oP 'inet6 \\K[0-9a-fA-F:]+'")
          if ipv6Addrs.len > 0:
            ipv6.add(fmt"{iface},{ipv6Addrs.replace(\"\n\", \",\")};")
        except:
          debug(fmt"Error getting IPs for {iface}")

    # Build connection info
    var conn: seq[string] = @[]
    for port, count in connectionCounts:
      conn.add(fmt"{port},{count};")

    # Build temperature info
    var temp: seq[string] = @[]
    for sensor, value in temperatureReadings:
      let avgValue = value div sampleCount
      temp.add(fmt"{sensor},{avgValue};")

    # Ping results
    let oping = pingResults.filterIt(it.len > 0).join("")

    # Custom variables
    var customVars = ""
    if config.CustomVars.len > 0:
      try:
        let customPath = scriptPath / config.CustomVars
        if fileExists(customPath):
          customVars = readFile(customPath)
      except:
        debug("Error reading custom variables")

    # Running processes
    var rps2 = ""
    if config.RunningProcesses == 1:
      try:
        let processes = execCommand("ps -Ao pid,ppid,uid,user:20,pcpu,pmem,cputime,etime,comm,cmd --no-headers", 5000)
        rps2 = encode(processes)
      except:
        debug("Error getting processes")

    # Construct JSON payload
    let currentTime = encode(now().format("yyyy-MM-dd HH:mm:ss UTC"))
    
    var payload = newJObject()
    payload["version"] = %VERSION
    payload["SID"] = %config.SID
    payload["agent"] = %"0"
    payload["user"] = sysInfo["user"]
    payload["os"] = sysInfo["os"]
    payload["kernel"] = sysInfo["kernel"]
    payload["hostname"] = sysInfo["hostname"]
    payload["time"] = %currentTime
    payload["reqreboot"] = sysInfo["reqreboot"]
    payload["uptime"] = sysInfo["uptime"]
    payload["cpumodel"] = sysInfo["cpumodel"]
    payload["cpusockets"] = sysInfo["cpusockets"]
    payload["cpucores"] = sysInfo["cpucores"]
    payload["cputhreads"] = sysInfo["cputhreads"]
    payload["cpuspeed"] = %"0"
    payload["cpu"] = %fmt"{metrics.cpu:.2f}"
    payload["wa"] = %fmt"{metrics.cpuwa:.2f}"
    payload["st"] = %fmt"{metrics.cpust:.2f}"
    payload["us"] = %fmt"{metrics.cpuus:.2f}"
    payload["sy"] = %fmt"{metrics.cpusy:.2f}"
    payload["load1"] = %fmt"{metrics.load1:.2f}"
    payload["load5"] = %fmt"{metrics.load5:.2f}"
    payload["load15"] = %fmt"{metrics.load15:.2f}"
    payload["ramsize"] = sysInfo["ramsize"]
    payload["ram"] = %fmt"{metrics.ram:.2f}"
    payload["ramswapsize"] = sysInfo["ramswapsize"]
    payload["ramswap"] = %fmt"{metrics.ramswap:.2f}"
    payload["rambuff"] = %fmt"{metrics.rambuff:.2f}"
    payload["ramcache"] = %fmt"{metrics.ramcache:.2f}"
    payload["disks"] = %diskInfo.disks
    payload["inodes"] = %diskInfo.inodes
    payload["iops"] = %""
    payload["raid"] = %""
    payload["zp"] = %""
    payload["dh"] = %""
    payload["nics"] = %encode(nics.join(""))
    payload["ipv4"] = %encode(ipv4.join(""))
    payload["ipv6"] = %encode(ipv6.join(""))
    payload["conn"] = %encode(conn.join(""))
    payload["temp"] = %encode(temp.join(""))
    payload["serv"] = %servicesStatus
    payload["cust"] = %(if customVars.len > 0: encode(customVars) else: "")
    payload["oping"] = %(if oping.len > 0: encode(oping) else: "")
    payload["rps1"] = %""
    payload["rps2"] = %rps2

    let jsonStr = $payload
    debug(fmt"JSON payload size: {jsonStr.len} bytes")

    # Compress and encode
    import std/zlib
    let compressed = compress(jsonStr, stream=GZIP_STREAM)
    var encoded = encode(compressed)
    encoded = encoded.replace("/", "%2F").replace("+", "%2B")

    let postData = "j=" & encoded

    # Save to log file
    let logFile = scriptPath / "hetrixtools_agent.log"
    writeFile(logFile, postData)

    debug("Posting data to HetrixTools")

    # Send data
    let client = newHttpClient()
    if config.SecuredConnection == 0:
      client.headers = newHttpHeaders({"Content-Type": "application/x-www-form-urlencoded"})
    else:
      client.headers = newHttpHeaders({"Content-Type": "application/x-www-form-urlencoded"})
    
    try:
      let response = client.postContent("https://sm.hetrixtools.net/v2/", body=postData)
      debug(fmt"Response received")
      if config.DEBUG == 1 and response.len > 0:
        debug(fmt"Response: {response}")
    except:
      debug(fmt"Error posting data: {getCurrentExceptionMsg()}")
    finally:
      client.close()

    debug("Data posted successfully")

  except:
    echo "Fatal error: ", getCurrentExceptionMsg()
    debug(fmt"Fatal error: {getCurrentExceptionMsg()}")
    quit(1)

when isMainModule:
  main()
