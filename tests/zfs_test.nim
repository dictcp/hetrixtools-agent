import std/[base64, os, tables, unittest]

import ../hetrixtools_agent

suite "ZFS health and usage collection":
  test "is disabled unless CheckSoftRAID is enabled":
    let zfs = collectZfsData(0)
    check zfs.healthBase64 == ""
    check zfs.usageByMount.len == 0
    check zfs.canonicalFilesystems.len == 0
    check zfs.duplicateFilesystems.len == 0

  test "uses pool root as canonical row and deduplicates ZFS datasets by default":
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
printf 'tank/data zfs 999 888 111 89%% /mnt/tank/data\n'
printf 'tank zfs 999 888 111 89%% /mnt/tank\n'
printf 'tank/data zfs 999 888 111 89%% /mnt/tank/data\n'
printf 'tank zfs 999 888 111 89%% /mnt/tank\n'
printf '/dev/sda1 ext4 200 50 150 25%% /mnt/other\n'
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
      check zfs.canonicalFilesystems.hasKey("tank")
      check zfs.duplicateFilesystems.hasKey("tank/data")
      check decode(getDiskUsageBase64(
        zfs.usageByMount,
        zfs.canonicalFilesystems,
        zfs.duplicateFilesystems
      )) ==
        "/mnt/tank,zfs,400,100,300;/mnt/other,ext4,200,50,150;"
      check decode(getInodesBase64(
        zfs.canonicalFilesystems,
        zfs.duplicateFilesystems
      )) ==
        "/mnt/tank,999,888,111;/mnt/other,200,50,150;"

      let disabled = collectZfsData(1, 0)
      check decode(disabled.healthBase64) ==
        "/mnt/tank,tank," & encode(detailedStatus) & ";"
      check disabled.canonicalFilesystems.len == 0
      check disabled.duplicateFilesystems.len == 0
      check decode(getDiskUsageBase64(
        disabled.usageByMount,
        disabled.canonicalFilesystems,
        disabled.duplicateFilesystems
      )) ==
        "/mnt/tank/data,zfs,999,888,111;/mnt/tank,zfs,400,100,300;" &
        "/mnt/tank/data,zfs,999,888,111;/mnt/tank,zfs,400,100,300;" &
        "/mnt/other,ext4,200,50,150;"
      check decode(getInodesBase64(
        disabled.canonicalFilesystems,
        disabled.duplicateFilesystems
      )) ==
        "/mnt/tank/data,999,888,111;/mnt/tank,999,888,111;" &
        "/mnt/tank/data,999,888,111;/mnt/tank,999,888,111;" &
        "/mnt/other,200,50,150;"
    finally:
      putEnv("PATH", originalPath)
      for command in ["zpool", "zfs", "df"]:
        removeFile(fakeBin / command)
      removeDir(fakeBin)

  test "does not deduplicate when zfs usage output is malformed":
    let
      fakeBin = getTempDir() / ("hetrixtools-zfs-test-bad-zfs-get-" & $getCurrentProcessId())
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
printf 'not-a-number\n'
""")
    writeFile(fakeBin / "df", """#!/bin/sh
printf 'Filesystem Type 1B-blocks Used Available Use%% Mounted on\n'
printf 'tank/data zfs 999 888 111 89%% /mnt/tank/data\n'
printf 'tank zfs 999 888 111 89%% /mnt/tank\n'
printf 'tank/data zfs 999 888 111 89%% /mnt/tank/data\n'
printf 'tank zfs 999 888 111 89%% /mnt/tank\n'
printf '/dev/sda1 ext4 200 50 150 25%% /mnt/other\n'
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
      check zfs.usageByMount.len == 0
      check zfs.canonicalFilesystems.len == 0
      check zfs.duplicateFilesystems.len == 0
      check decode(getDiskUsageBase64(
        zfs.usageByMount,
        zfs.canonicalFilesystems,
        zfs.duplicateFilesystems
      )) ==
        "/mnt/tank/data,zfs,999,888,111;/mnt/tank,zfs,999,888,111;" &
        "/mnt/tank/data,zfs,999,888,111;/mnt/tank,zfs,999,888,111;" &
        "/mnt/other,ext4,200,50,150;"
      check decode(getInodesBase64(
        zfs.canonicalFilesystems,
        zfs.duplicateFilesystems
      )) ==
        "/mnt/tank/data,999,888,111;/mnt/tank,999,888,111;" &
        "/mnt/tank/data,999,888,111;/mnt/tank,999,888,111;" &
        "/mnt/other,200,50,150;"
    finally:
      putEnv("PATH", originalPath)
      for command in ["zpool", "zfs", "df"]:
        removeFile(fakeBin / command)
      removeDir(fakeBin)
