# HetrixTools Agent Unraid Plugin

This directory contains a native Unraid plugin for the HetrixTools Linux server
monitoring agent. It runs the compiled Nim daemon directly on Unraid and does
not use Docker.

## Install

```bash
/usr/local/sbin/plugin install https://raw.githubusercontent.com/dictcp/hetrixtools-agent/master/unraid/hetrixtools-agent.plg
```

Then open `Settings -> HetrixTools Agent`, set the 32-character HetrixTools
Server ID, and apply the settings.

## Paths

- Persistent config: `/boot/config/plugins/hetrixtools-agent/hetrixtools.cfg`
- Cached release archives: `/boot/config/plugins/hetrixtools-agent/packages`
- WebGUI files: `/usr/local/emhttp/plugins/hetrixtools-agent`
- Service script: `/etc/rc.d/rc.hetrixtools_agent`
- Agent symlink: `/usr/local/sbin/hetrixtools_agent`

## Service Commands

```bash
/etc/rc.d/rc.hetrixtools_agent status
/etc/rc.d/rc.hetrixtools_agent start
/etc/rc.d/rc.hetrixtools_agent stop
/etc/rc.d/rc.hetrixtools_agent restart
```

## Remove

```bash
/usr/local/sbin/plugin remove hetrixtools-agent.plg
```
