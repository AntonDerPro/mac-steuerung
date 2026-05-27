from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json, shutil, pathlib, logging, re, urllib.request, base64, subprocess

PORT = 8765
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")

ICLOUD_BASE = pathlib.Path("/Users/anton/Library/Mobile Documents/com~apple~CloudDocs")

ALLOWED_BASES = [
    pathlib.Path.home(),
    ICLOUD_BASE,
]

SEARCH_BASES = [
    pathlib.Path.home() / "Downloads",
    pathlib.Path.home() / "Desktop",
    pathlib.Path.home() / "Documents",
    pathlib.Path.home() / "Movies",
    pathlib.Path.home() / "Pictures",
]

OLLAMA_MODELS = [
    "gemma4-vision",
    "gemma4",
    "qwen3:4b",
    "phi3:mini",
    "ibm/granite4:3b",
]

# ── Hilfsfunktionen ──────────────────────────────────────────────────────────

def resolve(p: str) -> pathlib.Path:
    if p.startswith("icloud:/"):
        rest = p[len("icloud:/"):].lstrip("/")
        return (ICLOUD_BASE / rest).resolve()
    return pathlib.Path(p).expanduser().resolve()

def is_allowed(p: pathlib.Path) -> bool:
    for base in ALLOWED_BASES:
        try:
            p.relative_to(base)
            return True
        except ValueError:
            continue
    return False

def search_files(keywords: list, preferred_base: str = None) -> list:
    results = []
    seen = set()
    preferred_path = None
    if preferred_base:
        try:
            preferred_path = resolve(preferred_base)
        except Exception:
            preferred_path = pathlib.Path(preferred_base).expanduser()
        bases = [preferred_path] + [b for b in SEARCH_BASES if b != preferred_path]
    else:
        bases = SEARCH_BASES
    for base in bases:
        if not base.exists():
            continue
        for f in base.rglob("*"):
            if f.is_dir():
                continue
            name_lower = f.name.lower()
            if any(kw.lower() in name_lower for kw in keywords):
                key = str(f)
                if key not in seen:
                    seen.add(key)
                    stat = f.stat()
                    results.append({
                        "name": f.name,
                        "path": str(f),
                        "modified": stat.st_mtime,
                        "size": stat.st_size,
                        "preferred": preferred_path is not None and str(base) == str(preferred_path)
                    })
    results.sort(key=lambda x: (not x.get("preferred", False), -x["modified"]))
    return results[:10]

