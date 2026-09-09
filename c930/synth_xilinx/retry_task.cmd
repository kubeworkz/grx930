@echo off
rem Task Scheduler entry point for the Vivado flow auto-retry.
rem Runs every 5 minutes as the logged-on user.
rem
rem Runs wsl.exe SYNCHRONOUSLY: the driver script executes in the foreground,
rem so the task instance lives as long as the flow does. Task Scheduler's
rem default "ignore new instances" policy makes concurrent heartbeats no-ops,
rem and if the WSL VM gets recycled (killing this task process), the next
rem 5-minute tick relaunches everything. The driver is idempotent: it heals
rem the license MAC and skips work if the routed checkpoint already exists.
rem
rem Remove with:  schtasks /delete /tn grx930_vivado_retry /f
wsl.exe -e bash /mnt/c/Users/kubew/grx930/c930/synth_xilinx/run_full_wsl_retry.sh
