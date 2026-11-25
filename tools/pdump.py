#!/usr/bin/env python3
# Dump /dev/mtdblock0..N from TP-Link Pharos OS over SSH (read-only).
# Password is read from env PHAROS_PW. Never overwrites existing files.
# Usage: PHAROS_PW='<password>' python3 tools/pdump.py <host> <outdir> <n_blocks>
import os, sys, hashlib, paramiko

host, outdir, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
os.makedirs(outdir, exist_ok=True)
c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(host, username=os.environ.get("PHAROS_USER", "admin"), password=os.environ["PHAROS_PW"],
          timeout=15, look_for_keys=False, allow_agent=False)
for i in range(n):
    _, o, _ = c.exec_command(f"cat /dev/mtdblock{i}", timeout=600)
    data = o.read()
    path = os.path.join(outdir, f"mtd{i}.bin")
    with open(path, "xb") as f:  # never overwrite
        f.write(data)
    print(f"mtd{i} {len(data):#x} sha256={hashlib.sha256(data).hexdigest()}")
c.close()
