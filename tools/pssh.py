#!/usr/bin/env python3
# Minimal SSH runner for TP-Link Pharos OS (legacy ssh-dss DSA-only host key).
# OpenSSH 10+ removed ssh-dss support; use paramiko<4 (`pip install "paramiko<4"`).
# Password is read from env PHAROS_PW.
# Usage: PHAROS_PW='<password>' python3 tools/pssh.py <host> <cmd>...
import os, sys, time, paramiko

host, cmds = sys.argv[1], sys.argv[2:]
c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(host, username=os.environ.get("PHAROS_USER", "admin"), password=os.environ["PHAROS_PW"],
          timeout=15, look_for_keys=False, allow_agent=False)
print("# host key:", c.get_transport().get_remote_server_key().get_name(),
      c.get_transport().get_remote_server_key().get_fingerprint().hex())
try:
    for cmd in cmds:
        _, o, e = c.exec_command(cmd, timeout=30)
        print(f"$ {cmd}\n{o.read().decode(errors='replace')}{e.read().decode(errors='replace')}", end="")
except paramiko.SSHException as ex:
    print("# exec failed:", ex, "-> interactive shell")
    ch = c.invoke_shell(); time.sleep(2)
    for cmd in cmds:
        ch.send(cmd + "\n"); time.sleep(3)
    time.sleep(2); out = b""
    while ch.recv_ready():
        out += ch.recv(65535)
    print(out.decode(errors="replace"))
c.close()
