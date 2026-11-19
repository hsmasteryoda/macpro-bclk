#!/usr/bin/env python3
"""macpro-bclk-gui - a small local web GUI to overclock the 2013 Mac Pro 6,1 via BCLK,
with built-in CPU / RAM benchmarks and a stability tester to validate each step.

Runs on the machine whose clock generator it drives (the Mac Pro / Proxmox host). Open the printed URL
in a browser on ANY OS (macOS, Linux, phone) to read/step the base clock and run the benchmarks.

Chip: ICS 932SQL435AL (CK420BQ family) on the PCH SMBus (i801), address 0x69. Frequency = byte6 bits[2:0]
(SQL420 table: 97..104 MHz, 100 default). Raising BCLK lifts CPU AND PCIe/DMI/SATA/TB/RAM by the same %.

SAFETY
  * Reading the clock is harmless. A WRITE changes the live clock and can hang the box, glitch IO, and
    skew the TSC. The setting is volatile (power-cycle restores 100 MHz). Writes are disabled until you
    arm them (--allow-write + a per-action checkbox), limited to 1 MHz steps, and refuse unless the chip
    reports the expected 932SQL435 device id.
  * Benchmarks and the stability test load the CPU/RAM to 100%. On a live server this WILL cause lag for
    players. Run them in a maintenance window; each needs a confirm in the UI.

  python3 macpro-bclk-gui.py                 # bind 127.0.0.1:8099 (local only; use an SSH tunnel)
  python3 macpro-bclk-gui.py --host 0.0.0.0  # reachable on the LAN (no auth - trusted LAN only)
  sudo python3 macpro-bclk-gui.py --allow-write   # enable BCLK writes (needs root for SMBus)

Native macOS note: this is a web app, so you drive it from a Mac browser, but the SMBus/stress I/O runs on
the Linux host. A NATIVE macOS app would need a signed SMBus kext/DriverKit driver (SIP-restricted) - out of scope.
"""
import argparse, glob, json, os, platform, re, shutil, signal, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

BUS = int(os.environ.get("BCLK_BUS", "0"))
ADDR = 0x69
EXPECT_DEV = 0x35
FREQ_MIN, FREQ_MAX = 100, 110
STOCK_MHZ = 100
LOG = os.environ.get("BCLK_LOG", "/var/log/macpro-bclk.log")
HERE = os.path.dirname(os.path.abspath(__file__))
STOCK_BLOCK_FILE = os.path.join(HERE, "bclk-stock-block.txt")
RESULTS_FILE = os.path.join(HERE, "bench-results.json")
ALLOW_WRITE = False
NPROC = os.cpu_count() or 4
BENCH_MAX_SECS = 1800

# ------------------------------------------------------------------ util
def logline(msg):
    line = f"{time.strftime('%Y-%m-%dT%H:%M:%S')} {msg}"
    try:
        open(LOG, "a").write(line + "\n")
    except OSError:
        pass
    print(line, file=sys.stderr)

def have(tool): return shutil.which(tool) is not None
def sh(cmd, timeout=15):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except Exception as e:
        return subprocess.CompletedProcess(cmd, 1, "", str(e))

# ------------------------------------------------------------------ SMBus / BCLK
def read_block():
    if platform.system() != "Linux":
        return None
    for m in ("i2c-i801", "i2c-dev"):
        sh(["modprobe", m])
    if not have("i2cget"):
        return None
    r = sh(["i2cget", "-y", str(BUS), hex(ADDR), "0x00", "s"])
    if r.returncode != 0:
        return None
    try:
        return [int(t, 16) for t in r.stdout.split()]
    except ValueError:
        return None

def decode(block):
    if not block or len(block) < 10:
        return {"ok": False, "raw": block or [], "error": "clock-gen read failed (need i2c-tools, root, Linux host)"}
    b6, b7, b9 = block[6], block[7], block[9]
    return {"ok": True, "raw": [f"0x{b:02x}" for b in block], "byte6": b6, "fsel": b6 & 0x7,
            "mhz": 97 + (b6 & 0x7), "vendor_ok": (b7 & 0xf) == 1, "vendor": f"0x{b7:02x}",
            "device_ok": b9 == EXPECT_DEV, "device": f"0x{b9:02x}"}

