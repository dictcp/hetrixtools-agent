import std/[algorithm, asyncdispatch, base64, httpclient, json, monotimes, net, os, osproc, parsecfg, parseopt, strformat, streams, strutils, tables, times, uri]

when defined(posix):
  {.passL: "-lz".}
  proc mkstemp(pathTemplate: cstring): cint {.importc, header: "<stdlib.h>".}
  proc close(fd: cint): cint {.importc, header: "<unistd.h>".}
  proc c_time(t: ptr clong): clong {.importc: "time", header: "<time.h>".}
  proc c_localtime(t: ptr clong): pointer {.importc: "localtime", header: "<time.h>".}
  proc c_strftime(buf: cstring, size: csize_t, fmt: cstring, tm: pointer): csize_t {.importc: "strftime", header: "<time.h>".}

  proc tzAbbr(): string =
    var t: clong = 0
    discard c_time(addr t)
    let tm_ptr = c_localtime(addr t)
    var buf = newString(64)
    let n = c_strftime(cstring(buf), csize_t(64), "%Z", tm_ptr)
    result = buf[0 ..< n]

const
  Version {.strdefine.} = "trunk"
  ProtocolVersion = "2.4.0"
  DefaultConfigPath = "/etc/hetrixtools/hetrixtools.cfg"
  TimeoutMs = 5000

type
  AgentConfig = object
    sid: string
    networkInterfaces: string
    checkServices: string
    checkSoftRaid: int
    deduplicateZfsDatasets: int
    checkDriveHealth: int
    runningProcesses: int
    connectionPorts: string
    customVars: string
    securedConnection: int
    collectEveryXSeconds: int
    debug: int
    outgoingPings: string
    outgoingPingsCount: int

  StatSample = object
    cpu: float
    wa: float
    st: float
    us: float
    sy: float
    ram: float
    ramSwap: float
    ramBuff: float
    ramCache: float
    load1: float
    load5: float
    load15: float
    iops: string
    temp: string
    nicRx: Table[string, float]
    nicTx: Table[string, float]

proc cmdOut(command: string): string =
  try:
    result = execProcess(command, options = {poUsePath, poEvalCommand}).strip()
  except CatchableError:
    result = ""

proc cmdOutPreserveLeading(command: string): string =
  try:
    result = execProcess(command, options = {poUsePath, poEvalCommand}).strip(
      leading = false,
      trailing = true
    )
  except CatchableError:
    result = ""

proc parseIntSafe(s: string, d: int = 0): int =
  try:
    result = parseInt(s.strip())
  except ValueError:
    result = d

proc parseFloatSafe(s: string, d: float = 0.0): float =
  try:
    result = parseFloat(s.strip())
  except ValueError:
    result = d

