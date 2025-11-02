import subprocess
import json
import os
import tempfile
import time
from datetime import datetime, timedelta
from faker import Faker
import shutil
import random
from http.server import BaseHTTPRequestHandler, HTTPServer
import threading

fake = Faker()

# ==========================================================
# ⚙️ Config (env vars)
# ==========================================================
UPLOAD_MINUTES = int(os.getenv("UPLOAD_MINUTES", "5"))
COOLDOWN_MINUTES = int(os.getenv("COOLDOWN_MINUTES", "5"))
MAX_RETRIES = int(os.getenv("MAX_RETRIES", "3"))
MIN_FILE_MB = int(os.getenv("MIN_FILE_MB", "100"))
MAX_FILE_MB = int(os.getenv("MAX_FILE_MB", "1024"))
USE_FRACTION = float(os.getenv("USE_FRACTION", "0.7"))
UPLOAD_DELAY_SEC = int(os.getenv("UPLOAD_DELAY_SEC", "15"))
CLEAN_TMP = os.getenv("CLEAN_TMP", "true").lower() in ("true", "1", "yes")
METRICS_PORT = int(os.getenv("METRICS_PORT", "8081"))

# ==========================================================
# 🌐 Dynamic File Browser URL Discovery
# ==========================================================
service_host = os.getenv("FILEBROWSER_SERVICE_HOST")
service_port = os.getenv("FILEBROWSER_SERVICE_PORT", "80")

if service_host:
    BASE_URL = f"http://{service_host}:{service_port}"
else:
    BASE_URL = os.getenv("BASE_URL", "http://localhost:8080")

print(f"🌐 Using File Browser base URL: {BASE_URL}")

API_USER = os.getenv("FB_USERNAME", "admin")
API_PASS = os.getenv("FB_PASSWORD", "admin123")

# ==========================================================
# 📊 Metrics storage
# ==========================================================
metrics = {
    "total_files_uploaded": 0,
    "total_mb_uploaded": 0.0,
    "cycle_start": datetime.utcnow().isoformat(),
    "last_upload": "",
}

def metrics_text():
    """Return Prometheus format metrics text."""
    return (
        f"# HELP filebrowser_files_uploaded Total files uploaded\n"
        f"# TYPE filebrowser_files_uploaded counter\n"
        f"filebrowser_files_uploaded {metrics['total_files_uploaded']}\n"
        f"# HELP filebrowser_mb_uploaded Total MB uploaded\n"
        f"# TYPE filebrowser_mb_uploaded counter\n"
        f"filebrowser_mb_uploaded {metrics['total_mb_uploaded']}\n"
        f"# HELP filebrowser_last_upload_timestamp Last upload time (UTC)\n"
        f"# TYPE filebrowser_last_upload_timestamp gauge\n"
        f"filebrowser_last_upload_timestamp {time.time() if metrics['last_upload'] else 0}\n"
    )

# ==========================================================
# 🧠 Metrics HTTP Server
# ==========================================================
class MetricsHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/metrics":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.end_headers()
            self.wfile.write(metrics_text().encode())
        else:
            self.send_response(404)
            self.end_headers()

def start_metrics_server():
    server = HTTPServer(("", METRICS_PORT), MetricsHandler)
    print(f"📡 Metrics server listening on :{METRICS_PORT}/metrics")
    threading.Thread(target=server.serve_forever, daemon=True).start()

# ==========================================================
# 🔐 Login
# ==========================================================
def get_api_token(api_url, protocol="http", api_username=None, api_password=None):
    api_url = api_url.strip()
    if not api_url.startswith("http"):
        api_url = f"{protocol}://{api_url}"

    data = {"username": api_username or "", "password": api_password or "", "recaptcha": ""}
    cmd = [
        "curl", "-s", "-H", "Content-Type: application/json",
        f"{api_url}/api/login", "--data", json.dumps(data)
    ]
    try:
        result = subprocess.check_output(cmd, text=True).strip()
        parsed = json.loads(result)
        token = parsed.get("jwt", result)
        print(f"✅ Got JWT token: {token[:40]}... (truncated)")
        return token
    except Exception as e:
        print(f"❌ Login failed: {e}")
        return None

# ==========================================================
# 🔁 Retry Wrapper
# ==========================================================
def run_curl_with_retry(cmd_func, *args, **kwargs):
    token = kwargs.get("token")
    for attempt in range(1, MAX_RETRIES + 1):
        code = cmd_func(*args, token=token)
        if code in ("401", "403"):
            print(f"⚠️ Got 403 — re-logging in (attempt {attempt}/{MAX_RETRIES})")
            token = get_api_token(BASE_URL, api_username=API_USER, api_password=API_PASS)
            kwargs["token"] = token
            continue
        return code
    print("❌ Failed after retries.")
    return None

