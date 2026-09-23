# Prerequisites

Complete these Windows/WSL requirements **before cloning this repository**.

## Windows host

Required:

- Windows 11
- Hardware virtualization enabled in BIOS/UEFI
- WSL2
- PowerShell
- Internet access
- Recommended host RAM: 16 GB or more

## 1. Install or update WSL

Open PowerShell as Administrator:

```powershell
wsl --install
wsl --update
wsl --set-default-version 2
```

Restart Windows if requested.

Verify:

```powershell
wsl --version
wsl --status
```

## 2. Configure WSL resources

Create or update:

```text
%USERPROFILE%\.wslconfig
```

Recommended configuration used by this lab:

```ini
[wsl2]
processors=6
memory=10GB
swap=0
```

Apply the configuration:

```powershell
wsl --shutdown
```

## 3. Install the clean Ubuntu source distribution

Install Ubuntu 24.04:

```powershell
wsl --install -d Ubuntu-24.04
```

On first launch, create the Linux user:

```text
ubuntu
```

The project expects:

```text
WSL distro name : Ubuntu-24.04
Linux user      : ubuntu
```

## 4. Enable systemd in the Ubuntu source distro

Start Ubuntu:

```powershell
wsl -d Ubuntu-24.04
```

Inside Ubuntu, create `/etc/wsl.conf`:

```bash
sudo tee /etc/wsl.conf >/dev/null <<'EOF'
[boot]
systemd=true

[user]
default=ubuntu
EOF
```

Exit Ubuntu:

```bash
exit
```

Back in PowerShell:

```powershell
wsl --terminate Ubuntu-24.04
```

Verify the source distro:

```powershell
wsl -d Ubuntu-24.04 -- whoami
wsl -d Ubuntu-24.04 -- ps -p 1 -o comm=
```

Expected:

```text
ubuntu
systemd
```

## 5. Install Git for Windows

```powershell
winget install --id Git.Git -e --source winget --accept-source-agreements --accept-package-agreements
```

Open a new PowerShell window if `git` is not immediately found.

Verify:

```powershell
git --version
```

## 6. Allow the project PowerShell scripts for the current session

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
```

This changes the execution policy only for the current PowerShell process.

## 7. Clone the repository

Only after the prerequisites above are complete:

```powershell
cd $HOME

git clone https://github.com/aneeqabid20/LocalKubernetesLabForWindows.git

cd LocalKubernetesLabForWindows
```
