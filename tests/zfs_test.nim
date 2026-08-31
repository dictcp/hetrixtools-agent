import std/[base64, os, tables, unittest]

import ../hetrixtools_agent

suite "ZFS health and usage collection":
  test "is disabled unless CheckSoftRAID is enabled":
    let zfs = collectZfsData(0)
    check zfs.healthBase64 == ""
    check zfs.usageByMount.len == 0

  test "uses zpool status and replaces df usage with ZFS allocation":
    let
      fakeBin = getTempDir() / ("hetrixtools-zfs-test-" & $getCurrentProcessId())
      originalPath = getEnv("PATH")
      detailedStatus = "  pool: tank\n state: ONLINE\nconfig:\n\n        NAME  STATE\n        tank  ONLINE"

    createDir(fakeBin)
    writeFile(fakeBin / "zpool", """#!/bin/sh
if [ "$1" = "status" ] && [ -z "$2" ]; then
  printf '  pool: tank\n state: ONLINE\n'
else
  printf '  pool: tank\n state: ONLINE\nconfig:\n\n        NAME  STATE\n        tank  ONLINE\n'
fi
""")
    writeFile(fakeBin / "zfs", """#!/bin/sh
printf '100\n300\n'
""")
    writeFile(fakeBin / "df", """#!/bin/sh
printf 'Filesystem Type 1B-blocks Used Available Use%% Mounted on\n'
printf 'tank zfs 999 888 111 89%% /mnt/tank\n'
""")
    for command in ["zpool", "zfs", "df"]:
      setFilePermissions(fakeBin / command, {
        fpUserRead, fpUserWrite, fpUserExec,
        fpGroupRead, fpGroupExec,
        fpOthersRead, fpOthersExec
      })

    try:
      putEnv("PATH", fakeBin & PathSep & originalPath)
      let zfs = collectZfsData(1)

      check decode(zfs.healthBase64) ==
        "/mnt/tank,tank," & encode(detailedStatus) & ";"
      check zfs.usageByMount["/mnt/tank"].total == 400
      check zfs.usageByMount["/mnt/tank"].used == 100
      check zfs.usageByMount["/mnt/tank"].available == 300
      check decode(getDiskUsageBase64(zfs.usageByMount)) ==
        "/mnt/tank,zfs,400,100,300;"
    finally:
      putEnv("PATH", originalPath)
      for command in ["zpool", "zfs", "df"]:
        removeFile(fakeBin / command)
      removeDir(fakeBin)