def effective_mhz():
    if have("turbostat"):
        r = sh(["turbostat", "--quiet", "--show", "Bzy_MHz", "--num_iterations", "1", "--interval", "1"], timeout=6)
        nums = [int(x) for x in re.findall(r"^\s*(\d{3,5})\s*$", r.stdout, re.M)]
        if nums:
            return max(nums)
    try:
        mh = [float(m) for m in re.findall(r"cpu MHz\s*:\s*([\d.]+)", open("/proc/cpuinfo").read())]
        if mh:
            return round(max(mh))
    except OSError:
        pass
    return None

def cur_bclk():
    d = decode(read_block())
    return d["mhz"] if d.get("ok") else None

def write_mhz(target):
    if not ALLOW_WRITE:
        return False, "writes disabled (start the server with sudo ... --allow-write)"
    if not (FREQ_MIN <= target <= FREQ_MAX):
        return False, f"target {target} out of range {FREQ_MIN}-{FREQ_MAX}"
    if not have("i2cset"):
        return False, "i2cset missing (apt install i2c-tools)"
    block = read_block()
    d = decode(block)
    if not d["ok"]:
        return False, d["error"]
    if not d["device_ok"]:
        return False, f"device id {d['device']} != expected 0x{EXPECT_DEV:02x}; refusing to write"
    cur = d["mhz"]
    if abs(target - cur) > 1:
        return False, f"refusing a {target - cur:+d} MHz jump from {cur}; step 1 MHz at a time"
    if not os.path.exists(STOCK_BLOCK_FILE):
        try:
            open(STOCK_BLOCK_FILE, "w").write(" ".join(f"0x{b:02x}" for b in block) + "\n")
            logline(f"saved stock block: {' '.join(f'0x{b:02x}' for b in block)}")
        except OSError:
            pass
    nb = list(block)
    nb[6] = (nb[6] & ~0x7) | (target - 97)
    nb[1] = nb[1] | 0x80
    before = effective_mhz()
    logline(f"WRITE BCLK {cur}->{target}  byte6 0x{block[6]:02x}->0x{nb[6]:02x}  effMHz_before={before}")
    r = sh(["i2cset", "-y", str(BUS), hex(ADDR), "0x00", *[f"0x{b:02x}" for b in nb], "s"])
    if r.returncode != 0:
        logline(f"i2cset failed rc={r.returncode}: {r.stderr.strip()}")
        return False, f"i2cset failed: {r.stderr.strip()}"
    time.sleep(1)
    after = effective_mhz()
    d2 = decode(read_block())
    logline(f"  readback byte6=0x{d2.get('byte6',0):02x} -> {d2.get('mhz')} MHz  effMHz_after={after}")
    return True, f"set {target} MHz (eff {before}->{after} MHz). Watch stability & journalctl -k."

# ------------------------------------------------------------------ error/MCE monitoring
def mce_snapshot():
    """Count hardware-error indicators (EDAC corrected/uncorrected + kernel MCE log lines)."""
    edac = 0
    for f in glob.glob("/sys/devices/system/edac/mc/mc*/ce_count") + glob.glob("/sys/devices/system/edac/mc/mc*/ue_count"):
        try:
            edac += int(open(f).read().strip())
        except (OSError, ValueError):
            pass
    mce = 0
    r = sh(["dmesg", "--notime"], timeout=8)
    if r.returncode == 0:
        mce = len(re.findall(r"(?i)machine check|\bmce:|hardware error|corrected error|uncorrected", r.stdout))
    return {"edac": edac, "mce_log": mce}

# ------------------------------------------------------------------ job runner (one at a time)
JOB = {"running": False, "kind": None, "started": 0, "timeout": 0, "output": "", "result": None, "proc": None}
JLOCK = threading.Lock()

def _append(txt):
    JOB["output"] = (JOB["output"] + txt)[-12000:]

