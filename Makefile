.RECIPEPREFIX := >
POWERSHELL ?= powershell.exe
NODE ?= controller

.PHONY: preflight setup vms provision start stop status k8s cilium verify shell ssh destroy

preflight:
>$(POWERSHELL) -NoProfile -ExecutionPolicy Bypass -File ./lab.ps1 preflight

setup:
>$(POWERSHELL) -NoProfile -ExecutionPolicy Bypass -File ./lab.ps1 setup

vms:
>$(POWERSHELL) -NoProfile -ExecutionPolicy Bypass -File ./lab.ps1 vms

provision:
>$(POWERSHELL) -NoProfile -ExecutionPolicy Bypass -File ./lab.ps1 provision

start:
>$(POWERSHELL) -NoProfile -ExecutionPolicy Bypass -File ./lab.ps1 start

stop:
>$(POWERSHELL) -NoProfile -ExecutionPolicy Bypass -File ./lab.ps1 stop

status:
>$(POWERSHELL) -NoProfile -ExecutionPolicy Bypass -File ./lab.ps1 status

k8s:
>$(POWERSHELL) -NoProfile -ExecutionPolicy Bypass -File ./lab.ps1 k8s

cilium:
>$(POWERSHELL) -NoProfile -ExecutionPolicy Bypass -File ./lab.ps1 cilium

verify:
>$(POWERSHELL) -NoProfile -ExecutionPolicy Bypass -File ./lab.ps1 verify

shell:
>$(POWERSHELL) -NoProfile -ExecutionPolicy Bypass -File ./lab.ps1 shell -Node $(NODE)

ssh:
>$(POWERSHELL) -NoProfile -ExecutionPolicy Bypass -File ./lab.ps1 ssh -Node $(NODE)

destroy:
>$(POWERSHELL) -NoProfile -ExecutionPolicy Bypass -File ./lab.ps1 destroy
