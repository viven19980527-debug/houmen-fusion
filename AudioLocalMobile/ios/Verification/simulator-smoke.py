#!/usr/bin/env python3
"""Optional bounded simulator UI smoke test; no platform login or live collection."""
from pathlib import Path
import json,subprocess,time
root=Path.cwd()
def run(*args,timeout=60):
 return subprocess.run(args,capture_output=True,text=True,timeout=timeout,check=True).stdout
proof={"ui_launch":"not_tested","live_comments":"not_tested"}
try:
 state=json.loads(run("xcrun","simctl","list","devices","available","--json"))
 devices=[d for runtime,values in state["devices"].items() if "iOS" in runtime
          for d in values if d.get("isAvailable") and d.get("name","").startswith("iPhone")]
 if not devices:raise RuntimeError("No available iPhone simulator runtime")
 device=devices[0];udid=device["udid"];proof["simulator"]=device["name"]
 if device.get("state")!="Booted":run("xcrun","simctl","boot",udid,timeout=40)
 run("xcrun","simctl","bootstatus",udid,"-b",timeout=100)
 app=root/"build/simulator/Build/Products/Debug-iphonesimulator/AudioLocal.app"
 run("xcrun","simctl","install",udid,str(app))
 run("xcrun","simctl","launch",udid,"cn.shengxun.local")
 time.sleep(10)
 run("xcrun","simctl","io",udid,"screenshot",str(root/"build/ui-preview.png"))
 proof["ui_launch"]="passed";proof["scope"]="empty home screen only, no collection or filters interaction"
except Exception as error:
 proof["ui_launch"]="unavailable";proof["reason"]=type(error).__name__
(root/"build/ui-smoke.json").write_text(json.dumps(proof,indent=2),encoding="utf8")
print(json.dumps(proof))