# ==========================================================
# 📁 Folder Creation
# ==========================================================
def create_folder(folder_name, token):
    folder_name = folder_name.strip("/")
    cmd = [
        "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
        "-X", "POST",
        f"{BASE_URL}/api/resources/{folder_name}/?override=false",
        "-H", f"Authorization: Bearer {token}",
        "-H", "Content-Type: application/json",
        "--data", '{"type":"dir"}'
    ]
    return subprocess.check_output(cmd, text=True).strip()

# ==========================================================
# 📤 Upload File
# ==========================================================
def upload_file(local_path, remote_folder, token):
    remote_folder = remote_folder.strip("/")
    file_name = os.path.basename(local_path)
    cmd = [
        "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
        "-X", "POST",
        "-H", f"Authorization: Bearer {token}",
        "-F", f"files=@{local_path}",
        f"{BASE_URL}/api/resources/{remote_folder}/{file_name}?override=false"
    ]
    code = subprocess.check_output(cmd, text=True).strip()
    return code

# ==========================================================
# 💾 Safe Large File Creation
# ==========================================================
def create_large_file_safe(file_path, min_mb=100, max_mb=1024, use_fraction=0.7):
    dir_path = os.path.dirname(file_path) or "."
    total, used, free = shutil.disk_usage(dir_path)
    free_mb = free // (1024 * 1024)
    max_allowed_mb = int(free_mb * use_fraction)
    target_size_mb = min(max_mb, max(min_mb, max_allowed_mb))
    chosen_size_mb = random.choice([min_mb, target_size_mb, target_size_mb // 2])
    print(f"💾 Free {free_mb} MB → writing {chosen_size_mb} MB file")

    if shutil.which("dd"):
        cmd = [
            "dd", "if=/dev/zero", f"of={file_path}",
            "bs=1M", f"count={chosen_size_mb}", "status=none"
        ]
        subprocess.run(cmd, check=True)
    else:
        chunk_size = 1024 * 1024
        with open(file_path, "wb") as f:
            for _ in range(chosen_size_mb):
                f.write(os.urandom(chunk_size))
    return chosen_size_mb

# ==========================================================
# 🧹 Cleanup
# ==========================================================
def cleanup_tmp():
    tmp_dir = tempfile.gettempdir()
    for f in os.listdir(tmp_dir):
        try:
            os.remove(os.path.join(tmp_dir, f))
        except Exception:
            pass

# ==========================================================
# 🔁 Upload Cycle
# ==========================================================
def upload_cycle(token):
    root_folder = f"data_{fake.word()}"
    sub_folder = f"{root_folder}/{fake.word()}_{fake.random_int(1,100)}"
    run_curl_with_retry(create_folder, root_folder, token=token)
    run_curl_with_retry(create_folder, sub_folder, token=token)

    end_time = datetime.utcnow() + timedelta(minutes=UPLOAD_MINUTES)
    uploaded_mb = 0
    uploaded_files = 0
    print(f"🚀 Uploading for {UPLOAD_MINUTES} minutes...")

    while datetime.utcnow() < end_time:
        tmp_file = os.path.join(tempfile.gettempdir(), f"{fake.word()}.bin")
        size_mb = create_large_file_safe(tmp_file, MIN_FILE_MB, MAX_FILE_MB, USE_FRACTION)
        code = run_curl_with_retry(upload_file, tmp_file, sub_folder, token=token)
        if code in ("200", "201"):
            uploaded_mb += size_mb
            uploaded_files += 1
            metrics["total_mb_uploaded"] += size_mb
            metrics["total_files_uploaded"] += 1
            metrics["last_upload"] = datetime.utcnow().isoformat()
            print(f"📤 {uploaded_files} files uploaded this cycle ({uploaded_mb} MB total)")
        else:
            print(f"⚠️ Upload failed ({code})")
        time.sleep(UPLOAD_DELAY_SEC)

    print(f"✅ Upload phase done: {uploaded_files} files ({uploaded_mb} MB)")
    if CLEAN_TMP:
        cleanup_tmp()
    print(f"🕒 Cooldown for {COOLDOWN_MINUTES} minutes...\n")
    time.sleep(COOLDOWN_MINUTES * 60)

# ==========================================================
# 🧠 Main
# ==========================================================
if __name__ == "__main__":
    start_metrics_server()
    token = get_api_token(BASE_URL, api_username=API_USER, api_password=API_PASS)
    while True:
        upload_cycle(token)
