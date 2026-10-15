# Sandbox Kit

An offline, portable security and development toolkit for **Windows Sandbox**.

Instead of installing tools at the start of every sandbox session, you build a
kit of portable tools once on your own computer. Windows Sandbox opens that
folder read-only, and a short startup script makes everything ready to use in
under a minute, with no downloads.

## What's in the kit

| Tool | Notes |
| --- | --- |
| Visual Studio Code | Portable mode, with the Python extension preinstalled |
| Python | Full, relocatable build from NuGet, with pip |
| Git | PortableGit |
| PowerShell 7 | Official zip |
| 7-Zip | Command line and the 7-Zip File Manager |
| Sysinternals Suite | Process Explorer, Process Monitor, Autoruns, TCPView and the rest |
| HxD | Hex editor, portable edition |
| Wireshark | Portable build, including TShark |
| Nmap | Command-line scanner |
| Npcap | Installer only; needed for live packet capture |

Anything else you need goes in `Tools\Other` (see below).

## Requirements

- Windows 10 build 18342 or later, or Windows 11, with the **Windows Sandbox**
  feature turned on (Turn Windows features on or off > Windows Sandbox)
- Windows PowerShell 5.1 (built into Windows)
- Internet access on the host while building the kit

## Quick start

1. Download `Build-SandboxKit.ps1` and `Start-SandboxKit.ps1` into one folder,
   for example `C:\SandboxKit`.
2. Build the kit (no administrator rights needed):

   ```powershell
   powershell -ExecutionPolicy Bypass -File C:\SandboxKit\Build-SandboxKit.ps1
   ```

3. Double-click one of the two files the build creates:
   - `SecurityToolkit-Online.wsb`: networking on
   - `SecurityToolkit-Offline.wsb`: networking off, for untrusted files

The sandbox starts, runs `Start-SandboxKit.ps1`, and puts a shortcut for each
tool on the desktop.

## How it works

### Build-SandboxKit.ps1 (runs on the host)

Downloads the latest portable version of each tool into `Tools`, the installers
that can't be portable (Npcap and the Visual C++ runtimes) into `Installers`,
and writes the two `.wsb` files with your kit's path. Downloads are cached in
`Cache`, so rerunning the script only fetches what has a new version. If one
tool fails, the rest of the kit still builds.

To preinstall different VS Code extensions:

```powershell
.\Build-SandboxKit.ps1 -VSCodeExtensions ms-python.python, ms-vscode.powershell
```

### The .wsb files

Each `.wsb` file maps the kit folder into the sandbox at `C:\Kit` as
**read-only**, so nothing running in the sandbox can change your kit, and runs
`Start-SandboxKit.ps1` at logon. The two files differ only in the
`<Networking>` setting.

### Start-SandboxKit.ps1 (runs in the sandbox)

1. Copies Python and VS Code to `C:\Tools`, since they need a writable folder.
2. Installs the Visual C++ runtimes silently.
3. Accepts the Sysinternals license for the session.
4. Adds the tools to PATH.
5. Creates desktop shortcuts, including one for `Tools\Other`.
6. Logs to `C:\Tools\SandboxKit.log`.

## Adding your own tools

Put any portable program in `Tools\Other` on the host. It appears in every
sandbox behind the **Other Tools** desktop shortcut. The build never clears
this folder, and no rebuild is needed after adding something.

The kit is read-only inside the sandbox. A program that saves settings next to
its own `.exe` should be copied to the sandbox desktop and run from there.

## Limitations

- **Live capture needs Npcap**, which is a driver and must be installed. Use the
  "Install Npcap" desktop shortcut; the free edition can't install silently.
  Opening saved captures works without it.
- **pip needs the network**, so new Python packages can only be installed in
  the Online sandbox.
- Wireshark's portable build and Nmap are unpacked from their installers with
  7-Zip. If a future release changes its packaging, the build reports that
  tool as failed and the rest of the kit still works.

## License

The scripts in this repository are released under the [MIT License](LICENSE).

This repository contains only the scripts. The tools are downloaded from their
official sources when you run the build, and each remains under its own
license. Review those licenses, especially the Sysinternals license, before
sharing a built kit with anyone else.
