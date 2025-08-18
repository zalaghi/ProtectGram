import os, time, logging, requests, io, datetime
from flask import Flask, request, abort, jsonify
from urllib3.exceptions import InsecureRequestWarning
from PIL import Image, ImageDraw, ImageFont
from zoneinfo import ZoneInfo
import urllib3
urllib3.disable_warnings(InsecureRequestWarning)

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")

BASE = os.environ.get("UNIFI_ADDR", "").rstrip("/")
API_KEY = os.environ.get("UNIFI_API_KEY", "")
UNAME   = os.environ.get("UNIFI_USERNAME", "")
UPASS   = os.environ.get("UNIFI_PASSWORD", "")
TELEGRAM_TOKEN = os.environ.get("TELEGRAM_TOKEN", "")
TELEGRAM_CHAT  = os.environ.get("TELEGRAM_CHAT", "")
WEBHOOK_TOKEN  = os.environ.get("WEBHOOK_TOKEN", "")

_session_token = None
_session_token_time = 0

def _headers(mode: str):
    token = API_KEY or _session_token or ""
    if mode == "bearer" and token:
        return {"Authorization": f"Bearer {token}"}
    if mode == "cookie" and token:
        return {"Cookie": f"TOKEN={token}"}
    return {}

def _login_with_password():
    global _session_token, _session_token_time
    if not (UNAME and UPASS and BASE):
        raise RuntimeError("UNIFI_ADDR/UNIFI_USERNAME/UNIFI_PASSWORD not set")
    url = f"{BASE}/api/auth/login"
    r = requests.post(url, json={"username": UNAME, "password": UPASS}, timeout=20, verify=False)
    r.raise_for_status()
    token = r.cookies.get("TOKEN")
    if not token:
        try:
            j = r.json()
            token = j.get("access_token") or j.get("token") or token
        except Exception:
            pass
    if not token:
        raise RuntimeError("Login succeeded but no TOKEN cookie found")
    _session_token = token
    _session_token_time = time.time()
    logging.info("Obtained session token via password login")

def _ensure_auth():
    if API_KEY:
        return
    if (not _session_token) or (time.time() - _session_token_time > 12*3600):
        _login_with_password()

def _get(url: str):
    last = None
    if not API_KEY and UNAME and UPASS:
        try:
            _ensure_auth()
        except Exception as e:
            last = e
    for mode in ("bearer", "cookie"):
        try:
            r = requests.get(url, headers=_headers(mode), timeout=25, verify=False)
            if r.ok:
                return r
            last = r
        except Exception as e:
            last = e
    if hasattr(last, "raise_for_status"):
        last.raise_for_status()
    raise RuntimeError(f"Failed GET {url}: {last}")

def _normalize_cam_list(data):
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        for k in ("cameras", "data", "items", "results"):
            v = data.get(k)
            if isinstance(v, list):
                return v
        vals = list(data.values())
        if all(isinstance(v, dict) for v in vals):
            return vals
    return []


def _json(url: str):
    r = _get(url)
    try:
        return r.json()
    except Exception as e:
        raise RuntimeError(f"Invalid JSON from {url}: {e}")

def _pick_camera_list(obj):
    # Return a list of camera-like dicts from various Protect responses
    def looks_like_cam(d):
        return isinstance(d, dict) and any(k in d for k in ("id","_id","uuid","mac")) and any(k in d for k in ("name","displayName","marketName","type","modelKey"))
    if isinstance(obj, list):
        return [c for c in obj if looks_like_cam(c)]
    if isinstance(obj, dict):
        # direct keys
        for k in ("cameras","data","items","results"):
            v = obj.get(k)
            if isinstance(v, list):
                cams = [c for c in v if looks_like_cam(c)]
                if cams:
                    return cams
        # flatten nested dict-of-dicts or dict-of-lists
        for v in obj.values():
            if isinstance(v, list):
                cams = [c for c in v if looks_like_cam(c)]
                if cams:
                    return cams
            if isinstance(v, dict):
                for vv in v.values():
                    if isinstance(vv, list):
                        cams = [c for c in vv if looks_like_cam(c)]
                        if cams:
                            return cams
    return []

def list_cameras():
    if not BASE:
        raise RuntimeError("UNIFI_ADDR not configured")
    endpoints = [
        f"{BASE}/proxy/protect/api/cameras",
        f"{BASE}/proxy/protect/api/bootstrap",
        f"{BASE}/proxy/protect/v1/cameras",
    ]
    last_err = None
    for url in endpoints:
        try:
            data = _json(url)
            cams = _pick_camera_list(data)
            if cams:
                return cams
        except Exception as e:
            last_err = e
    # As a last attempt, try bootstrap again after ensuring auth
    try:
        _ensure_auth()
        data = _json(f"{BASE}/proxy/protect/api/bootstrap")
        cams = _pick_camera_list(data)
        if cams:
            return cams
    except Exception as e:
        last_err = e
    raise RuntimeError(f"No cameras found via Protect API. Last error: {last_err}")

def nice_name(cam: dict) -> str:
    name = cam.get("name") or cam.get("displayName")
    model = cam.get("marketName") or cam.get("type") or cam.get("modelKey") or "camera"
    mac = cam.get("mac", "")[-6:] if cam.get("mac") else ""
    if name:
        return name
    ident = cam.get("mac") or cam.get("id") or cam.get("_id") or cam.get("uuid") or "unknown"
    return f"{model}{f'_{ident[-6:]}' if isinstance(ident,str) else ''}"