def _run_proc(cmd):
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                         bufsize=1, start_new_session=True)
    JOB["proc"] = p
    for line in iter(p.stdout.readline, ""):
        _append(line)
    p.wait()
    JOB["proc"] = None
    return p.returncode

def _parse_metrics(out):
    """bogo-ops/s (real) per stressor from stress-ng --metrics-brief, plus any memory-rate line."""
    scores = {}
    for m in re.finditer(r"\]\s+([a-z0-9]+)\s+(\d+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)", out):
        scores[m.group(1)] = float(m.group(5))   # bogo ops/s (real time)
    rate = None
    mr = re.search(r"memory rate[:\s]+([\d.]+)\s*MB", out, re.I) or re.search(r"([\d.]+)\s*MB per sec", out, re.I)
    if mr:
        rate = float(mr.group(1))
    return scores, rate

def _finish(kind, rc, extra):
    res = {"kind": kind, "rc": rc, "bclk": cur_bclk(), "when": time.strftime("%Y-%m-%d %H:%M:%S"), **extra}
    JOB["result"] = res
    try:
        hist = json.load(open(RESULTS_FILE)) if os.path.exists(RESULTS_FILE) else []
    except (OSError, ValueError):
        hist = []
    hist.append(res)
    try:
        json.dump(hist[-50:], open(RESULTS_FILE, "w"), indent=2)
    except OSError:
        pass
    logline(f"BENCH {kind} done rc={rc} bclk={res['bclk']} {extra}")

def _worker(kind, cmd, secs, stability):
    try:
        before = mce_snapshot() if stability else None
        rc = _run_proc(cmd)
        out = JOB["output"]
        scores, rate = _parse_metrics(out)
        extra = {"scores": scores, "ram_MBps": rate, "secs": secs}
        if stability:
            after = mce_snapshot()
            new_err = (after["edac"] - before["edac"]) + max(0, after["mce_log"] - before["mce_log"])
            completed = rc == 0
            verdict = "PASS" if (completed and new_err == 0) else "FAIL"
            extra.update({"mce_before": before, "mce_after": after, "new_errors": new_err,
                         "completed": completed, "verdict": verdict})
        _finish(kind, rc, extra)
    except Exception as e:
        _append(f"\n[job error] {e}\n")
        _finish(kind, 1, {"error": str(e)})
    finally:
        JOB["running"] = False