def ask_ollama(prompt: str, model: str = "ibm/granite4:3b") -> str:
    payload = {"model": model, "prompt": prompt, "stream": False}
    req = urllib.request.Request(
        "http://127.0.0.1:11434/api/generate",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        return json.loads(resp.read())["response"].strip()

def chat_ollama(messages: list, model: str) -> str:
    payload = {"model": model, "messages": messages, "stream": False}
    req = urllib.request.Request(
        "http://127.0.0.1:11434/api/chat",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=180) as resp:
        return json.loads(resp.read())["message"]["content"].strip()

def pdf_to_content(pdf_bytes: bytes) -> dict:
    try:
        import fitz
    except ImportError:
        return {"type": "error", "text": "pymupdf nicht installiert. Bitte: pip3 install pymupdf --break-system-packages"}
    doc = fitz.open(stream=pdf_bytes, filetype="pdf")
    has_images = any(page.get_images(full=True) for page in doc)
    if not has_images:
        full_text = "".join(page.get_text() for page in doc)
        doc.close()
        return {"type": "text", "text": full_text.strip()}
    else:
        page = doc[0]
        mat  = fitz.Matrix(2.0, 2.0)
        pix  = page.get_pixmap(matrix=mat)
        img_bytes = pix.tobytes("png")
        doc.close()
        return {"type": "image", "base64": base64.b64encode(img_bytes).decode(), "mime": "image/png"}

# ── System-Status & Medien ───────────────────────────────────────────────────

def run(cmd: list, timeout: int = 5) -> str:
    try:
        return subprocess.check_output(cmd, stderr=subprocess.DEVNULL, timeout=timeout).decode()
    except Exception:
        return ""

def get_battery() -> dict:
    out = run(["pmset", "-g", "batt"])
    result = {"percent": None, "charging": False, "remaining": None, "source": "unbekannt"}
    for line in out.splitlines():
        if "InternalBattery" in line:
            m = re.search(r'(\d+)%', line)
            if m:
                result["percent"] = int(m.group(1))
            result["charging"] = "charging" in line or "AC attached" in line
            m2 = re.search(r'(\d+:\d+) remaining', line)
            if m2:
                result["remaining"] = m2.group(1)
        if "AC Power" in line:
            result["source"] = "Strom"
        elif "Battery Power" in line:
            result["source"] = "Akku"
    return result

def get_cpu_ram() -> dict:
    cpu = None
    top_out = run(["top", "-l", "1", "-n", "0", "-s", "0"])
    for line in top_out.splitlines():
        if "CPU usage" in line or "CPU:" in line:
            m = re.search(r'([\d.]+)%\s+user', line)
            m2 = re.search(r'([\d.]+)%\s+sys', line)
            if m and m2:
                cpu = round(float(m.group(1)) + float(m2.group(1)), 1)
            break

    ram_used = None
    ram_total = None
    try:
        vm = run(["vm_stat"])
        page_size = 16384  # Apple Silicon page size
        pages = {}
        for line in vm.splitlines():
            for key in ["Pages free", "Pages active", "Pages inactive",
                        "Pages wired down", "Pages occupied by compressor"]:
                if line.startswith(key):
                    val = re.search(r'(\d+)', line)
                    if val:
                        pages[key] = int(val.group(1))

        used = (pages.get("Pages active", 0) +
                pages.get("Pages wired down", 0) +
                pages.get("Pages occupied by compressor", 0)) * page_size
        ram_used = round(used / (1024**3), 1)

        mem_out = run(["sysctl", "-n", "hw.memsize"])
        if mem_out.strip():
            ram_total = round(int(mem_out.strip()) / (1024**3), 1)
    except Exception:
        pass

    return {"cpu_percent": cpu, "ram_used_gb": ram_used, "ram_total_gb": ram_total}

def get_wifi() -> dict:
    result = {"connected": False, "ssid": None, "signal": None}
    airport = run(["/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport", "-I"])
    for line in airport.splitlines():
        line = line.strip()
        if line.startswith("SSID:"):
            ssid = line.split("SSID:", 1)[-1].strip()
            if ssid and ssid != "":
                result["connected"] = True
                result["ssid"] = ssid
        elif line.startswith("agrCtlRSSI:"):
            m = re.search(r'-(\d+)', line)
            if m:
                result["signal"] = -int(m.group(1))
    if not result["ssid"]:
        out = run(["networksetup", "-getairportnetwork", "en0"])
        if "Current Wi-Fi Network:" in out:
            result["connected"] = True
            result["ssid"] = out.split("Current Wi-Fi Network:")[-1].strip()
    return result

def get_volume() -> dict:
    # Ein einziger osascript-Prozess für beide Werte
    out = run(["osascript", "-e",
               "set s to get volume settings\nreturn (output volume of s as string) & \"|\" & (output muted of s as string)"])
    parts = out.strip().split("|")
    vol = int(parts[0]) if len(parts) > 0 and parts[0].strip().isdigit() else None
    muted = parts[1].strip().lower() == "true" if len(parts) > 1 else False
    return {"volume": vol, "muted": muted}

def set_volume(level: int):
    level = max(0, min(100, int(level)))
    run(["osascript", "-e", f"set volume output volume {level}"])

def set_muted(muted: bool):
    run(["osascript", "-e", f"set volume output muted {'true' if muted else 'false'}"])

def get_gpu_usage() -> dict:
    result = {"gpu_percent": None, "available": False}
    cmd_str = "/usr/bin/sudo powermetrics -n 1 -s gpu_power --format text"
    try:
        out = subprocess.check_output(cmd_str, shell=True, stderr=subprocess.DEVNULL, timeout=8).decode()
    except Exception:
        out = ""
    if out:
        m = re.search(r'GPU HW active residency:\s*([\d.]+)%', out)
        if m:
            result["gpu_percent"] = round(float(m.group(1)), 1)
            result["available"] = True
    return result

def get_processes() -> list:
    out = run(["ps", "aux"])
    procs = []
    for line in out.splitlines()[1:]:
        parts = line.split(None, 10)
        if len(parts) < 11:
            continue
        try:
            cpu = float(parts[2])
            mem = float(parts[3])
            name = parts[10].split("/")[-1][:40]
            if cpu > 0.0 or mem > 0.5:
                procs.append({"name": name, "cpu": cpu, "mem": mem, "pid": parts[1]})
        except ValueError:
            continue
    procs.sort(key=lambda x: x["cpu"], reverse=True)
    return procs[:15]

def get_media_status() -> dict:
    """Liest den aktuellen Track sowie das Album Cover aus Apple Music aus (Absturzsicher)."""
    result = {"playing": False, "title": "Keine Wiedergabe", "artist": "Unbekannt", "position": 0, "duration": 0, "cover": None}
    
    try:
        run_script = 'tell application "Music" to return running as string'
        is_running = run(["osascript", "-e", run_script], timeout=2).strip() == "true"
        if is_running:
            state_script = 'tell application "Music" to return player state as string'
            player_state = run(["osascript", "-e", state_script], timeout=2).strip()
            result["playing"] = player_state == "playing"
            meta_script = 'tell application "Music" to return name of current track & "||" & artist of current track & "||" & player position & "||" & duration of current track'
            meta_out = run(["osascript", "-e", meta_script], timeout=2).strip()
            if "||" in meta_out:
                parts = meta_out.split("||")
                if len(parts) >= 4:
                    result["title"] = parts[0] if parts[0].strip() else "Unbekannter Titel"
                    result["artist"] = parts[1] if parts[1].strip() else "Unbekannter Interpret"
                    try:
                        result["position"] = int(float(parts[2]))
                    except (ValueError, TypeError):
                        result["position"] = 0
                    try:
                        result["duration"] = int(float(parts[3]))
                    except (ValueError, TypeError):
                        result["duration"] = 0
                
            # Album Cover via AppleScript mit striktem Sicherheits-Timeout auslesen
            cover_script = """
            tell application "Music"
                try
                    if exists (artwork 1 of current track) then
                        set rawData to raw data of artwork 1 of current track
                        return rawData
                    end if
                end try
            end tell
            return "none"
            """
            proc = subprocess.Popen(["osascript", "-e", cover_script], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            try:
                cover_bytes, _ = proc.communicate(timeout=2)
                if cover_bytes and b"none" not in cover_bytes and len(cover_bytes) > 100:
                    encoded = base64.b64encode(cover_bytes).decode('utf-8').strip()
                    result["cover"] = encoded
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.communicate()
    except Exception as e:
        logging.error(f"Fehler in get_media_status: {e}")
    return result

def control_media(action, value=None):
    """Steuert Apple Music mit klassischen Vor-/Zurück-Befehlen."""
    cmd = None
    if action == 'playpause' or action == 'play':
        cmd = 'tell application "Music" to playpause'
    elif action == 'next':
        cmd = 'tell application "Music" to next track'
    elif action == 'previous':
        cmd = 'tell application "Music" to previous track'
        
    if cmd:
        run(["osascript", "-e", cmd], timeout=3)

def get_status() -> dict:
    """Sammelt alle Status-Werte und fängt Fehler pro Komponente ab."""
    status = {}
    try: status["battery"] = get_battery()
    except Exception: status["battery"] = {"percent": None, "charging": False, "remaining": None, "source": "Fehler"}
    
    try: status["cpu_ram"] = get_cpu_ram()
    except Exception: status["cpu_ram"] = {"cpu_percent": None, "ram_used_gb": None, "ram_total_gb": None}
    
    try: status["wifi"] = get_wifi()
    except Exception: status["wifi"] = {"connected": False, "ssid": None, "signal": None}
    
    try: status["volume"] = get_volume()
    except Exception: status["volume"] = {"volume": None, "muted": False}
    
    try: status["gpu"] = get_gpu_usage()
    except Exception: status["gpu"] = {"gpu_percent": None, "available": False}
    
    try: status["processes"] = get_processes()
    except Exception: status["processes"] = []
    
    try: status["media"] = get_media_status()
    except Exception: status["media"] = {"playing": False, "title": "Keine Wiedergabe", "artist": "Unbekannt", "position": 0, "duration": 0, "cover": None}
    
    return status

# ── HTTP Handler ──────────────────────────────────────────────────────────────

class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        logging.info(f"{self.client_address[0]} - {format % args}")

    def _read_json(self):
        try:
            length = int(self.headers.get("Content-Length", 0) or 0)
        except (TypeError, ValueError):
            return {}
        if length <= 0:
            return {}
        body = self.rfile.read(length)
        try:
            return json.loads(body)
        except json.JSONDecodeError:
            raise ValueError("Ungültiger JSON-Body")

    def do_GET(self):
        try:
            if self.path == "/":
                self.serve_ui()
            elif self.path == "/status":
                self._send(200, get_status())
            else:
                self._send(404, {"error": "not found"})
        except Exception as e:
            logging.error(f"Fehler in do_GET: {e}")
            try: self._send(500, {"error": "Internal Server Error", "details": str(e)})
            except Exception: pass

    def do_POST(self):
        try:
            if self.path == "/move-doc":
                self.handle_move()
            elif self.path == "/list":
                self.handle_list()
            elif self.path == "/ai-move":
                self.handle_ai_move()
            elif self.path == "/ai-confirm":
                self.handle_ai_confirm()
            elif self.path == "/ai-chat":
                self.handle_ai_chat()
            elif self.path == "/process-file":
                self.handle_process_file()
            elif self.path == "/media-control":
                body = self._read_json()
                control_media(body.get("action"), body.get("value", 0))
                self._send(200, {"ok": True})
            elif self.path == "/volume":
                body = self._read_json()
                level = max(0, min(100, int(body.get("level", 50))))
                set_volume(level)
                self._send(200, {"ok": True})
            elif self.path == "/mute":
                body = self._read_json()
                muted = bool(body.get("muted", False))
                set_muted(muted)
                self._send(200, {"ok": True})
            else:
                self._send(404, {"error": "not found"})
        except Exception as e:
            logging.error(f"Fehler in do_POST: {e}")
            try: self._send(500, {"error": "Internal Server Error", "details": str(e)})
            except Exception: pass

    def handle_move(self):
        body   = self._read_json()
        src    = resolve(body.get("src", ""))
        dst    = resolve(body.get("dst", ""))
        if not is_allowed(src) or not is_allowed(dst):
            self._send(403, {"error": f"Pfad nicht erlaubt: {dst}"}); return
        if not src.exists():
            self._send(400, {"error": f"Datei nicht gefunden: {src}"}); return
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(src), str(dst))
        self._send(200, {"ok": True, "src": str(src), "dst": str(dst)})

    def handle_list(self):
        body   = self._read_json()
        folder = resolve(body.get("path", "~/Downloads"))
        if not is_allowed(folder):
            self._send(403, {"error": "Pfad nicht erlaubt"}); return
        if not folder.exists() or not folder.is_dir():
            self._send(400, {"error": f"Ordner nicht gefunden oder kein Verzeichnis: {folder}"}); return
        files = []
        for f in sorted(folder.iterdir()):
            stat = f.stat()
            files.append({"name": f.name, "path": str(f), "is_dir": f.is_dir(),
                          "modified": stat.st_mtime, "size": stat.st_size})
        self._send(200, {"files": files, "folder": str(folder)})

    def handle_ai_move(self):
        body   = self._read_json()
        prompt = body.get("prompt", "")
        ki_prompt = f"""Du bist ein Datei-Assistent auf einem Mac.
Der Benutzer sagt: "{prompt}"

Aufgaben:
1. Extrahiere Suchbegriffe für den Dateinamen (alternative Schreibweisen, Abkürzungen, Deutsch+Englisch)
2. Erkenne das Ziel in iCloud falls genannt, sonst "icloud:/"
3. Erkenne ob der Benutzer einen bestimmten Quell-Ordner nennt:
   - "Desktop" → "/Users/anton/Desktop"
   - "Downloads" → "/Users/anton/Downloads"
   - "Dokumente" oder "Documents" → "/Users/anton/Documents"
   - "Bilder" oder "Pictures" → "/Users/anton/Pictures"
   - "Filme" oder "Movies" → "/Users/anton/Movies"
   - Absoluter Pfad wie "/Users/anton/..." → direkt übernehmen
   Falls kein Ordner genannt: null

Antworte NUR mit JSON, kein Text davor oder danach:
{{"keywords": ["Begriff1", "Begriff2"], "dst": "icloud:/Ordner", "src_base": "/Users/anton/Desktop"}}"""
        try:
            ki_antwort = ask_ollama(ki_prompt)
        except Exception as e:
            self._send(500, {"error": f"Ollama nicht erreichbar: {str(e)}"}); return
        match = re.search(r'\{.*\}', ki_antwort, re.DOTALL)
        if not match:
            self._send(500, {"error": "Kein JSON", "raw": ki_antwort}); return
        try:
            ki_data = json.loads(match.group())
        except json.JSONDecodeError:
            self._send(500, {"error": "JSON ungültig", "raw": ki_antwort}); return
        keywords = ki_data.get("keywords", [])
        dst      = ki_data.get("dst", "icloud:/")
        src_base = ki_data.get("src_base", None)
        treffer  = search_files(keywords, preferred_base=src_base)
        if not treffer:
            self._send(200, {"status": "nicht_gefunden", "keywords": keywords,
                             "message": f"Keine Dateien gefunden für: {', '.join(keywords)}"}); return
        self._send(200, {"status": "auswahl", "keywords": keywords, "dst": dst,
                         "treffer": [{"index": i+1, "name": t["name"], "path": t["path"]}
                                     for i, t in enumerate(treffer)]})

    def handle_ai_confirm(self):
        body     = self._read_json()
        src_path = resolve(body.get("src", ""))
        dst_path = resolve(body.get("dst", "icloud:/"))
        if not src_path.exists():
            self._send(400, {"error": f"Datei nicht gefunden: {src_path}"}); return
        if not is_allowed(src_path):
            self._send(403, {"error": f"Quelle nicht erlaubt: {src_path}"}); return
        if not is_allowed(dst_path):
            self._send(403, {"error": f"Ziel nicht erlaubt: {dst_path}"}); return
        dst_path.parent.mkdir(parents=True, exist_ok=True)
        final = dst_path / src_path.name if dst_path.is_dir() else dst_path
        shutil.move(str(src_path), str(final))
        self._send(200, {"ok": True, "src": str(src_path), "dst": str(final)})

    def handle_ai_chat(self):
        body       = self._read_json()
        messages   = body.get("messages", [])
        model      = body.get("model", "ibm/granite4:3b")
        image_b64  = body.get("image", None)
        image_mime = body.get("image_mime", "image/jpeg")
        if model not in OLLAMA_MODELS:
            self._send(400, {"error": f"Unbekanntes Modell: {model}"}); return
        if image_b64 and model == "gemma4-vision":
            if messages and messages[-1]["role"] == "user":
                messages[-1]["images"] = [image_b64]
            else:
                messages.append({"role": "user", "content": "", "images": [image_b64]})
        try:
            antwort = chat_ollama(messages, model)
            self._send(200, {"reply": antwort, "model": model})
        except Exception as e:
            self._send(500, {"error": f"Ollama Fehler: {str(e)}"})

    def handle_process_file(self):
        body     = self._read_json()
        mime     = body.get("mime", "")
        data_b64 = body.get("data", "")
        try:
            raw = base64.b64decode(data_b64)
        except Exception:
            self._send(400, {"error": "Ungültige Base64-Daten"}); return
        if mime == "application/pdf":
            self._send(200, pdf_to_content(raw))
        elif mime.startswith("image/"):
            self._send(200, {"type": "image", "base64": data_b64, "mime": mime})
        else:
            self._send(400, {"error": f"Nicht unterstützter Dateityp: {mime}"})

    def serve_ui(self):
        html = r"""<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Mac Agent</title>
<style>
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; -webkit-tap-highlight-color: transparent; }
  html, body { height: 100%; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
    background: #000;
    color: #f2f2f7;
    display: flex;
    flex-direction: column;
    height: 100dvh;
  }

  /* ── Tab-Pill ── */
  .tab-wrap {
    flex-shrink: 0;
    display: flex;
    justify-content: center;
    padding: 12px 16px 8px;
    background: #000;
  }
  .tab-pill {
    display: flex;
    gap: 2px;
    padding: 4px;
    background: rgba(44,44,46,0.95);
    border-radius: 20px;
    box-shadow: 0 2px 16px rgba(0,0,0,0.6), inset 0 0 0 0.5px rgba(255,255,255,0.08);
  }
  .tab {
    padding: 7px 18px;
    border-radius: 16px;
    font-size: 14px;
    font-weight: 500;
    color: #8e8e93;
    cursor: pointer;
    user-select: none;
    transition: background 0.2s, color 0.2s;
    white-space: nowrap;
  }
  .tab.active { background: rgba(255,255,255,0.14); color: #fff; }

  /* ── Modell-Pill ── */
  .model-wrap {
    flex-shrink: 0; display: none;
    justify-content: center;
    padding: 0 16px 8px;
    background: #000;
    overflow-x: auto;
  }
  .model-wrap.visible { display: flex; }
  .model-pill {
    display: flex; gap: 4px; padding: 4px 8px;
    background: rgba(28,28,30,0.95); border-radius: 18px;
    box-shadow: 0 2px 12px rgba(0,0,0,0.5), inset 0 0 0 0.5px rgba(255,255,255,0.07);
  }
  .model-btn {
    background: transparent; border: none; color: #8e8e93;
    padding: 5px 11px; border-radius: 13px;
    font-size: 12px; font-weight: 500; cursor: pointer;
    transition: background 0.18s, color 0.18s; white-space: nowrap;
  }
  .model-btn.active { background: rgba(255,255,255,0.12); color: #fff; }

  /* ── Panels ── */
  .panel { display: none; flex: 1; flex-direction: column; min-height: 0; }
  .panel.active { display: flex; }

  /* ── Chat ── */
  .chat {
    flex: 1; overflow-y: auto; -webkit-overflow-scrolling: touch;
    padding: 12px 16px; display: flex; flex-direction: column; gap: 8px;
  }

  /* ── Nachrichten ── */
  .msg {
    max-width: 82%; padding: 10px 14px; border-radius: 18px;
    font-size: 15px; line-height: 1.5; white-space: pre-wrap; word-break: break-word;
  }
  .msg.user  { background: #0a84ff; align-self: flex-end; border-bottom-right-radius: 4px; }
  .msg.agent { background: #1c1c1e; border: 0.5px solid rgba(255,255,255,0.09); align-self: flex-start; border-bottom-left-radius: 4px; }
  .msg.error { background: #2c1515; border: 0.5px solid #ff453a; align-self: flex-start; color: #ff6961; }
  .loading   { opacity: 0.45; font-style: italic; }
  .msg-img   { max-width: 100%; border-radius: 12px; display: block; margin-bottom: 6px; }

  /* ── Treffer-Buttons ── */
  .treffer-btn {
    display: block; width: 100%; text-align: left;
    background: rgba(255,255,255,0.07); border: 0.5px solid rgba(255,255,255,0.1);
    color: #f2f2f7; padding: 10px 13px; border-radius: 12px;
    margin-top: 6px; font-size: 13.5px; cursor: pointer; transition: background 0.15s;
  }
  .treffer-btn:active, .treffer-btn:hover { background: #0a84ff; }

  /* ── Input-Bereich ── */
  .input-wrap { flex-shrink: 0; padding: 8px 16px 20px; background: #000; }
  .attachment-preview {
    display: none; align-items: center; gap: 8px;
    padding: 6px 12px 6px 10px; background: rgba(44,44,46,0.9);
    border-radius: 14px; margin-bottom: 6px; font-size: 13px; color: #f2f2f7;
  }
  .attachment-preview.visible { display: flex; }
  .attachment-preview img { width: 36px; height: 36px; object-fit: cover; border-radius: 6px; }
  .att-name { flex: 1; opacity: 0.8; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .att-remove {
    background: rgba(255,255,255,0.15); border: none; color: #fff;
    border-radius: 50%; width: 22px; height: 22px; font-size: 13px;
    cursor: pointer; display: flex; align-items: center; justify-content: center;
  }
  .input-pill {
    display: flex; align-items: center; gap: 8px;
    background: rgba(44,44,46,0.95); border-radius: 28px;
    padding: 8px 8px 8px 12px;
    box-shadow: 0 4px 20px rgba(0,0,0,0.6), inset 0 0 0 0.5px rgba(255,255,255,0.08);
  }
  .attach-btn {
    background: rgba(255,255,255,0.1); border: none; border-radius: 50%;
    width: 32px; height: 32px; color: #f2f2f7; font-size: 18px;
    cursor: pointer; flex-shrink: 0; display: none;
    align-items: center; justify-content: center; transition: background 0.15s;
  }
  .attach-btn.visible { display: flex; }
  .attach-btn:active { background: rgba(255,255,255,0.2); }
  .input-pill input {
    flex: 1; background: transparent; border: none; color: #f2f2f7;
    font-size: 15px; outline: none; caret-color: #0a84ff; min-width: 0;
  }
  .input-pill input::placeholder { color: #48484a; }
  .send-btn {
    background: #0a84ff; border: none; border-radius: 50%;
    width: 34px; height: 34px; color: #fff; font-size: 18px;
    cursor: pointer; flex-shrink: 0;
    display: flex; align-items: center; justify-content: center; transition: opacity 0.15s;
  }
  .send-btn:active { opacity: 0.7; }

  /* ── Dashboard ── */
  .dashboard {
    flex: 1; overflow-y: auto; -webkit-overflow-scrolling: touch;
    padding: 12px 16px 24px; display: flex; flex-direction: column; gap: 12px;
  }
  .dash-card {
    background: #1c1c1e; border: 0.5px solid rgba(255,255,255,0.08);
    border-radius: 16px; padding: 14px 16px;
  }
  
  /* ── Apple Music Card ── */
  .media-card {
    background: #1c1c1e; border: 0.5px solid rgba(255,255,255,0.08);
    border-radius: 16px; padding: 16px; display: flex; flex-direction: column; align-items: center; text-align: center;
  }
  .media-cover-wrap {
    width: 110px; height: 110px; background: #2c2c2e; border-radius: 12px; 
    margin-bottom: 12px; box-shadow: 0 4px 14px rgba(0,0,0,0.4); display: flex; align-items: center; justify-content: center; overflow: hidden;
  }
  .media-cover { width: 100%; height: 100%; object-fit: cover; }
  .media-title-wrap { width: 100%; overflow: hidden; position: relative; }
  .media-title { font-size: 16px; font-weight: 600; color: #fff; margin-bottom: 2px; min-width: 100%; width: auto; display: inline-block; white-space: nowrap; text-decoration: none; }
  .media-title.marquee { animation-name: marquee; animation-timing-function: linear; animation-iteration-count: infinite; }
  .media-artist { font-size: 14px; color: #8e8e93; margin-bottom: 12px; width: 100%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  @keyframes marquee {
    0%, 10% { transform: translateX(0); }
    90%, 100% { transform: translateX(var(--marquee-offset, 0)); }
  }
  .media-controls { display: flex; align-items: center; justify-content: center; gap: 24px; width: 100%; margin-top: 4px; }
  .media-ctrl-btn {
    background: rgba(255,255,255,0.08);
    border: 1px solid rgba(255,255,255,0.14);
    box-shadow: 0 18px 45px rgba(0,0,0,0.15);
    color: #fff;
    width: 44px;
    height: 44px;
    border-radius: 14px;
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    transition: transform 0.15s ease, background 0.15s ease, box-shadow 0.15s ease;
    font-size: 18px;
  }
  .media-ctrl-btn:hover {
    transform: translateY(-1px);
    background: rgba(255,255,255,0.14);
  }
  .media-ctrl-btn:active {
    transform: translateY(0);
    box-shadow: 0 10px 24px rgba(0,0,0,0.18);
  }
  .media-ctrl-btn.playpause { width: 52px; height: 52px; font-size: 22px; }
  .media-cover-placeholder {
    width: 90px; height: 90px; display: flex; align-items: center; justify-content: center;
    background: rgba(255,255,255,0.05); border-radius: 16px; color: #8e8e93; font-size: 30px;
  }
  .media-cover-placeholder {
    width: 90px; height: 90px; display: flex; align-items: center; justify-content: center;
    background: rgba(255,255,255,0.05); border-radius: 16px; color: #8e8e93; font-size: 30px;
  }

  .dash-card-title {
    font-size: 12px; font-weight: 600; color: #8e8e93;
    text-transform: uppercase; letter-spacing: 0.5px; margin-bottom: 10px;
  }
  .dash-row {
    display: flex; align-items: center; justify-content: space-between;
    font-size: 15px; margin-bottom: 6px;
  }
  .dash-row:last-child { margin-bottom: 0; }
  .dash-label { color: #8e8e93; font-size: 13px; }
  .dash-value { font-weight: 500; }
  .dash-accent { color: #30d158; }
  .dash-warn   { color: #ff9f0a; }
  .dash-danger { color: #ff453a; }

  /* Progress Bar */
  .progress-wrap { margin: 10px 0 16px; }
  .progress-bg {
    background: rgba(255,255,255,0.1); border-radius: 4px; height: 6px; overflow: hidden;
  }
  .progress-fill {
    height: 100%; border-radius: 4px; transition: width 0.5s ease;
    background: #30d158;
  }
  .progress-fill.warn   { background: #ff9f0a; }
  .progress-fill.danger { background: #ff453a; }
  .progress-fill.blue   { background: #0a84ff; }


  .dash-refresh { font-size: 11px; color: #48484a; text-align: center; margin-top: 4px; }
  .temp-unavail { font-size: 12px; color: #8e8e93; font-style: italic; }

  /* Versteckter File-Input */
  #file-pick { display: none; }

  /* ── Volume Slider ── */
  .volume-row {
    display: flex; align-items: center; gap: 12px; margin-top: 10px;
  }
  .volume-icon { font-size: 18px; flex-shrink: 0; cursor: pointer; user-select: none; }
  .volume-slider-wrap { flex: 1; position: relative; height: 28px; display: flex; align-items: center; }
  .volume-slider {
    -webkit-appearance: none; appearance: none;
    width: 100%; height: 6px; border-radius: 3px; outline: none; cursor: pointer;
    background: linear-gradient(to right, #0a84ff var(--vol-pct, 50%), rgba(255,255,255,0.15) var(--vol-pct, 50%));
  }
  .volume-slider::-webkit-slider-thumb {
    -webkit-appearance: none; appearance: none;
    width: 22px; height: 22px; border-radius: 50%;
    background: #fff; box-shadow: 0 2px 8px rgba(0,0,0,0.5);
    cursor: pointer; transition: transform 0.1s;
  }
  .volume-slider:active::-webkit-slider-thumb { transform: scale(1.15); }
  .volume-label { font-size: 13px; color: #8e8e93; min-width: 30px; text-align: right; flex-shrink: 0; }
</style>
</head>
<body>

<div class="tab-wrap">
  <div class="tab-pill">
    <div class="tab active" id="tab-agent">🖥 Agent</div>
    <div class="tab" id="tab-aichat">🤖 KI Chat</div>
    <div class="tab" id="tab-dash">📊 Dashboard</div>
  </div>
</div>

<div class="model-wrap" id="model-wrap">
  <div class="model-pill">
    <button class="model-btn active" id="btn-vision">gemma4 👁</button>
    <button class="model-btn" id="btn-gemma">gemma4</button>
    <button class="model-btn" id="btn-granite">granite4</button>
    <button class="model-btn" id="btn-qwen">qwen3</button>
    <button class="model-btn" id="btn-phi">phi3</button>
  </div>
</div>

<div class="panel active" id="panel-agent">
  <div class="chat" id="chat-agent"></div>
  <div class="input-wrap">
    <div class="input-pill">
      <input id="input-agent" type="text" placeholder="Verschiebe PDF Skript Rom nach iCloud…" autocomplete="off" />
      <button class="send-btn" id="send-agent">↑</button>
    </div>
  </div>
</div>

<div class="panel" id="panel-aichat">
  <div class="chat" id="chat-aichat"></div>
  <div class="input-wrap">
    <div class="attachment-preview" id="att-preview">
      <img id="att-thumb" src="" alt="" />
      <span class="att-name" id="att-name"></span>
      <button class="att-remove" id="att-remove">✕</button>
    </div>
    <div class="input-pill">
      <button class="attach-btn" id="attach-btn">＋</button>
      <input id="input-aichat" type="text" placeholder="Schreib eine Nachricht…" autocomplete="off" />
      <button class="send-btn" id="send-aichat">↑</button>
    </div>
  </div>
</div>

<div class="panel" id="panel-dash">
  <div class="dashboard" id="dashboard">
    <div style="color:#8e8e93;font-size:14px;text-align:center;padding-top:40px">Lade…</div>
  </div>
</div>

<input type="file" id="file-pick" accept="image/*,application/pdf" />

<script>
// ── Tabs ──────────────────────────────────────────────────
let dashInterval = null;

function switchTab(name) {
  ['agent','aichat','dash'].forEach(t => {
    document.getElementById('tab-'   + t).classList.toggle('active', t === name);
    document.getElementById('panel-' + t).classList.toggle('active', t === name);
  });
  document.getElementById('model-wrap').classList.toggle('visible', name === 'aichat');

  if (name === 'dash') {
    loadDashboard();
    if (!dashInterval) dashInterval = setInterval(loadDashboard, 8000);
  } else {
    if (dashInterval) { clearInterval(dashInterval); dashInterval = null; }
    setTimeout(() => document.getElementById('input-' + (name === 'agent' ? 'agent' : 'aichat')).focus(), 100);
  }
}

document.getElementById('tab-agent').addEventListener('click',  () => switchTab('agent'));
document.getElementById('tab-aichat').addEventListener('click', () => switchTab('aichat'));
document.getElementById('tab-dash').addEventListener('click',   () => switchTab('dash'));

// ── Dashboard ─────────────────────────────────────────────
function colorClass(val, warn, danger) {
  if (val >= danger) return 'dash-danger';
  if (val >= warn)   return 'dash-warn';
  return 'dash-accent';
}
function progressClass(val, warn, danger) {
  if (val >= danger) return 'danger';
  if (val >= warn)   return 'warn';
  return '';
}
function renderMediaCard(media) {
  const coverSrc = media.cover ? `data:image/jpeg;base64,${media.cover}` : '';
  return `
      <div class="media-card" id="media-card">
        <div class="dash-card-title" style="align-self: flex-start;">Apple Music</div>
        <div class="media-cover-wrap">
          <img id="media-cover-img" class="media-cover" src="${coverSrc}" alt="Cover" style="display:${coverSrc? 'block':'none'}" onerror="this.style.display='none';document.getElementById('media-cover-placeholder').style.display='flex';this.dataset.valid='0'" />
          <div id="media-cover-placeholder" class="media-cover-placeholder" style="display:${coverSrc? 'none':'flex'}">🎵</div>
        </div>
        <div id="media-title-wrap">
          <a id="media-title-link" class="media-title" href="${media.title ? 'https://music.apple.com/search?term=' + encodeURIComponent((media.artist||'') + ' ' + (media.title||'')) : '#'}" target="_blank" rel="noopener noreferrer">${media.title || 'Keine Wiedergabe'}</a>
        </div>
        <div id="media-artist" class="media-artist">${media.artist || 'Unbekannt'}</div>
        <div class="media-controls">
          <button id="media-prev" class="media-ctrl-btn" onclick="sendMediaAction('previous')" aria-label="Vorheriger Titel">◀◀</button>
          <button id="media-playpause" class="media-ctrl-btn playpause" onclick="sendMediaAction('playpause')" aria-label="Play/Pause">${media.playing ? 'II' : '▶'}</button>
          <button id="media-next" class="media-ctrl-btn" onclick="sendMediaAction('next')" aria-label="Nächster Titel">▶▶</button>
        </div>
      </div>`;
}

// Aktualisiert die Media-Card in-place ohne DOM-Rebuild
function updateMediaCard(media) {
  const titleLink = document.getElementById('media-title-link');
  const artistEl  = document.getElementById('media-artist');
  if (titleLink && media.title !== undefined) {
    titleLink.textContent = media.title || 'Keine Wiedergabe';
    titleLink.href = media.title ? ('https://music.apple.com/search?term=' + encodeURIComponent((media.artist||'') + ' ' + (media.title||''))) : '#';
  }
  if (artistEl && media.artist !== undefined) artistEl.textContent = media.artist || 'Unbekannt';
  const titleWrap = document.getElementById('media-title-wrap');
  if (titleLink && titleWrap) {
    const overflow = titleLink.scrollWidth - titleWrap.clientWidth;
    if (overflow > 10) {
      titleLink.style.setProperty('--marquee-offset', `-${overflow}px`);
      const duration = Math.max(8, overflow / 15 + 8);
      titleLink.style.animationDuration = `${duration}s`;
      titleLink.classList.add('marquee');
    } else {
      titleLink.classList.remove('marquee');
      titleLink.style.removeProperty('--marquee-offset');
      titleLink.style.removeProperty('animation-duration');
    }
  }
  const pp = document.getElementById('media-playpause');
  if (pp) pp.textContent = media.playing ? 'II' : '▶';
  const img = document.getElementById('media-cover-img');
  const placeholder = document.getElementById('media-cover-placeholder');
  if (img) {
    const newSrc = media.cover ? `data:image/jpeg;base64,${media.cover}` : '';
    if (newSrc) {
      if (img.src !== newSrc) {
        img.dataset.valid = '1';
        img.style.display = 'block';
        img.src = newSrc;
        if (placeholder) placeholder.style.display = 'none';
      }
    } else {
      img.style.display = 'none';
      if (placeholder) placeholder.style.display = 'flex';
    }
  }
}

async function sendMediaAction(action) {
    try {
        const res = await fetch('/media-control', { 
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ action: action })
        });
        if (!res.ok) throw new Error(`Server antwortete mit Status ${res.status}`);
    } catch (e) {
        console.error("Dashboard-Fehler:", e);
    }
}

// ── Lautstärke ───────────────────────────────────────────
// Lokaler State — kein extra /status-Fetch nötig
let volState = { volume: 50, muted: false };
let volDebounceTimer = null;
let volDragging = false;

function _applyVolUI(volume, muted) {
  const slider = document.getElementById('vol-slider');
  const label  = document.getElementById('vol-label');
  const icon   = document.getElementById('vol-mute-btn');
  if (!slider) return;
  const display = muted ? 0 : volume;
  slider.value = display;
  slider.style.setProperty('--vol-pct', display + '%');
  if (label) label.textContent = muted ? '🔇' : display + '%';
  if (icon)  icon.textContent  = muted ? '🔇' : (display > 50 ? '🔊' : display > 0 ? '🔉' : '🔈');
}

function onVolSlider(val) {
  volDragging = true;
  const pct = parseInt(val);
  // UI sofort aktualisieren — ohne auf den Server zu warten
  const slider = document.getElementById('vol-slider');
  const label  = document.getElementById('vol-label');
  const icon   = document.getElementById('vol-mute-btn');
  if (slider) slider.style.setProperty('--vol-pct', pct + '%');
  if (label)  label.textContent = pct + '%';
  if (icon)   icon.textContent  = pct > 50 ? '🔊' : pct > 0 ? '🔉' : '🔈';
  // Debounce: Request erst 150ms nach letzter Bewegung absenden
  clearTimeout(volDebounceTimer);
  volDebounceTimer = setTimeout(async () => {
    volDragging = false;
    volState.volume = pct;
    volState.muted  = false;
    try {
      await fetch('/volume', {
        method: 'POST', headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({level: pct})
      });
    } catch(e) { console.error('Volume error:', e); }
  }, 150);
}

async function toggleMute() {
  // Lokalen State verwenden — kein Round-Trip zu /status nötig
  const newMuted = !volState.muted;
  volState.muted = newMuted;
  _applyVolUI(volState.volume, newMuted);
  try {
    await fetch('/mute', {
      method: 'POST', headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({muted: newMuted})
    });
  } catch(e) { console.error('Mute error:', e); }
}

function updateVolumeCard(vol) {
  if (volDragging) return; // Slider gerade bedient → nicht überschreiben
  volState.volume = vol.volume ?? volState.volume;
  volState.muted  = vol.muted;
  _applyVolUI(volState.volume, volState.muted);
}

async function loadDashboard() {
  try {
    const res  = await fetch('/status');
    const d    = await res.json();
    const dash = document.getElementById('dashboard');

    const dashScroll = dash ? dash.scrollTop : 0;
    const isFirstLoad = !document.getElementById('media-card');

    const bat   = d.battery;
    const cr    = d.cpu_ram;
    const wifi  = d.wifi;
    const vol   = d.volume;
    const gpu   = d.gpu;
    const media = d.media;

    const batPct  = bat.percent ?? 0;
    const cpuPct  = cr.cpu_percent ?? 0;
    const ramUsed = cr.ram_used_gb ?? 0;
    const ramTot  = cr.ram_total_gb ?? 1;
    const ramPct  = Math.round((ramUsed / ramTot) * 100);

    let gpuHTML = '';
    if (gpu.available && gpu.gpu_percent !== null) {
      const gp = gpu.gpu_percent;
      const gc = gp >= 85 ? 'dash-danger' : gp >= 60 ? 'dash-warn' : 'dash-accent';
      const fillClass = gp >= 85 ? 'danger' : gp >= 60 ? 'warn' : '';
      gpuHTML = `
        <div class="dash-row">
          <span class="dash-label">🎮 GPU</span>
          <span class="dash-value ${gc}">${gp}%</span>
        </div>
        <div class="progress-wrap">
          <div class="progress-bg">
            <div class="progress-fill ${fillClass} blue" style="width:${gp}%"></div>
          </div>
        </div>`;
    } else {
      gpuHTML = `
        <div class="dash-row">
          <span class="dash-label">🎮 GPU Auslastung</span>
          <span class="temp-unavail">Nicht verfügbar</span>
        </div>`;
    }

    if (isFirstLoad) {
      // Erstes Laden: komplettes DOM aufbauen
      dash.innerHTML = `
        <div class="dash-card" id="dc-battery">
          <div class="dash-card-title">Akku & Energie</div>
          <div class="dash-row">
            <span class="dash-label">🔋 Ladezustand</span>
            <span class="dash-value" id="dc-bat-pct"></span>
          </div>
          <div class="progress-wrap">
            <div class="progress-bg"><div class="progress-fill" id="dc-bat-bar"></div></div>
          </div>
          <div class="dash-row" style="margin-top:8px">
            <span class="dash-label">⚡ Status</span>
            <span class="dash-value" id="dc-bat-status"></span>
          </div>
          <div class="dash-row" id="dc-bat-remaining-row">
            <span class="dash-label">⏱ Verbleibend</span>
            <span class="dash-value" id="dc-bat-remaining"></span>
          </div>
        </div>

        <div id="media-section">${renderMediaCard(media)}</div>

        <div class="dash-card" id="volume-card">
          <div class="dash-card-title">Lautstärke</div>
          <div class="volume-row">
            <span class="volume-icon" id="vol-mute-btn" onclick="toggleMute()" title="Stummschalten">🔊</span>
            <div class="volume-slider-wrap">
              <input type="range" class="volume-slider" id="vol-slider"
                min="0" max="100" value="50"
                style="--vol-pct:50%"
                oninput="onVolSlider(this.value)" />
            </div>
            <span class="volume-label" id="vol-label">50%</span>
          </div>
        </div>

        <div class="dash-card" id="dc-perf">
          <div class="dash-card-title">Leistung</div>
          <div class="dash-row">
            <span class="dash-label">💻 CPU</span>
            <span class="dash-value" id="dc-cpu"></span>
          </div>
          <div class="progress-wrap">
            <div class="progress-bg"><div class="progress-fill blue" id="dc-cpu-bar"></div></div>
          </div>
          <div class="dash-row" style="margin-top:8px">
            <span class="dash-label">🧠 RAM</span>
            <span class="dash-value" id="dc-ram"></span>
          </div>
          <div class="progress-wrap">
            <div class="progress-bg"><div class="progress-fill" id="dc-ram-bar"></div></div>
          </div>
          <div id="dc-gpu">${gpuHTML}</div>
        </div>

        <div class="dash-refresh" id="dc-refresh">Aktualisiert alle 8 s</div>
      `;
    } else {
      // Folge-Updates: nur Werte patchen, kein DOM-Rebuild
      document.getElementById('dc-gpu').innerHTML = gpuHTML;
      updateMediaCard(media);
    }

    // Akku-Werte immer patchen
    const batPctEl  = document.getElementById('dc-bat-pct');
    const batBarEl  = document.getElementById('dc-bat-bar');
    const batStatEl = document.getElementById('dc-bat-status');
    const batRemRow = document.getElementById('dc-bat-remaining-row');
    const batRemEl  = document.getElementById('dc-bat-remaining');
    if (batPctEl)  { batPctEl.className = 'dash-value ' + colorClass(100-batPct, 30, 50); batPctEl.textContent = batPct + '%'; }
    if (batBarEl)  { batBarEl.className = 'progress-fill ' + progressClass(100-batPct, 30, 50); batBarEl.style.width = batPct + '%'; }
    if (batStatEl) batStatEl.textContent = bat.charging ? '🟢 Lädt' : '🔌 ' + bat.source;
    if (batRemRow) batRemRow.style.display = bat.remaining ? '' : 'none';
    if (batRemEl && bat.remaining) batRemEl.textContent = bat.remaining + ' h';

    // CPU/RAM immer patchen
    const cpuEl    = document.getElementById('dc-cpu');
    const cpuBar   = document.getElementById('dc-cpu-bar');
    const ramEl    = document.getElementById('dc-ram');
    const ramBar   = document.getElementById('dc-ram-bar');
    if (cpuEl)  { cpuEl.className = 'dash-value ' + colorClass(cpuPct, 60, 85); cpuEl.textContent = (cpuPct ?? '—') + '%'; }
    if (cpuBar) { cpuBar.className = 'progress-fill blue ' + progressClass(cpuPct, 60, 85); cpuBar.style.width = cpuPct + '%'; }
    if (ramEl)  { ramEl.className = 'dash-value ' + colorClass(ramPct, 75, 90); ramEl.textContent = ramUsed + ' / ' + ramTot + ' GB'; }
    if (ramBar) { ramBar.className = 'progress-fill ' + progressClass(ramPct, 75, 90); ramBar.style.width = ramPct + '%'; }

    // Lautstärke
    updateVolumeCard(vol);

    if (dash) dash.scrollTop = dashScroll;

  } catch(e) {
    document.getElementById('dashboard').innerHTML =
      `<div class="msg error">⚠️ Dashboard-Fehler: ${e.message}</div>`;
  }
}

// ── Nachrichten ───────────────────────────────────────────
function addMsg(chatId, text, cls) {
  const d = document.createElement('div');
  d.className = 'msg ' + cls;
  d.textContent = text;
  document.getElementById(chatId).appendChild(d);
  d.scrollIntoView({behavior: 'smooth', block: 'end'});
  return d;
}
function addHTML(chatId, html, cls) {
  const d = document.createElement('div');
  d.className = 'msg ' + cls;
  d.innerHTML = html;
  document.getElementById(chatId).appendChild(d);
  d.scrollIntoView({behavior: 'smooth', block: 'end'});
  return d;
}
function addImageMsg(chatId, b64, mime, caption) {
  const d = document.createElement('div');
  d.className = 'msg user';
  if (caption) { const t = document.createElement('div'); t.style.marginBottom='6px'; t.textContent=caption; d.appendChild(t); }
  const img = document.createElement('img');
  img.className = 'msg-img';
  img.src = `data:${mime};base64,${b64}`;
  d.appendChild(img);
  document.getElementById(chatId).appendChild(d);
  d.scrollIntoView({behavior: 'smooth', block: 'end'});
}

// ── Mac Agent ─────────────────────────────────────────────
let pendingDst = null;

async function agentSend() {
  const input = document.getElementById('input-agent');
  const text  = input.value.trim();
  if (!text) return;
  input.value = '';
  addMsg('chat-agent', text, 'user');
  const loading = addMsg('chat-agent', 'Denke nach…', 'agent loading');
  try {
    const res  = await fetch('/ai-move', {
      method: 'POST', headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({prompt: text})
    });
    const data = await res.json();
    loading.remove();
    if (data.status === 'auswahl') {
      pendingDst = data.dst;
      let html = `<span style="font-size:12px;opacity:0.5">Suchbegriffe: ${data.keywords.join(', ')}</span><br><br>Welche Datei meinst du?`;
      data.treffer.forEach(t => {
        html += `<button class="treffer-btn" data-path="${t.path.replace(/&/g,'&amp;').replace(/"/g,'&quot;')}">📄 <b>${t.name}</b><br><span style="opacity:0.45;font-size:12px">${t.path}</span></button>`;
      });
      const el = addHTML('chat-agent', html, 'agent');
      el.querySelectorAll('.treffer-btn').forEach(btn => {
        btn.addEventListener('click', () => confirmMove(btn.dataset.path));
      });
    } else if (data.status === 'nicht_gefunden') {
      addMsg('chat-agent', '❌ ' + data.message, 'agent');
    } else if (data.error) {
      addMsg('chat-agent', '⚠️ ' + data.error, 'error');
    }
  } catch(e) {
    loading.remove();
    addMsg('chat-agent', '⚠️ Verbindungsfehler: ' + e.message, 'error');
  }
}

async function confirmMove(src) {
  addMsg('chat-agent', '📄 ' + src.split('/').pop(), 'user');
  const loading = addMsg('chat-agent', 'Verschiebe…', 'agent loading');
  try {
    const res  = await fetch('/ai-confirm', {
      method: 'POST', headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({src: src, dst: pendingDst || 'icloud:/'})
    });
    const data = await res.json();
    loading.remove();
    if (data.ok) {
      addMsg('chat-agent', '✅ Verschoben nach:\n' + data.dst, 'agent');
    } else {
      addMsg('chat-agent', '❌ ' + (data.error || 'Unbekannter Fehler'), 'error');
    }
  } catch(e) {
    loading.remove();
    addMsg('chat-agent', '⚠️ Verbindungsfehler: ' + e.message, 'error');
  }
}

document.getElementById('send-agent').addEventListener('click', agentSend);
document.getElementById('input-agent').addEventListener('keydown', e => { if (e.key==='Enter') agentSend(); });

// ── AI Chat ───────────────────────────────────────────────
let currentModel = 'gemma4-vision';
let chatHistory  = [];
let pendingAttachment = null;

const modelMap = {
  'btn-vision':  'gemma4-vision',
  'btn-gemma':   'gemma4',
  'btn-granite': 'ibm/granite4:3b',
  'btn-qwen':    'qwen3:4b',
  'btn-phi':     'phi3:mini',
};

function updateAttachBtn() {
  document.getElementById('attach-btn').classList.toggle('visible', currentModel === 'gemma4-vision');
}

Object.entries(modelMap).forEach(([btnId, model]) => {
  document.getElementById(btnId).addEventListener('click', () => {
    currentModel = model;
    chatHistory  = [];
    clearAttachment();
    document.querySelectorAll('.model-btn').forEach(b => b.classList.remove('active'));
    document.getElementById(btnId).classList.add('active');
    updateAttachBtn();
    addMsg('chat-aichat', `Modell gewechselt: ${model}`, 'agent');
  });
});

document.getElementById('attach-btn').addEventListener('click', () => {
  document.getElementById('file-pick').click();
});

function clearAttachment() {
  pendingAttachment = null;
  const preview = document.getElementById('att-preview');
  preview.classList.remove('visible');
  document.getElementById('att-thumb').src = '';
  document.getElementById('att-thumb').style.display = '';
  document.getElementById('att-name').textContent = '';
  document.getElementById('file-pick').value = '';
}
document.getElementById('att-remove').addEventListener('click', clearAttachment);

document.getElementById('file-pick').addEventListener('change', async e => {
  const file = e.target.files[0];
  if (!file) return;
  const loading = addMsg('chat-aichat', `Verarbeite ${file.name}…`, 'agent loading');
  const b64 = await new Promise((res, rej) => {
    const r = new FileReader();
    r.onload  = () => res(r.result.split(',')[1]);
    r.onerror = () => rej(new Error('Lesefehler'));
    r.readAsDataURL(file);
  });
  try {
    const resp   = await fetch('/process-file', {
      method: 'POST', headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({filename: file.name, mime: file.type, data: b64})
    });
    const result = await resp.json();
    loading.remove();
    if (result.error) { addMsg('chat-aichat', '⚠️ ' + result.error, 'error'); return; }
    if (result.type === 'image') {
      pendingAttachment = {type: 'image', base64: result.base64, mime: result.mime, name: file.name};
      document.getElementById('att-thumb').src = `data:${result.mime};base64,${result.base64}`;
      document.getElementById('att-thumb').style.display = '';
      document.getElementById('att-name').textContent = file.name;
      document.getElementById('att-preview').classList.add('visible');
    } else if (result.type === 'text') {
      pendingAttachment = {type: 'text', text: result.text, name: file.name};
      document.getElementById('att-thumb').style.display = 'none';
      document.getElementById('att-name').textContent = `📄 ${file.name} (Text)`;
      document.getElementById('att-preview').classList.add('visible');
    }
  } catch(e) {
    loading.remove();
    addMsg('chat-aichat', '⚠️ ' + e.message, 'error');
  }
});

async function chatSend() {
  const input = document.getElementById('input-aichat');
  const text  = input.value.trim();
  if (!text && !pendingAttachment) return;
  input.value = '';
  const userMsg = {role: 'user', content: text || ''};
  let requestBody = {messages: [...chatHistory, userMsg], model: currentModel};
  if (pendingAttachment) {
    if (pendingAttachment.type === 'image') {
      addImageMsg('chat-aichat', pendingAttachment.base64, pendingAttachment.mime, text || null);
      requestBody.image      = pendingAttachment.base64;
      requestBody.image_mime = pendingAttachment.mime;
    } else {
      userMsg.content = (text ? text + '\n\n' : '') + `[${pendingAttachment.name}]:\n${pendingAttachment.text}`;
      requestBody.messages = [...chatHistory, userMsg];
      addMsg('chat-aichat', text || `📄 ${pendingAttachment.name}`, 'user');
    }
    clearAttachment();
  } else {
    addMsg('chat-aichat', text, 'user');
  }
  chatHistory.push(userMsg);
  const loading = addMsg('chat-aichat', `${currentModel} denkt nach…`, 'agent loading');
  try {
    const res  = await fetch('/ai-chat', {
      method: 'POST', headers: {'Content-Type': 'application/json'},
      body: JSON.stringify(requestBody)
    });
    const data = await res.json();
    loading.remove();
    if (data.reply) {
      chatHistory.push({role: 'assistant', content: data.reply});
      addMsg('chat-aichat', data.reply, 'agent');
    } else if (data.error) {
      chatHistory.pop();
      addMsg('chat-aichat', '⚠️ ' + data.error, 'error');
    }
  } catch(e) {
    loading.remove();
    chatHistory.pop();
    addMsg('chat-aichat', '⚠️ Verbindungsfehler: ' + e.message, 'error');
  }
}

document.getElementById('send-aichat').addEventListener('click', chatSend);
document.getElementById('input-aichat').addEventListener('keydown', e => { if (e.key==='Enter') chatSend(); });

updateAttachBtn();
</script>
</body>
</html>""".encode()

        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", len(html))
        self.end_headers()
        self.wfile.write(html)

    def _send(self, code, data):
        body = json.dumps(data, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)

if __name__ == "__main__":
    # Umstellung auf Threading-Server, um Blockaden bei mehreren Geräten (z.B. iPhone über Tailscale) zu verhindern
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    logging.info(f"Agent läuft auf Port {PORT} — iCloud: {ICLOUD_BASE}")
    server.serve_forever()