proc parseInt64Safe(s: string, d: int64 = 0'i64): int64 =
  try:
    result = int64(parseBiggestInt(s.strip()))
  except ValueError:
    result = d

proc nowB64(): string =
  encode(now().format("yyyy-MM-dd HH:mm:ss") & " " & tzAbbr() & "\n").replace("\n", "")

proc createShmLogPath(): string =
  when defined(posix):
    if not dirExists("/dev/shm"):
      raise newException(IOError, "/dev/shm is not available on this system")

    result = "/dev/shm/hetrixtools_agent.XXXXXX"
    result.add('\0')
    let fd = mkstemp(result.cstring)
    if fd < 0:
      raise newException(IOError, "Unable to create temporary log file in /dev/shm")
    discard close(fd)
    result.setLen(result.len - 1)
  else:
    raise newException(IOError, "--log-shm requires a POSIX platform")

proc parseCfg(path: string): AgentConfig =
  var p: Config
  p = loadConfig(path)
  result.sid = p.getSectionValue("", "SID", "")
  result.networkInterfaces = p.getSectionValue("", "NetworkInterfaces", "")
  result.checkServices = p.getSectionValue("", "CheckServices", "")
  result.checkSoftRaid = parseIntSafe(p.getSectionValue("", "CheckSoftRAID", "0"))
  let deduplicateZfsDatasets = parseIntSafe(
    p.getSectionValue("", "DeduplicateZFSDatasets", "1"),
    1
  )
  result.deduplicateZfsDatasets = if deduplicateZfsDatasets == 0: 0 else: 1
  result.checkDriveHealth = parseIntSafe(p.getSectionValue("", "CheckDriveHealth", "0"))
  result.runningProcesses = parseIntSafe(p.getSectionValue("", "RunningProcesses", "0"))
  result.connectionPorts = p.getSectionValue("", "ConnectionPorts", "")
  result.customVars = p.getSectionValue("", "CustomVars", "custom_variables.json")
  result.securedConnection = parseIntSafe(p.getSectionValue("", "SecuredConnection", "1"), 1)
  result.collectEveryXSeconds = parseIntSafe(p.getSectionValue("", "CollectEveryXSeconds", "3"), 3)
  if result.collectEveryXSeconds < 1:
    result.collectEveryXSeconds = 3
  result.debug = parseIntSafe(p.getSectionValue("", "DEBUG", "0"))
  result.outgoingPings = p.getSectionValue("", "OutgoingPings", "")
  result.outgoingPingsCount = parseIntSafe(p.getSectionValue("", "OutgoingPingsCount", "20"), 20)

proc readLinesSafe(path: string): seq[string] =
  if not fileExists(path):
    return @[]
  result = readFile(path).splitLines()

proc kvFromFile(path: string, sep: string = ":"): Table[string, string] =
  result = initTable[string, string]()
  for ln in readLinesSafe(path):
    if ln.contains(sep):
      let p = ln.split(sep, maxsplit = 1)
      if p.len == 2:
        result[p[0].strip()] = p[1].strip()

proc getMemInfo(): Table[string, int64] =
  result = initTable[string, int64]()
  for ln in readLinesSafe("/proc/meminfo"):
    let parts = ln.splitWhitespace()
    if parts.len >= 2:
      let key = parts[0].replace(":", "")
      result[key] = int64(parseIntSafe(parts[1]))

proc getLoad(): tuple[l1: float, l5: float, l15: float] =
  let parts = readFile("/proc/loadavg").splitWhitespace()
  if parts.len >= 3:
    return (parseFloatSafe(parts[0]), parseFloatSafe(parts[1]), parseFloatSafe(parts[2]))
  (0.0, 0.0, 0.0)

proc readCpuStat(): array[8, int64] =
  let lns = readLinesSafe("/proc/stat")
  for ln in lns:
    if ln.startsWith("cpu "):
      let p = ln.splitWhitespace()
      if p.len >= 8:
        for i in 1..8:
          result[i - 1] = int64(parseIntSafe(p[i]))
      return

proc cpuFromDelta(a, b: array[8, int64]): tuple[cpu, wa, st, us, sy: float] =
  let
    user = (b[0] + b[1]) - (a[0] + a[1])
    system = b[2] - a[2]
    idle = b[3] - a[3]
    iowait = b[4] - a[4]
    steal = b[7] - a[7]
    total = (user + system + idle + iowait + (b[5]-a[5]) + (b[6]-a[6]) + steal).float
  if total <= 0:
    return (0.0, 0.0, 0.0, 0.0, 0.0)
  let
    us = user.float * 100.0 / total
    sy = system.float * 100.0 / total
    wa = iowait.float * 100.0 / total
    st = steal.float * 100.0 / total
  (100.0 - (idle.float * 100.0 / total), wa, st, us, sy)

proc readNetCounters(): Table[string, tuple[rx, tx: int64]] =
  result = initTable[string, tuple[rx, tx: int64]]()
  for ln in readLinesSafe("/proc/net/dev"):
    if not ln.contains(":"):
      continue
    let p = ln.split(":")
    if p.len != 2:
      continue
    let iface = p[0].strip()
    let vals = p[1].splitWhitespace()
    if vals.len >= 10:
      result[iface] = (int64(parseIntSafe(vals[0])), int64(parseIntSafe(vals[8])))

proc splitCsv(s: string): seq[string] =
  for part in s.split(","):
    let v = part.strip()
    if v.len > 0:
      result.add(v)

proc detectNics(cfgNics: string): seq[string] =
  if cfgNics.strip().len > 0:
    return splitCsv(cfgNics)
  let all = readNetCounters()
  for nic in all.keys:
    if nic != "lo":
      result.add(nic)

proc getOsPretty(): string =
  for ln in readLinesSafe("/etc/os-release"):
    if ln.startsWith("PRETTY_NAME="):
      return ln.split("=", maxsplit = 1)[1].strip(chars = {'"', '\''})
  let output = cmdOut("uname -s")
  if output.len > 0: output else: "Linux"

proc getUptimeSeconds(): int64 =
  let up = readFile("/proc/uptime").splitWhitespace()
  if up.len > 0:
    return int64(parseIntSafe(up[0].split(".")[0]))
  0'i64

proc getCpuModel(): string =
  for ln in readLinesSafe("/proc/cpuinfo"):
    if ln.startsWith("model name"):
      return ln.split(":", maxsplit = 1)[1].strip()
  # Fallback to lscpu
  cmdOut("lscpu | awk -F': ' '/Model name/ {print $2; exit}'")

proc getCpuCores(): int =
  var c = 0
  for ln in readLinesSafe("/proc/cpuinfo"):
    if ln.startsWith("processor"):
      inc c
  if c == 0: 1 else: c

proc getCpuThreads(): int =
  let output = cmdOut("lscpu | awk -F': ' '/Thread\\(s\\) per core/ {print $2; exit}'")
  let v = parseIntSafe(output, 1)
  if v < 1: 1 else: v

proc getCpuSockets(): int =
  let output = cmdOut("grep -i 'physical id' /proc/cpuinfo | sort -u | wc -l")
  let v = parseIntSafe(output, 1)
  if v < 1: 1 else: v

proc getCpuSpeed(): int =
  let output = cmdOut("grep -m1 'cpu MHz' /proc/cpuinfo | awk -F': ' '{print $2}'")
  int(parseFloatSafe(output, 0.0))

type
  ZfsPoolUsage* = object
    total*: int64
    used*: int64
    available*: int64

  ZfsData* = object
    usageByMount*: Table[string, ZfsPoolUsage]
    canonicalFilesystems*: Table[string, bool]
    duplicateFilesystems*: Table[string, bool]
    healthBase64*: string

  ZfsMount = tuple[filesystem: string, mountpoint: string]

proc findZfsMounts(dfOutput, pool: string): seq[ZfsMount] =
  for ln in dfOutput.splitLines():
    let fields = ln.splitWhitespace()
    if fields.len >= 7 and (fields[0] == pool or fields[0].startsWith(pool & "/")):
      result.add((filesystem: fields[0], mountpoint: fields[^1]))

proc selectCanonicalZfsMount(mounts: seq[ZfsMount], pool: string): ZfsMount =
  for mount in mounts:
    if mount.filesystem == pool:
      return mount

  var bestDepth = high(int)
  for mount in mounts:
    let depth = mount.filesystem.count('/')
    if depth < bestDepth:
      result = mount
      bestDepth = depth

proc collectZfsData*(
  checkSoftRaid: int,
  deduplicateZfsDatasets: int = 1
): ZfsData =
  result.usageByMount = initTable[string, ZfsPoolUsage]()
  result.canonicalFilesystems = initTable[string, bool]()
  result.duplicateFilesystems = initTable[string, bool]()
  if checkSoftRaid <= 0 or findExe("zpool").len == 0:
    return

  let overallStatus = cmdOutPreserveLeading("zpool status 2>/dev/null")
  if overallStatus.len == 0 or overallStatus.contains("no pools available"):
    return

  var pools: seq[string] = @[]
  for ln in overallStatus.splitLines():
    let fields = ln.strip().splitWhitespace()
    if fields.len >= 2 and fields[0] == "pool:" and fields[1] notin pools:
      pools.add(fields[1])

  let
    dfOutput = cmdOut("df -TPB1 2>/dev/null || df -l -TPB1 2>/dev/null")
    hasZfs = findExe("zfs").len > 0
  var healthEntries: seq[string] = @[]
  for pool in pools:
    let
      poolMounts = findZfsMounts(dfOutput, pool)
      canonicalMount = selectCanonicalZfsMount(poolMounts, pool)
      mountpoint = canonicalMount.mountpoint
      status = cmdOutPreserveLeading(fmt"zpool status {pool.quoteShell} 2>/dev/null")
    healthEntries.add(fmt"{mountpoint},{pool},{encode(status)};")

    if hasZfs and mountpoint.len > 0:
      let usageFields = cmdOut(
        fmt"zfs get -H -o value -p used,avail {pool.quoteShell} 2>/dev/null"
      ).splitWhitespace()
      if usageFields.len >= 2:
        let
          used = parseInt64Safe(usageFields[0], -1)
          available = parseInt64Safe(usageFields[1], -1)
        if used >= 0 and available >= 0:
          result.usageByMount[mountpoint] = ZfsPoolUsage(
            total: used + available,
            used: used,
            available: available
          )
          # Only suppress dataset rows after valid pool-level usage is
          # available. Otherwise retain every df row to avoid under-reporting.
          if deduplicateZfsDatasets > 0 and canonicalMount.filesystem.len > 0:
            result.canonicalFilesystems[canonicalMount.filesystem] = true
            for poolMount in poolMounts:
              if poolMount.filesystem != canonicalMount.filesystem:
                result.duplicateFilesystems[poolMount.filesystem] = true

  result.healthBase64 = encode(healthEntries.join(""))

proc getDiskUsageBase64*(
  zfsUsage: Table[string, ZfsPoolUsage],
  canonicalFilesystems: Table[string, bool],
  duplicateFilesystems: Table[string, bool]
): string =
  var entries: seq[string] = @[]
  var emittedCanonicalFilesystems = initTable[string, bool]()
  let output = cmdOut("df -TPB1 2>/dev/null || df -l -TPB1 2>/dev/null")
  for ln in output.splitLines():
    if ln.startsWith("Filesystem") or ln.contains(" tmpfs "):
      continue
    let p = ln.splitWhitespace()
    if p.len >= 7:
      let
        filesystem = p[0]
        mountpoint = p[^1]
      if duplicateFilesystems.hasKey(filesystem):
        continue
      if canonicalFilesystems.hasKey(filesystem):
        if emittedCanonicalFilesystems.hasKey(filesystem):
          continue
        emittedCanonicalFilesystems[filesystem] = true
      if zfsUsage.hasKey(mountpoint):
        let usage = zfsUsage[mountpoint]
        entries.add(fmt"{mountpoint},{p[1]},{usage.total},{usage.used},{usage.available};")
      else:
        entries.add(fmt"{mountpoint},{p[1]},{p[2]},{p[3]},{p[4]};")
  encode(entries.join(""))

proc getDiskUsageBase64*(zfsUsage: Table[string, ZfsPoolUsage]): string =
  getDiskUsageBase64(
    zfsUsage,
    initTable[string, bool](),
    initTable[string, bool]()
  )

proc getInodesBase64*(
  checkSoftRaid: int,
  canonicalFilesystems: Table[string, bool],
  duplicateFilesystems: Table[string, bool]
): string =
  var entries: seq[string] = @[]
  var emittedCanonicalFilesystems = initTable[string, bool]()
  let output = cmdOut("df -Ti 2>/dev/null || df -l -Ti 2>/dev/null")
  for ln in output.splitLines():
    if ln.startsWith("Filesystem") or ln.contains("tmpfs"):
      continue
    let p = ln.splitWhitespace()
    if p.len >= 7:
      let filesystem = p[0]
      # ZFS does not have a fixed ext4-style inode pool. When ZFS handling
      # is enabled, omit its df -Ti rows instead of reporting misleading
      # per-dataset inode values. This is independent of disk-row
      # deduplication and remains safe when zfs usage collection fails.
      if checkSoftRaid > 0 and p[1] == "zfs":
        continue
      if duplicateFilesystems.hasKey(filesystem):
        continue
      if canonicalFilesystems.hasKey(filesystem):
        if emittedCanonicalFilesystems.hasKey(filesystem):
          continue
        emittedCanonicalFilesystems[filesystem] = true
      entries.add(fmt"{p[^1]},{p[2]},{p[3]},{p[4]};")
  encode(entries.join(""))

proc getInodesBase64*(
  canonicalFilesystems: Table[string, bool],
  duplicateFilesystems: Table[string, bool]
): string =
  getInodesBase64(0, canonicalFilesystems, duplicateFilesystems)

type
  DiskMount = object
    mountpoint: string
    device: string

proc detectDiskMounts(): seq[DiskMount] =
  let output = cmdOut("df 2>/dev/null || df -l 2>/dev/null")
  for ln in output.splitLines():
    let p = ln.splitWhitespace()
    if p.len < 6:
      continue
    if p[0] == "Filesystem" or not p[0].contains("/"):
      continue
    let mountpoint = p[^1]
    let device = cmdOut(fmt"lsblk -l | grep -w {mountpoint.quoteShell} | awk '{{print $1; exit}}'")
    result.add(DiskMount(mountpoint: mountpoint, device: device))

proc readDiskstatsSectors(): Table[string, tuple[readSectors, writeSectors: int64]] =
  result = initTable[string, tuple[readSectors, writeSectors: int64]]()
  for ln in readLinesSafe("/proc/diskstats"):
    let p = ln.splitWhitespace()
    if p.len < 10:
      continue
    let dev = p[2]
    result[dev] = (int64(parseIntSafe(p[5])), int64(parseIntSafe(p[9])))

proc buildIopsBase64(
  mounts: seq[DiskMount],
  startStats, endStats: Table[string, tuple[readSectors, writeSectors: int64]],
  elapsedSeconds: int
): string =
  var entries: seq[string] = @[]
  let sec = max(1, elapsedSeconds)
  for m in mounts:
    var
      startRead = 0'i64
      startWrite = 0'i64
      endRead = 0'i64
      endWrite = 0'i64
    if m.device.len > 0:
      let startVals = startStats.getOrDefault(m.device, (0'i64, 0'i64))
      let endVals = endStats.getOrDefault(m.device, (0'i64, 0'i64))
      startRead = startVals.readSectors
      startWrite = startVals.writeSectors
      endRead = endVals.readSectors
      endWrite = endVals.writeSectors
    let readDelta = max(0'i64, endRead - startRead)
    let writeDelta = max(0'i64, endWrite - startWrite)
    let readBps = max(0'i64, (readDelta * 512'i64) div int64(sec))
    let writeBps = max(0'i64, (writeDelta * 512'i64) div int64(sec))
    entries.add(fmt"{m.mountpoint},{readBps},{writeBps};")
  encode(entries.join(""))

proc getIPv4Base64(nics: seq[string]): string =
  var entries: seq[string] = @[]
  for nic in nics:
    let ips = cmdOut(fmt"ip -4 addr show {nic} | awk '/inet / {{print $2}}' | cut -d/ -f1 | paste -sd, -")
    entries.add(fmt"{nic},{ips};")
  encode(entries.join(""))

proc getIPv6Base64(nics: seq[string]): string =
  var entries: seq[string] = @[]
  for nic in nics:
    let ips = cmdOut(fmt"ip -6 addr show {nic} | awk '/scope global/ {{print $2}}' | cut -d/ -f1 | paste -sd, -")
    entries.add(fmt"{nic},{ips};")
  encode(entries.join(""))

proc buildCustomVarsBase64(configPath: string, customVarsPath: string): string =
  if customVarsPath.len == 0:
    return ""
  let baseDir = parentDir(configPath)
  let target = joinPath(baseDir, customVarsPath)
  if fileExists(target):
    return encode(readFile(target))
  ""

proc sleepMs(ms: int) =
  if ms > 0:
    sleep(ms)

# ── Outgoing Ping support ────────────────────────────────────────────────────

type
  PingEntry = object
    name: string
    target: string
    port: int  # 0 = ICMP, >0 = TCP port

proc isValidPingName(s: string): bool =
  if s.len == 0: return false
  for c in s:
    if not (c.isAlphaAscii() or c.isDigit() or c == '.' or c == '-' or c == '_'):
      return false
  return true

proc isValidPingTarget(s: string): bool =
  if s.len == 0: return false
  for c in s:
    if not (c.isAlphaAscii() or c.isDigit() or c == '.' or c == ':' or c == '_' or c == '-'):
      return false
  return true

proc parseOutgoingPings(s: string): seq[PingEntry] =
  if s.len == 0: return @[]
  for raw in s.split("|"):
    let entry = raw.strip()
    if entry.len == 0: continue
    let parts = entry.split(",")
    if parts.len == 2:
      let name = parts[0].strip()
      let target = parts[1].strip()
      if isValidPingName(name) and isValidPingTarget(target):
        result.add(PingEntry(name: name, target: target, port: 0))
    elif parts.len == 3:
      let name = parts[0].strip()
      let target = parts[1].strip()
      let portStr = parts[2].strip()
      try:
        let port = parseInt(portStr)
        if port >= 1 and port <= 65535 and isValidPingName(name) and isValidPingTarget(target):
          result.add(PingEntry(name: name, target: target, port: port))
      except ValueError:
        discard

proc parseIcmpPacketLoss(output: string): int =
  for line in output.splitLines():
    let idx = line.find("% packet loss")
    if idx > 0:
      var numStart = idx - 1
      while numStart > 0 and line[numStart - 1].isDigit():
        dec numStart
      try:
        return parseInt(line[numStart ..< idx])
      except ValueError:
        discard
  return 100

proc parseIcmpAvgRtt(output: string): int =
  ## Parse average RTT in microseconds from ping output (Linux/BSD formats).
  ## ping reports ms; multiply by 1000 to match the shell agent's wire format,
  ## which the HetrixTools backend divides by 1000 to display as ms.
  for line in output.splitLines():
    if "min/avg/max" in line and "=" in line:
      let eqParts = line.split("=")
      if eqParts.len >= 2:
        let nums = eqParts[^1].strip().split("/")
        if nums.len >= 2:
          return int(parseFloatSafe(nums[1].strip()) * 1000.0 + 0.5)
  return 0

proc tcpProbeConnect(target: string, port, timeoutMs: int): (bool, int) =
  ## Attempt a TCP connection; returns (success, rttUs).
  ## Returns microseconds to match the shell agent's wire format.
  var sock: Socket
  try:
    sock = newSocket()
  except CatchableError:
    return (false, 0)
  let startTime = getMonoTime()
  try:
    sock.connect(target, Port(port), timeout = timeoutMs)
    sock.close()
    let elapsed = int((getMonoTime() - startTime).inMicroseconds)
    return (true, max(0, elapsed))
  except CatchableError:
    try: sock.close() except CatchableError: discard
    return (false, 0)

proc runTcpPing(entry: PingEntry, count: int): string =
  ## Probe a TCP port with multiple timed samples; returns "name,target_port,loss,avgRtt;".
  let sampleCount = max(2, min(8, (count + 4) div 5))
  let outputTarget = fmt"{entry.target}_{entry.port}"
  var successCount = 0
  var rttSum = 0
  for i in 1..sampleCount:
    let (ok, rtt) = tcpProbeConnect(entry.target, entry.port, 3000)
    if ok:
      inc successCount
      rttSum += rtt
    if i < sampleCount:
      # TODO: run TCP probes concurrently in threads (like ICMP uses background
      # processes) so this inter-sample delay overlaps with collectSamples instead
      # of adding to total wall-clock time.
      sleep(500)
  let packetLoss = int(
    ((sampleCount - successCount).float / sampleCount.float) * 100.0 + 0.5
  )
  let avgRtt = if successCount > 0: rttSum div successCount else: 0
  fmt"{entry.name},{outputTarget},{packetLoss},{avgRtt};"

# ─────────────────────────────────────────────────────────────────────────────

proc extractFirstFloat(s: string): string =
  var i = 0
  while i < s.len:
    if (s[i] == '+' or s[i] == '-') and i + 1 < s.len and s[i + 1].isDigit():
      var j = i + 1
      while j < s.len and s[j].isDigit(): inc j
      if j < s.len and s[j] == '.':
        inc j
        while j < s.len and s[j].isDigit(): inc j
      return s[i ..< j]
    elif s[i].isDigit():
      var j = i
      while j < s.len and s[j].isDigit(): inc j
      if j < s.len and s[j] == '.':
        inc j
        while j < s.len and s[j].isDigit(): inc j
      return s[i ..< j]
    inc i
  ""

proc collectThermalZoneTemp(tempSum: var Table[string, int64], tempCnt: var Table[string, int]) =
  for zone in walkDirs("/sys/class/thermal/thermal_zone*"):
    let typeFile = zone / "type"
    let tempFile = zone / "temp"
    if not fileExists(typeFile) or not fileExists(tempFile): continue
    let zoneName = try: readFile(typeFile).strip() except CatchableError: ""
    if zoneName.len == 0: continue
    let tempStr = try: readFile(tempFile).strip() except CatchableError: ""
    let tempVal = parseIntSafe(tempStr, -1)
    if tempVal >= 0:
      tempSum[zoneName] = tempSum.getOrDefault(zoneName, 0'i64) + int64(tempVal)
      tempCnt[zoneName] = tempCnt.getOrDefault(zoneName, 0) + 1

proc collectSensorsTemp(tempSum: var Table[string, int64], tempCnt: var Table[string, int]) =
  let sensorsOut = cmdOut("sensors -A 2>/dev/null")
  if sensorsOut.len == 0: return
  var category = ""
  var coreSum: int64 = 0
  var coreCnt = 0
  for line in sensorsOut.splitLines():
    let trimmed = line.strip()
    if trimmed.len == 0:
      continue
    if not trimmed.contains(':') and not trimmed.contains('='):
      category = trimmed
    elif trimmed.contains(':'):
      let parts = trimmed.split(':', maxsplit = 1)
      if parts.len < 2: continue
      let label = parts[0].strip().replace(" ", "_")
      let rawFloat = extractFirstFloat(parts[1])
      if rawFloat.len == 0: continue
      let tempMilli = int64(parseFloatSafe(rawFloat) * 1000.0 + 0.5)
      let sensorName = category & "|" & label
      tempSum[sensorName] = tempSum.getOrDefault(sensorName, 0'i64) + tempMilli
      tempCnt[sensorName] = tempCnt.getOrDefault(sensorName, 0) + 1
      if "|Core_" in sensorName:
        coreSum += tempMilli
        inc coreCnt
  if coreCnt > 0:
    let avgCore = coreSum div int64(coreCnt)
    tempSum["AllCoreAvg"] = tempSum.getOrDefault("AllCoreAvg", 0'i64) + avgCore
    tempCnt["AllCoreAvg"] = tempCnt.getOrDefault("AllCoreAvg", 0) + 1

proc collectIpmiTemp(tempSum: var Table[string, int64], tempCnt: var Table[string, int]) =
  if findExe("ipmitool") == "": return
  let ipmiOut = cmdOut("timeout -s 9 5 ipmitool sdr type Temperature 2>/dev/null")
  if ipmiOut.len == 0: return
  for line in ipmiOut.splitLines():
    if "degrees" notin line: continue
    let fields = line.split('|')
    if fields.len < 2: continue
    let sensorName = fields[0].strip().replace(" ", "_")
    let lastField = fields[^1]
    let degIdx = lastField.find("degrees")
    if degIdx < 0: continue
    let rawFloat = extractFirstFloat(lastField[0 ..< degIdx])
    if rawFloat.len == 0: continue
    let tempMilli = int64(parseFloatSafe(rawFloat) * 1000.0 + 0.5)
    tempSum[sensorName] = tempSum.getOrDefault(sensorName, 0'i64) + tempMilli
    tempCnt[sensorName] = tempCnt.getOrDefault(sensorName, 0) + 1

proc buildTempBase64(tempSum: Table[string, int64], tempCnt: Table[string, int]): string =
  if tempSum.len == 0: return ""
  var parts: seq[string] = @[]
  for name, total in tempSum:
    let cnt = tempCnt.getOrDefault(name, 1)
    let avg = int64(float(total) / float(max(1, cnt)) + 0.5)
    parts.add(fmt"{name},{avg};")
  encode(parts.join(""))

proc collectSamples(cfg: AgentConfig, nics: seq[string]): StatSample =
  var
    iterations = max(1, 60 div cfg.collectEveryXSeconds)
    totalCpu = 0.0
    totalWa = 0.0
    totalSt = 0.0
    totalUs = 0.0
    totalSy = 0.0
    totalRam = 0.0
    totalRamSwap = 0.0
    totalBuff = 0.0
    totalCache = 0.0
    totalL1 = 0.0
    totalL5 = 0.0
    totalL15 = 0.0
    diskMounts = detectDiskMounts()
    diskStartStats = readDiskstatsSectors()
    tempSum = initTable[string, int64]()
    tempCnt = initTable[string, int]()
  result.nicRx = initTable[string, float]()
  result.nicTx = initTable[string, float]()
  for nic in nics:
    result.nicRx[nic] = 0
    result.nicTx[nic] = 0

  for _ in 0..<iterations:
    let cpuA = readCpuStat()
    let netA = readNetCounters()
    sleepMs(cfg.collectEveryXSeconds * 1000)
    let cpuB = readCpuStat()
    let netB = readNetCounters()
    let cpu = cpuFromDelta(cpuA, cpuB)
    totalCpu += cpu.cpu
    totalWa += cpu.wa
    totalSt += cpu.st
    totalUs += cpu.us
    totalSy += cpu.sy
    let mem = getMemInfo()
    let totalMem = max(1'i64, mem.getOrDefault("MemTotal", 1))
    let freeMem = mem.getOrDefault("MemFree", 0)
    let buffMem = mem.getOrDefault("Buffers", 0)
    let cacheMem = mem.getOrDefault("Cached", 0)
    let swapTotal = mem.getOrDefault("SwapTotal", 0)
    let swapFree = mem.getOrDefault("SwapFree", 0)
    let usedPct = ((totalMem - freeMem - buffMem - cacheMem).float * 100.0 / totalMem.float)
    totalRam += max(0.0, min(100.0, usedPct))
    totalBuff += (buffMem.float * 100.0 / totalMem.float)
    totalCache += (cacheMem.float * 100.0 / totalMem.float)
    if swapTotal > 0:
      totalRamSwap += ((swapTotal - swapFree).float * 100.0 / swapTotal.float)
    let l = getLoad()
    totalL1 += l.l1
    totalL5 += l.l5
    totalL15 += l.l15

    for nic in nics:
      if netA.hasKey(nic) and netB.hasKey(nic):
        let rxDelta = (netB[nic].rx - netA[nic].rx).float / cfg.collectEveryXSeconds.float
        let txDelta = (netB[nic].tx - netA[nic].tx).float / cfg.collectEveryXSeconds.float
        result.nicRx[nic] = result.nicRx[nic] + max(0.0, rxDelta)
        result.nicTx[nic] = result.nicTx[nic] + max(0.0, txDelta)

    collectThermalZoneTemp(tempSum, tempCnt)
    collectSensorsTemp(tempSum, tempCnt)

  result.cpu = totalCpu / iterations.float
  result.wa = totalWa / iterations.float
  result.st = totalSt / iterations.float
  result.us = totalUs / iterations.float
  result.sy = totalSy / iterations.float
  result.ram = totalRam / iterations.float
  result.ramSwap = totalRamSwap / iterations.float
  result.ramBuff = totalBuff / iterations.float
  result.ramCache = totalCache / iterations.float
  result.load1 = totalL1 / iterations.float
  result.load5 = totalL5 / iterations.float
  result.load15 = totalL15 / iterations.float
  let diskEndStats = readDiskstatsSectors()
  result.iops = buildIopsBase64(
    diskMounts,
    diskStartStats,
    diskEndStats,
    iterations * cfg.collectEveryXSeconds
  )
  for nic in nics:
    result.nicRx[nic] = result.nicRx[nic] / iterations.float
    result.nicTx[nic] = result.nicTx[nic] / iterations.float
  collectIpmiTemp(tempSum, tempCnt)
  # Synthesise cpu_thermal from thermal_zone0 when no confirmed CPU sensor
  # is present. "package" is intentionally excluded: package-thermal is not
  # recognised by the HetrixTools backend. cpu/core/tdie/tctl are.
  let hasCpuSensor = block:
    var found = false
    for name in tempSum.keys:
      if name.startsWith("cpu"):
        found = true
        break
    found
  if not hasCpuSensor:
    let zone0 = try: readFile("/sys/class/thermal/thermal_zone0/temp").strip()
                except CatchableError: ""
    let val = parseIntSafe(zone0, -1)
    if val >= 0:
      tempSum["cpu_thermal"] = int64(val)
      tempCnt["cpu_thermal"] = 1
  result.temp = buildTempBase64(tempSum, tempCnt)

proc buildNicsBase64(stats: StatSample, nics: seq[string]): string =
  var s = ""
  for nic in nics:
    s.add(fmt"{nic},{stats.nicRx.getOrDefault(nic, 0).int},{stats.nicTx.getOrDefault(nic, 0).int};")
  encode(s)

proc buildPayload(cfg: AgentConfig, configPath: string): JsonNode =
  let nics = detectNics(cfg.networkInterfaces)

  # Validate and clamp ping count (10–40, default 20)
  let pingCount =
    if cfg.outgoingPingsCount >= 10 and cfg.outgoingPingsCount <= 40:
      cfg.outgoingPingsCount
    else:
      20

  # Parse ping entries and launch ICMP probes as background processes before
  # collectSamples so they run concurrently with the ~60-second stats window.
  let pingEntries = parseOutgoingPings(cfg.outgoingPings)
  var icmpProcesses: seq[tuple[index: int, entry: PingEntry, process: Process]] = @[]
  var tcpEntries: seq[tuple[index: int, entry: PingEntry]] = @[]
  for index, entry in pingEntries:
    if entry.port == 0:
      try:
        let p = startProcess("ping", args = [entry.target, "-c", $pingCount],
                             options = {poUsePath})
        icmpProcesses.add((index: index, entry: entry, process: p))
      except CatchableError:
        discard
    else:
      tcpEntries.add((index: index, entry: entry))

  let
    stats = collectSamples(cfg, nics)
    zfs = collectZfsData(cfg.checkSoftRaid, cfg.deduplicateZfsDatasets)

  var
    tcpResults: seq[tuple[index: int, data: string]] = @[]
    icmpResults: seq[tuple[index: int, data: string]] = @[]

  # Run TCP port probes sequentially (after collection window).
  for item in tcpEntries:
    tcpResults.add((index: item.index, data: runTcpPing(item.entry, pingCount)))

  # Collect ICMP results (processes should have completed during stats collection).
  for item in icmpProcesses:
    discard item.process.waitForExit()
    let output = item.process.outputStream.readAll()
    item.process.close()
    icmpResults.add((
      index: item.index,
      data: fmt"{item.entry.name},{item.entry.target},{parseIcmpPacketLoss(output)},{parseIcmpAvgRtt(output)};"
    ))

  tcpResults.sort(proc(a, b: tuple[index: int, data: string]): int = cmp(a.index, b.index))
  icmpResults.sort(proc(a, b: tuple[index: int, data: string]): int = cmp(a.index, b.index))

  var pingData = ""
  for result in tcpResults:
    pingData.add(result.data)
  for result in icmpResults:
    pingData.add(result.data)

  let opingStr = if pingData.len > 0: encode(pingData) else: ""

  let
    osName = encode(getOsPretty())
    kernel = encode(cmdOut("uname -r") & "\n")
    hostname = encode(cmdOut("uname -n") & "\n")
    user = getEnv("USER", cmdOut("whoami"))
    uptime = $getUptimeSeconds()
    cpuModel = encode(getCpuModel())
    cpuSockets = $getCpuSockets()
    cpuCores = $getCpuCores()
    cpuThreads = $getCpuThreads()
    cpuSpeed = $getCpuSpeed()
    mem = getMemInfo()
    ramSize = $mem.getOrDefault("MemTotal", 0)
    ramSwapSize = $mem.getOrDefault("SwapTotal", 0)
    customVars = buildCustomVarsBase64(configPath, cfg.customVars)

  result = %*{
    "version": ProtocolVersion,
    "SID": cfg.sid,
    "agent": "0",
    "user": user,
    "os": osName,
    "kernel": kernel,
    "hostname": hostname,
    "time": nowB64(),
    "reqreboot": (if fileExists("/var/run/reboot-required"): "1" else: "0"),
    "uptime": uptime,
    "cpumodel": cpuModel,
    "cpusockets": cpuSockets,
    "cpucores": cpuCores,
    "cputhreads": cpuThreads,
    "cpuspeed": cpuSpeed,
    "cpu": $(stats.cpu),
    "wa": $(stats.wa),
    "st": $(stats.st),
    "us": $(stats.us),
    "sy": $(stats.sy),
    "load1": $(stats.load1),
    "load5": $(stats.load5),
    "load15": $(stats.load15),
    "ramsize": ramSize,
    "ram": $(stats.ram),
    "ramswapsize": ramSwapSize,
    "ramswap": $(stats.ramSwap),
    "rambuff": $(stats.ramBuff),
    "ramcache": $(stats.ramCache),
    "disks": getDiskUsageBase64(
      zfs.usageByMount,
      zfs.canonicalFilesystems,
      zfs.duplicateFilesystems
    ),
    "inodes": getInodesBase64(
      cfg.checkSoftRaid,
      zfs.canonicalFilesystems,
      zfs.duplicateFilesystems
    ),
    "iops": stats.iops,
    "raid": "",
    "zp": zfs.healthBase64,
    "dh": "",
    "nics": buildNicsBase64(stats, nics),
    "ipv4": getIPv4Base64(nics),
    "ipv6": getIPv6Base64(nics),
    "conn": "",
    "temp": stats.temp,
    "serv": "",
    "cust": customVars,
    "oping": opingStr,
    "rps1": "",
    "rps2": ""
  }

type
  ZAllocFunc = proc(opaque: pointer, items, size: cuint): pointer {.cdecl.}
  ZFreeFunc = proc(opaque, address: pointer) {.cdecl.}
  ZStream = object
    next_in: ptr uint8
    avail_in: cuint
    total_in: culong
    next_out: ptr uint8
    avail_out: cuint
    total_out: culong
    msg: cstring
    state: pointer
    zalloc: ZAllocFunc
    zfree: ZFreeFunc
    opaque: pointer
    data_type: cint
    adler: culong
    reserved: culong

const
  ZNoFlush = 0.cint
  ZFinish = 4.cint
  ZOk = 0.cint
  ZStreamEnd = 1.cint
  ZDeflated = 8.cint
  ZDefaultCompression = -1.cint
  ZDefaultStrategy = 0.cint
  ZDefaultWindowBits = 15.cint
  ZGzipWindowBits = ZDefaultWindowBits + 16
  ZDefaultMemLevel = 8.cint
  ZBufSize = 16384

proc zlibVersion(): cstring {.cdecl, importc.}
proc deflateInit2(
  strm: ptr ZStream,
  level, zmethod, windowBits, memLevel, strategy: cint,
  version: cstring,
  streamSize: cint
): cint {.cdecl, importc: "deflateInit2_".}
proc deflate(strm: ptr ZStream, flush: cint): cint {.cdecl, importc.}
proc deflateEnd(strm: ptr ZStream): cint {.cdecl, importc.}

proc gzipCompress(input: string): string =
  var stream: ZStream
  stream.zalloc = nil
  stream.zfree = nil
  stream.opaque = nil
  if input.len > 0:
    stream.next_in = cast[ptr uint8](unsafeAddr input[0])
    stream.avail_in = cuint(input.len)
  else:
    stream.next_in = nil
    stream.avail_in = 0

  let initCode = deflateInit2(
    addr stream,
    ZDefaultCompression,
    ZDeflated,
    ZGzipWindowBits,
    ZDefaultMemLevel,
    ZDefaultStrategy,
    zlibVersion(),
    cint(sizeof(ZStream))
  )
  if initCode != ZOk:
    return ""

  var outChunk = newString(ZBufSize)
  while true:
    stream.next_out = cast[ptr uint8](addr outChunk[0])
    stream.avail_out = cuint(ZBufSize)
    let flushMode = if stream.avail_in == 0: ZFinish else: ZNoFlush
    let code = deflate(addr stream, flushMode)
    if code != ZOk and code != ZStreamEnd:
      discard deflateEnd(addr stream)
      return ""

    let produced = ZBufSize - int(stream.avail_out)
    if produced > 0:
      result.add(outChunk[0 ..< produced])
    if code == ZStreamEnd:
      break

  discard deflateEnd(addr stream)

proc gzipBase64(s: string): string =
  encode(gzipCompress(s))

proc requestWithTimeout(
  client: AsyncHttpClient,
  url: Uri | string,
  timeoutMs = TimeoutMs,
  httpMethod: HttpMethod = HttpGet,
  body = "",
  headers: HttpHeaders = nil,
  multipart: MultipartData = nil
): Future[AsyncResponse] {.async.} =
  let requestFuture = client.request(
    url,
    httpMethod = httpMethod,
    body = body,
    headers = headers,
    multipart = multipart
  )
  if not await withTimeout(requestFuture, timeoutMs):
    client.close()
    raise newException(
      TimeoutError,
      fmt"HTTP request timed out after {timeoutMs} ms while connecting or waiting for a response."
    )
  result = await requestFuture

proc postLogDataAsync(logPath: string, securedConnection: int): Future[bool] {.async.} =
  if not fileExists(logPath):
    return false
  let body = readFile(logPath)
  let overrideUrl = getEnv("HETRIXTOOLS_POST_URL", "").strip()
  let postUrl =
    if overrideUrl.len > 0:
      overrideUrl
    else:
      when defined(ssl):
        "https://sm.hetrixtools.net/v2/"
      else:
        if securedConnection > 0:
          "https://sm.hetrixtools.net/v2/"
        else:
          "http://sm.hetrixtools.net/v2/"
  var client: AsyncHttpClient
  when defined(ssl):
    if securedConnection > 0:
      client = newAsyncHttpClient()
    else:
      let tlsCtx = newContext(verifyMode = CVerifyNone)
      client = newAsyncHttpClient(sslContext = tlsCtx)
  else:
    client = newAsyncHttpClient()
  client.headers = newHttpHeaders({
    "Content-Type": "application/x-www-form-urlencoded",
    "User-Agent": "Wget/1.21.3",
    "Accept": "*/*",
    "Accept-Encoding": "identity"
  })
  try:
    discard await client.requestWithTimeout(
      postUrl,
      timeoutMs = TimeoutMs,
      httpMethod = HttpPost,
      body = body
    )
    result = true
  except CatchableError as e:
    stderr.writeLine("ERROR: Failed to POST log data: " & e.msg)
    result = false
  finally:
    client.close()

proc postLogData(logPath: string, securedConnection: int): bool =
  waitFor postLogDataAsync(logPath, securedConnection)

proc writeAndPost(payload: JsonNode, logPath: string, securedConnection: int, noPost: bool) =
  let jsonRaw = $payload
  # Encode exactly like the upstream shell agent: only escape / and +.
  # std/uri.encodeUrl also percent-encodes '=' which corrupts base64 padding
  # when the backend only decodes %2F/%2B (matching what the shell agent sends).
  let encoded = gzipBase64(jsonRaw).replace("/", "%2F").replace("+", "%2B")
  writeFile(logPath, "j=" & encoded & "\n")
  if noPost:
    return
  for attempt in 0..<3:
    if postLogData(logPath, securedConnection):
      break
    if attempt < 2:
      sleepMs(1000)

proc secondsToNextMinute(): int =
  let n = now()
  result = 60 - n.second
  if result <= 0:
    result = 60

proc runAgent(configPath: string, logPath: string, oneShot: bool, noPost: bool) =
  let cfg = parseCfg(configPath)
  if cfg.sid.len == 0:
    stderr.writeLine("ERROR: SID is empty in config.")
    quit(1)
  if oneShot:
    let payload = buildPayload(cfg, configPath)
    writeAndPost(payload, logPath, cfg.securedConnection, noPost)
    return
  while true:
    let payload = buildPayload(cfg, configPath)
    writeAndPost(payload, logPath, cfg.securedConnection, noPost)
    sleep(secondsToNextMinute() * 1000)

proc printUsage(programName: string) =
  echo fmt"HetrixTools Linux Agent v{Version}"
  echo ""
  echo "Usage:"
  echo fmt"  {programName} [options]"
  echo ""
  echo "Options:"
  echo "  -h, --help           Show this help message and exit."
  echo "  --version            Print version and exit."
  echo "  --once               Run one collection cycle, then exit."
  echo "  --no-post            Do not post metrics; only write the local log payload."
  echo "  --config=PATH        Path to configuration file."
  echo "  --log=PATH           Path to output log payload file."
  echo "  --log-shm            Write the log payload to a temp file in /dev/shm."
  echo ""
  echo fmt"Defaults: --config={DefaultConfigPath} --log-shm"

when isMainModule:
  let programName = getAppFilename().extractFilename()

  var
    configPath = DefaultConfigPath
    logPath = ""
    oneShot = false
    noPost = false
    err = ""

  for kind, key, val in getopt():
    case kind
    of cmdArgument:
      err = fmt"Unknown argument: {key}"
      break
    of cmdLongOption, cmdShortOption:
      case key
      of "help", "h":
        printUsage(programName)
        quit(0)
      of "version":
        echo Version
        quit(0)
      of "once":
        oneShot = true
      of "no-post":
        noPost = true
      of "config":
        if val.len == 0:
          err = "Missing value for --config"
          break
        configPath = val
      of "log":
        if val.len == 0:
          err = "Missing value for --log"
          break
        logPath = val
      of "log-shm":
        try:
          logPath = createShmLogPath()
        except IOError as exc:
          err = exc.msg
          break
      else:
        err = fmt"Unknown option: --{key}"
        break
    of cmdEnd: discard

  if err.len == 0 and logPath.len == 0:
    try:
      logPath = createShmLogPath()
    except IOError as exc:
      err = exc.msg

  if err.len > 0:
    stderr.writeLine(fmt"ERROR: {err}")
    printUsage(programName)
    quit(1)

  runAgent(configPath, logPath, oneShot, noPost)