def snapshot_by_id(cam_id: str, width: int = 1280, hq: bool = False) -> bytes:
    try:
        url_v1 = f"{BASE}/proxy/protect/v1/cameras/{cam_id}/snapshot?highQuality={'true' if hq else 'false'}"
        r = _get(url_v1)
        ctype = r.headers.get("Content-Type", "")
        if r.ok and ctype.startswith("image/"):
            return r.content
    except Exception as e:
        logging.warning("v1 snapshot path failed for %s: %s", cam_id, e)
    ts = int(time.time() * 1000)
    url_api = f"{BASE}/proxy/protect/api/cameras/{cam_id}/snapshot?ts={ts}&force=true&width={width}"
    r = _get(url_api)
    return r.content

def overlay_timestamp(photo: bytes, tz_name: str, fmt: str, text_color=(255,255,255), pad=8):
    try:
        tz = ZoneInfo(tz_name) if tz_name else None
    except Exception:
        tz = None
    now = datetime.datetime.now(tz or datetime.timezone.utc).astimezone(tz or datetime.timezone.utc)
    label = now.strftime(fmt or "%Y-%m-%d %H:%M:%S %Z")
    im = Image.open(io.BytesIO(photo)).convert("RGB")
    draw = ImageDraw.Draw(im)
    try:
        font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", max(16, im.width//50))
    except Exception:
        font = ImageFont.load_default()
    x0,y0,x1,y1 = draw.textbbox((0,0), label, font=font)
    tw, th = x1 - x0, y1 - y0
    x, y = pad, im.height - th - 2*pad
    draw.rectangle([(x - pad, y - pad), (x + tw + pad, y + th + pad)], fill=(0,0,0,160))
    draw.text((x, y), label, fill=text_color, font=font)
    out = io.BytesIO(); im.save(out, format="JPEG", quality=90); return out.getvalue()

def send_to_telegram(photo: bytes, caption: str):
    files = {"photo": ("snapshot.jpg", photo, "image/jpeg")}
    data = {"chat_id": TELEGRAM_CHAT, "caption": caption}
    r = requests.post(f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/sendPhoto",
                      data=data, files=files, timeout=30)
    r.raise_for_status()

def send_text_to_telegram(text: str):
    data = {"chat_id": TELEGRAM_CHAT, "text": text}
    r = requests.post(f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/sendMessage",
                      data=data, timeout=15)
    r.raise_for_status()

app = Flask(__name__)

@app.get("/health")
def health():
    ok = bool(BASE and TELEGRAM_TOKEN and TELEGRAM_CHAT) and bool(API_KEY or (UNAME and UPASS))
    return jsonify({"ok": ok}), 200 if ok else 503

@app.get("/cameras")
def cameras_endpoint():
    token = request.args.get("token", "")
    if WEBHOOK_TOKEN and token != WEBHOOK_TOKEN:
        abort(403)
    try:
        cams_raw = list_cameras()
        cams = [{
            "id": (c.get("id") or c.get("_id") or c.get("uuid") or c.get("mac")),
            "name": nice_name(c),
            "model": (c.get("marketName") or c.get("type") or c.get("modelKey") or c.get("model"))
        } for c in cams_raw if isinstance(c, dict)]
        return jsonify({"ok": True, "cameras": cams}), 200
    except Exception as e:
        logging.error("Camera listing failed: %s", e)
        return jsonify({"ok": False, "error": str(e)}), 500


@app.get("/test/text")
def test_text():
    token = request.args.get("token", "")
    if WEBHOOK_TOKEN and token != WEBHOOK_TOKEN:
        abort(403)
    text = request.args.get("text", "Hello from UniFi Protect Telegram webhook ✅")
    send_text_to_telegram(text)
    return jsonify({"ok": True}), 200

@app.post("/hook/<camera_name>")
def hook_by_name(camera_name):
    token = request.args.get("token", "")
    if WEBHOOK_TOKEN and token != WEBHOOK_TOKEN:
        abort(403)
    caption = request.args.get("caption", f"Motion on {camera_name}")
    width = int(request.args.get("width", "1280"))
    hq = request.args.get("hq", "false").lower() in ("1","true","yes","on")
    stamp = request.args.get("stamp", "false").lower() in ("1","true","yes","on")
    stamp_tz = request.args.get("stamp_tz", "")
    stamp_fmt = request.args.get("stamp_fmt", "%Y-%m-%d %H:%M:%S %Z")
    cam_id = None
    for c in list_cameras():
        if nice_name(c) == camera_name:
            cam_id = cam.get("id") or cam.get("_id") or cam.get("uuid") or c.get("mac")
            break
    if not cam_id:
        abort(404)
    photo = snapshot_by_id(cam_id, width=width, hq=hq)
    if stamp:
        photo = overlay_timestamp(photo, stamp_tz, stamp_fmt)
    send_to_telegram(photo, caption)
    return jsonify({"ok": True}), 200

@app.post("/hook/by-id/<camera_id>")
def hook_by_id(camera_id):
    token = request.args.get("token", "")
    if WEBHOOK_TOKEN and token != WEBHOOK_TOKEN:
        abort(403)
    caption = request.args.get("caption", f"Motion on camera {camera_id}")
    width = int(request.args.get("width", "1280"))
    hq = request.args.get("hq", "false").lower() in ("1","true","yes","on")
    stamp = request.args.get("stamp", "false").lower() in ("1","true","yes","on")
    stamp_tz = request.args.get("stamp_tz", "")
    stamp_fmt = request.args.get("stamp_fmt", "%Y-%m-%d %H:%M:%S %Z")
    photo = snapshot_by_id(camera_id, width=width, hq=hq)
    if stamp:
        photo = overlay_timestamp(photo, stamp_tz, stamp_fmt)
    send_to_telegram(photo, caption)
    return jsonify({"ok": True}), 200

if __name__ == "__main__":
    port = int(os.getenv("PORT", "8080"))
    app.run(host="0.0.0.0", port=port)