def start_job(kind, secs):
    if not have("stress-ng"):
        return False, "stress-ng not installed (apt install stress-ng)"
    secs = max(5, min(BENCH_MAX_SECS, int(secs)))
    with JLOCK:
        if JOB["running"]:
            return False, "a job is already running"
        JOB.update({"running": True, "kind": kind, "started": time.time(), "timeout": secs,
                    "output": "", "result": None})
    half = max(1, NPROC // 2)
    if kind == "cpu":
        cmd = ["stress-ng", "--cpu", str(NPROC), "--cpu-method", "all", "--metrics-brief", "--timeout", f"{secs}s"]
        stability = False
    elif kind == "ram":
        cmd = ["stress-ng", "--stream", str(NPROC), "--metrics-brief", "--timeout", f"{secs}s"]
        stability = False
    elif kind == "stability":
        cmd = ["stress-ng", "--cpu", str(NPROC), "--vm", str(half), "--vm-bytes", "75%",
               "--verify", "--metrics-brief", "--timeout", f"{secs}s"]
        stability = True
    else:
        JOB["running"] = False
        return False, f"unknown job {kind}"
    logline(f"BENCH start {kind} secs={secs} cmd={' '.join(cmd)} bclk={cur_bclk()}")
    threading.Thread(target=_worker, args=(kind, cmd, secs, stability), daemon=True).start()
    return True, f"started {kind} for {secs}s"

def stop_job():
    p = JOB.get("proc")
    if p and p.poll() is None:
        try:
            os.killpg(os.getpgid(p.pid), signal.SIGTERM)
        except Exception:
            p.terminate()
        return True, "stopping job"
    return False, "no job running"

def job_status():
    j = {k: JOB[k] for k in ("running", "kind", "timeout", "output", "result")}
    j["elapsed"] = round(time.time() - JOB["started"]) if JOB["running"] else 0
    return j

def history():
    try:
        return json.load(open(RESULTS_FILE)) if os.path.exists(RESULTS_FILE) else []
    except (OSError, ValueError):
        return []

def verified():
    return os.path.exists(STOCK_BLOCK_FILE)

def tail_log(n=30):
    try:
        return "".join(open(LOG).readlines()[-n:]) or "(empty)"
    except OSError:
        return "(no log yet)"

# ------------------------------------------------------------------ page
PAGE = r"""<!doctype html><html lang=en><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1"><title>Mac Pro BCLK</title>
<style>
:root{--bg:#0f1115;--card:#181b22;--fg:#e6e8ee;--mut:#8a90a0;--acc:#5aa0ff;--warn:#ffb648;--bad:#ff5a5a;--ok:#4ad07a;--line:#262b36}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 -apple-system,Segoe UI,Roboto,sans-serif;padding:16px}
.wrap{max-width:760px;margin:0 auto}h1{font-size:19px;margin:.2em 0}.sub{color:var(--mut);font-size:13px;margin-bottom:14px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px;margin-bottom:14px}
.big{font-size:40px;font-weight:700;letter-spacing:-1px}.unit{font-size:17px;color:var(--mut);font-weight:400}
.row{display:flex;gap:10px;align-items:center;flex-wrap:wrap}.grow{flex:1}
.k{color:var(--mut)}.mono{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12px}
button{background:#222735;color:var(--fg);border:1px solid var(--line);border-radius:9px;padding:9px 13px;font-size:14px;cursor:pointer}
button:hover{border-color:var(--acc)}button:disabled{opacity:.4;cursor:not-allowed}
.step{font-size:22px;width:50px}.apply{background:var(--acc);color:#061018;border:0;font-weight:600}
.restore{background:#2a2f3c}.go{background:var(--warn);color:#1a1205;border:0;font-weight:600}
.pill{padding:2px 8px;border-radius:999px;font-size:12px;border:1px solid var(--line)}
.ok{color:var(--ok)}.bad{color:var(--bad)}.warn{color:var(--warn)}
.banner{background:#2a1d10;border:1px solid #5a3d16;color:var(--warn);padding:10px 12px;border-radius:9px;font-size:13px;margin-bottom:14px}
.arm{display:flex;gap:8px;align-items:center;font-size:13px;color:var(--mut);margin:10px 0}
.tabs{display:flex;gap:6px;margin-bottom:14px}.tab{padding:8px 14px;border:1px solid var(--line);border-radius:9px;cursor:pointer;background:#13161c}
.tab.on{background:var(--acc);color:#061018;border-color:var(--acc);font-weight:600}
pre{background:#0b0d12;border:1px solid var(--line);border-radius:9px;padding:10px;max-height:240px;overflow:auto;font-size:12px;margin:0;white-space:pre-wrap}
table{width:100%;border-collapse:collapse;font-size:13px}td,th{text-align:left;padding:5px 8px;border-bottom:1px solid var(--line)}
input[type=number]{background:#0b0d12;border:1px solid var(--line);color:var(--fg);border-radius:7px;padding:7px;width:80px}
.hide{display:none}
</style></head><body><div class=wrap>
<h1>Mac Pro 6,1 · BCLK overclock + bench</h1>
<div class=sub>ICS 932SQL435AL @ SMBus 0x69 · base clock scales CPU <b>and</b> PCIe/DMI/SATA/TB/RAM</div>
<div class=tabs><div class="tab on" data-t=oc>Overclock</div><div class=tab data-t=bench>Benchmark</div><div class=tab data-t=stab>Stability</div></div>

<!-- OVERCLOCK -->
<div id=tab-oc>
<div class=banner id=unverified>⚠ Write path is <b>UNVERIFIED</b> on this hardware. The first successful write clears this. Step only at a maintenance window with no players, with the ability to power-cycle. The setting is volatile — a power-cycle restores 100 MHz.</div>
<div class=card>
  <div class=row><div class=grow><div class=k>Base clock</div><div class=big id=bclk>—<span class=unit> MHz</span></div></div>
  <div><div class=k>Effective CPU</div><div class=big id=eff>—<span class=unit> MHz</span></div></div></div>
  <div class=row style=margin-top:10px><span class=pill id=dev>device —</span><span class=pill id=ven>vendor —</span><span class=pill id=write>write —</span></div>
  <div class="k mono" id=raw style=margin-top:10px></div>
</div>
<div class=card>
  <div class=row><button class=step id=minus>−</button>
    <div class=grow style=text-align:center><div class=k>Target</div><div class=big><span id=target>—</span><span class=unit> MHz</span></div></div>
    <button class=step id=plus>+</button></div>
  <div class=arm><input type=checkbox id=armchk><label for=armchk>Maintenance window (no players) and I can power-cycle.</label></div>
  <div class=row><button class=apply id=apply disabled>Apply target</button><button class=restore id=restore>Restore 100 MHz</button>
    <span class=grow></span><span id=msg class=k></span></div>
</div></div>

<!-- BENCHMARK -->
<div id=tab-bench class=hide>
<div class=banner>Benchmarks load all cores / memory to 100% for the duration. On a live server this causes player lag — run in a maintenance window. Use them before and after a BCLK step to measure the real gain.</div>
<div class=card>
  <div class=row><label class=k>Duration <input type=number id=bsecs value=20 min=5 max=600> s</label>
    <button id=bcpu>CPU benchmark</button><button id=bram>RAM benchmark</button>
    <span class=grow></span><button id=bstop class=restore>Stop</button></div>
</div>
<div class=card><div class=k style=margin-bottom:6px>Results (newest first — the BCLK column lets you compare before/after OC)</div>
  <table id=restbl><tr><th>when</th><th>test</th><th>BCLK</th><th>score</th></tr></table></div>
</div>

<!-- STABILITY -->
<div id=tab-stab class=hide>
<div class=banner>Stress + verify test: hammers CPU and ~75% RAM with result verification, then checks EDAC/MCE counters. A FAIL (verify error, crash, or new machine-check) means the current BCLK is unstable — back off a step. This is the test that proves an overclock is safe to keep.</div>
<div class=card>
  <div class=row><label class=k>Duration <input type=number id=ssecs value=120 min=30 max=1800> s</label>
    <div class=arm><input type=checkbox id=sarm><label for=sarm>Maintenance window — OK to peg the box.</label></div>
    <button id=sgo class=go disabled>Run stability test</button><span class=grow></span><button id=sstop class=restore>Stop</button></div>
  <div id=sverdict style=margin-top:10px></div>
</div></div>

<!-- shared job view -->
<div class=card id=jobcard><div class=row><div class=k style=margin-bottom:6px>Job</div><span class=grow></span><span id=jobstat class=k></span></div>
  <pre id=joblog>idle</pre></div>
<div class=card><div class=k style=margin-bottom:6px>Activity log</div><pre id=log>loading…</pre></div>
<div class=sub>Polling every 2 s. Writes and benchmarks are logged on the server. Closing this page does not stop a running job.</div>
</div>
<script>
let cur=null,target=null,writeEnabled=false;
const $=id=>document.getElementById(id);
document.querySelectorAll('.tab').forEach(t=>t.onclick=()=>{
  document.querySelectorAll('.tab').forEach(x=>x.classList.remove('on'));t.classList.add('on');
  for(const n of ['oc','bench','stab']) $('tab-'+n).classList.toggle('hide',n!==t.dataset.t);
});
function paintStatus(d){
  if(d.clock&&d.clock.ok){cur=d.clock.mhz;$('bclk').innerHTML=cur+'<span class=unit> MHz</span>';
    $('raw').textContent='clockgen: '+d.clock.raw.join(' ');
    $('dev').innerHTML='device '+(d.clock.device_ok?'<span class=ok>435 ✓</span>':'<span class=bad>'+d.clock.device+' ?</span>');
    $('ven').innerHTML='vendor '+(d.clock.vendor_ok?'<span class=ok>ICS ✓</span>':'<span class=bad>'+d.clock.vendor+'</span>');
    if(target===null)target=cur;}
  else{$('bclk').textContent='n/a';$('raw').textContent=(d.clock&&d.clock.error)||'read failed';}
  $('eff').innerHTML=(d.eff_mhz||'—')+'<span class=unit> MHz</span>';
  writeEnabled=d.write_enabled;
  $('write').innerHTML='write '+(d.write_enabled?'<span class=warn>armed on server</span>':'<span class=k>disabled</span>');
  if(d.verified)$('unverified').style.display='none';
  $('target').textContent=target===null?'—':target;gate();
  if(d.log)$('log').textContent=d.log;
}
function gate(){
  $('apply').disabled=!(writeEnabled&&$('armchk').checked&&target!==null&&cur!==null&&Math.abs(target-cur)<=1&&target!==cur);
  $('sgo').disabled=!$('sarm').checked;
}
function fmtScore(r){
  if(r.kind==='ram'){ if(r.ram_MBps) return r.ram_MBps.toFixed(0)+' MB/s';
    return (r.scores&&r.scores.stream?r.scores.stream.toFixed(0)+' ops/s':'—'); }
  if(r.kind==='cpu') return (r.scores&&r.scores.cpu?r.scores.cpu.toFixed(0)+' bogo-ops/s':'—');
  if(r.kind==='stability') return (r.verdict==='PASS'?'<span class=ok>PASS</span>':'<span class=bad>FAIL ('+(r.new_errors||0)+' err)</span>');
  return '—';
}
function paintHist(h){
  const t=$('restbl');t.innerHTML='<tr><th>when</th><th>test</th><th>BCLK</th><th>score</th></tr>';
  h.slice().reverse().forEach(r=>{const tr=document.createElement('tr');
    tr.innerHTML=`<td>${r.when||''}</td><td>${r.kind}</td><td>${r.bclk||'?'} MHz</td><td>${fmtScore(r)}</td>`;t.appendChild(tr);});
}
function paintJob(j){
  $('jobstat').textContent=j.running?`${j.kind} · ${j.elapsed}/${j.timeout}s`:(j.result?`${j.result.kind} done`:'idle');
  $('joblog').textContent=j.output||'idle';
  if(j.result&&j.result.kind==='stability'){const r=j.result;
    $('sverdict').innerHTML=`<b class="${r.verdict==='PASS'?'ok':'bad'}">${r.verdict}</b> — `+
      `completed ${r.completed}, new hardware errors ${r.new_errors} (EDAC ${r.mce_after.edac-r.mce_before.edac}, MCE-log ${r.mce_after.mce_log-r.mce_before.mce_log})`;}
}
async function refresh(){try{
  const s=await (await fetch('/api/status')).json();paintStatus(s);
  const j=await (await fetch('/api/job')).json();paintJob(j);
  paintHist(await (await fetch('/api/history')).json());
}catch(e){}}
$('minus').onclick=()=>{if(target!==null){target=Math.max(100,target-1);$('target').textContent=target;gate();}};
$('plus').onclick=()=>{if(target!==null){target=Math.min(110,target+1);$('target').textContent=target;gate();}};
$('armchk').onchange=gate;$('sarm').onchange=gate;
$('apply').onclick=async()=>{if(!confirm('Set BCLK to '+target+' MHz on the LIVE machine?'))return;
  $('msg').textContent='applying…';const r=await (await fetch('/api/write?mhz='+target,{method:'POST'})).json();
  $('msg').textContent=r.message||'';target=null;refresh();};
$('restore').onclick=async()=>{if(!confirm('Write 100 MHz (stock) back?'))return;
  $('msg').textContent='restoring…';const r=await (await fetch('/api/restore',{method:'POST'})).json();$('msg').textContent=r.message||'';target=null;refresh();};
async function startBench(kind,secsId){if(!confirm('Run '+kind+' benchmark? This pegs the box and will lag players.'))return;
  const secs=$(secsId).value;await fetch('/api/bench/'+kind+'?secs='+secs,{method:'POST'});refresh();}
$('bcpu').onclick=()=>startBench('cpu','bsecs');
$('bram').onclick=()=>startBench('ram','bsecs');
$('sgo').onclick=async()=>{if(!confirm('Run stability test for '+$('ssecs').value+'s? Full load + verify.'))return;
  await fetch('/api/bench/stability?secs='+$('ssecs').value,{method:'POST'});refresh();};
$('bstop').onclick=$('sstop').onclick=async()=>{await fetch('/api/job/stop',{method:'POST'});refresh();};
refresh();setInterval(refresh,2000);
</script></body></html>"""

# ------------------------------------------------------------------ HTTP
class H(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json"):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code); self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass

    def do_GET(self):
        p = urlparse(self.path).path
        if p == "/":
            return self._send(200, PAGE, "text/html; charset=utf-8")
        if p == "/api/status":
            return self._send(200, json.dumps({"clock": decode(read_block()), "eff_mhz": effective_mhz(),
                "write_enabled": ALLOW_WRITE, "verified": verified(), "log": tail_log()}))
        if p == "/api/job":
            return self._send(200, json.dumps(job_status()))
        if p == "/api/history":
            return self._send(200, json.dumps(history()))
        return self._send(404, json.dumps({"error": "not found"}))

    def do_POST(self):
        u = urlparse(self.path); p = u.path; q = parse_qs(u.query)
        if p == "/api/write":
            try: target = int(q.get("mhz", ["0"])[0])
            except ValueError: return self._send(400, json.dumps({"ok": False, "message": "bad mhz"}))
            ok, msg = write_mhz(target); return self._send(200, json.dumps({"ok": ok, "message": msg}))
        if p == "/api/restore":
            ok, msg = write_mhz(STOCK_MHZ); return self._send(200, json.dumps({"ok": ok, "message": msg}))
        if p.startswith("/api/bench/"):
            kind = p.rsplit("/", 1)[-1]
            try: secs = int(q.get("secs", ["20"])[0])
            except ValueError: secs = 20
            ok, msg = start_job(kind, secs); return self._send(200, json.dumps({"ok": ok, "message": msg}))
        if p == "/api/job/stop":
            ok, msg = stop_job(); return self._send(200, json.dumps({"ok": ok, "message": msg}))
        return self._send(404, json.dumps({"error": "not found"}))

def main():
    global ALLOW_WRITE
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8099)
    ap.add_argument("--allow-write", action="store_true", help="enable BCLK write endpoints (needs root)")
    a = ap.parse_args()
    ALLOW_WRITE = a.allow_write
    if platform.system() != "Linux":
        print("WARNING: SMBus/stress I/O only works on the Linux host; on macOS this only serves the UI.", file=sys.stderr)
    if a.allow_write and hasattr(os, "geteuid") and os.geteuid() != 0:
        print("note: BCLK writes need root (SMBus). Re-run with sudo.", file=sys.stderr)
    if not have("stress-ng"):
        print("note: stress-ng not found - benchmarks/stability disabled until `apt install stress-ng`.", file=sys.stderr)
    srv = ThreadingHTTPServer((a.host, a.port), H)
    logline(f"GUI started http://{a.host}:{a.port} write={'ON' if ALLOW_WRITE else 'off'} nproc={NPROC}")
    print(f"\n  Mac Pro BCLK GUI -> http://{a.host}:{a.port}\n"
          f"  writes: {'ENABLED (arm each action in the UI)' if ALLOW_WRITE else 'DISABLED (restart with sudo --allow-write)'}\n"
          f"  remote: ssh -L {a.port}:localhost:{a.port} root@<macpro-ip>  then open http://localhost:{a.port}\n", file=sys.stderr)
    try: srv.serve_forever()
    except KeyboardInterrupt: pass

if __name__ == "__main__":
    main()
