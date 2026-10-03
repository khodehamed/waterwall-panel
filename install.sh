#!/bin/bash

# ==============================================================================
# Waterwall Web Panel - Auto Installation Script
# ==============================================================================

echo -e "\e[34m>>> Updating system and installing prerequisites...\e[0m"
apt update
apt install -y python3 python3-pip curl
pip3 install fastapi uvicorn pydantic

echo -e "\e[34m>>> Creating working directory at /opt/waterwall-panel...\e[0m"
mkdir -p /opt/waterwall-panel
cd /opt/waterwall-panel

echo -e "\e[34m>>> Generating backend API code (panel_api.py)...\e[0m"
cat << 'EOF' > panel_api.py
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse
from pydantic import BaseModel
import subprocess
import re
import os

app = FastAPI(title="Waterwall Web Panel")

# Enable CORS for frontend communication
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

class ActionRequest(BaseModel):
    version: str
    action: str
    new_port: str = None

def run_shell(command: str):
    """Execute shell commands and return output"""
    try:
        result = subprocess.run(command, shell=True, capture_output=True, text=True)
        return result.stdout.strip(), result.returncode
    except Exception as e:
        return str(e), 1

def check_tunnel(version: str, service_name: str):
    """Check the status, uptime, and port of a specific tunnel service"""
    # Check if the service file exists
    stdout, code = run_shell(f"systemctl list-units --all | grep {service_name}.service")
    if service_name not in stdout:
        return None

    # Check if the service is active
    status_out, _ = run_shell(f"systemctl is-active {service_name}")
    is_active = (status_out == "active")

    # Extract uptime
    uptime = "Stopped"
    if is_active:
        time_out, _ = run_shell(f"systemctl show {service_name} --property=ActiveEnterTimestamp")
        uptime = time_out.replace("ActiveEnterTimestamp=", "") or "Running"

    # Extract port from the service configuration file
    port = "Unknown"
    config_cat, _ = run_shell(f"cat /etc/systemd/system/{service_name}.service")
    port_match = re.search(r'--port\s+(\d+)', config_cat)
    if port_match:
        port = port_match.group(1)

    return {
        "version": version,
        "service_name": service_name,
        "status": "active" if is_active else "inactive",
        "uptime": uptime,
        "port": port
    }

@app.get("/")
def serve_frontend():
    """Serve the HTML frontend directly from FastAPI"""
    if os.path.exists("index.html"):
        with open("index.html", "r", encoding="utf-8") as file:
            return HTMLResponse(content=file.read())
    return HTMLResponse(content="<h1>Error: index.html not found!</h1>", status_code=404)

@app.get("/api/status")
def get_status():
    """API endpoint to get the status of all tunnels and server location"""
    tunnels = []
    
    # Check V1 and V2 tunnels
    v1 = check_tunnel("v1", "waterwall")
    if v1: tunnels.append(v1)
        
    v2 = check_tunnel("v2", "waterwall-v2")
    if v2: tunnels.append(v2)

    # Detect server location based on hostname
    hostname, _ = run_shell("hostname")
    location = "Iran" if "ir" in hostname.lower() else "Foreign"

    return {
        "server_location": location,
        "active_tunnels": tunnels
    }

@app.post("/api/action")
def manage_tunnel(req: ActionRequest):
    """API endpoint to handle tunnel actions (start, stop, restart, edit)"""
    service = "waterwall" if req.version == "v1" else "waterwall-v2"
    
    if req.action in ["start", "stop", "restart"]:
        out, code = run_shell(f"sudo systemctl {req.action} {service}")
        if code == 0:
            return {"message": f"Action '{req.action}' executed successfully on {service}."}
        raise HTTPException(status_code=500, detail="Failed to execute the command.")
        
    elif req.action == "edit_port" and req.new_port:
        # Example logic for editing port in systemd service file
        run_shell(f"sudo sed -i 's/--port [0-9]*/--port {req.new_port}/g' /etc/systemd/system/{service}.service")
        run_shell("sudo systemctl daemon-reload")
        run_shell(f"sudo systemctl restart {service}")
        return {"message": f"Port successfully changed to {req.new_port}."}

    raise HTTPException(status_code=400, detail="Invalid request.")
EOF

echo -e "\e[34m>>> Generating frontend UI code (index.html)...\e[0m"
cat << 'EOF' > index.html
<!DOCTYPE html>
<html lang="fa" dir="rtl">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>پنل مدیریت تانل Waterwall</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <link href="https://cdn.jsdelivr.net/gh/rastikerdar/vazirmatn@v33.003/Vazirmatn-font-face.css" rel="stylesheet" type="text/css" />
    <style>body { font-family: 'Vazirmatn', sans-serif; }</style>
</head>
<body class="bg-gray-900 text-gray-100 min-h-screen">
    <header class="bg-gray-800 shadow-lg border-b border-gray-700">
        <div class="max-w-6xl mx-auto px-4 py-5 flex justify-between items-center">
            <h1 id="server-title" class="text-2xl font-bold text-blue-400">در حال بررسی وضعیت سرور...</h1>
            <button onclick="loadDashboard()" class="bg-gray-700 hover:bg-gray-600 px-4 py-2 rounded-lg transition text-sm">🔄 بروزرسانی</button>
        </div>
    </header>
    <main class="max-w-6xl mx-auto px-4 py-8">
        <div id="tunnels-container" class="grid grid-cols-1 md:grid-cols-2 gap-6"></div>
    </main>

    <script>
        // Get the current host dynamically
        const API_URL = window.location.origin + "/api";

        async function loadDashboard() {
            const titleEl = document.getElementById('server-title');
            const containerEl = document.getElementById('tunnels-container');
            containerEl.innerHTML = '<p class="text-gray-400">در حال دریافت اطلاعات از سرور...</p>';

            try {
                // Fetch data from the FastAPI backend
                const response = await fetch(`${API_URL}/status`);
                const data = await response.json();

                titleEl.innerHTML = `🎛️ مدیریت تانل - سرور <span class="text-white">${data.server_location}</span>`;
                containerEl.innerHTML = '';

                if (data.active_tunnels.length === 0) {
                    containerEl.innerHTML = '<p class="text-red-400">هیچ نسخه‌ای از Waterwall روی این سرور یافت نشد.</p>';
                    return;
                }

                // Render tunnel cards dynamically
                data.active_tunnels.forEach(tunnel => {
                    const isActive = tunnel.status === 'active';
                    const statusColor = isActive ? 'text-green-400' : 'text-red-400';
                    const statusBg = isActive ? 'bg-green-400/10 border-green-500/30' : 'bg-red-400/10 border-red-500/30';
                    const statusText = isActive ? '🟢 فعال (آنلاین)' : '🔴 غیرفعال (آفلاین)';

                    const cardHTML = `
                        <div class="bg-gray-800 rounded-xl p-6 shadow-xl border border-gray-700 flex flex-col justify-between">
                            <div>
                                <div class="flex justify-between items-start border-b border-gray-700 pb-4 mb-4">
                                    <div>
                                        <h2 class="text-xl font-bold mb-1">نسخه تانل: Waterwall ${tunnel.version.toUpperCase()}</h2>
                                        <p class="text-sm text-gray-400 font-mono">${tunnel.service_name}.service</p>
                                    </div>
                                    <div class="px-3 py-1 rounded-lg border ${statusBg} ${statusColor} text-sm font-semibold">${statusText}</div>
                                </div>
                                <div class="grid grid-cols-2 gap-4 mb-6">
                                    <div class="bg-gray-900 rounded p-3 border border-gray-700">
                                        <p class="text-xs text-gray-400 mb-1">آپتایم</p>
                                        <p class="font-medium text-left dir-ltr">${tunnel.uptime}</p>
                                    </div>
                                    <div class="bg-gray-900 rounded p-3 border border-gray-700">
                                        <p class="text-xs text-gray-400 mb-1">پورت ارتباطی</p>
                                        <p class="font-medium font-mono">${tunnel.port}</p>
                                    </div>
                                </div>
                            </div>
                            <div class="flex flex-wrap gap-2 mt-4">
                                <button onclick="sendAction('${tunnel.version}', 'restart')" class="flex-1 bg-blue-600 hover:bg-blue-500 text-white py-2 px-4 rounded text-sm">🔄 ری‌استارت</button>
                                ${isActive ? 
                                    `<button onclick="sendAction('${tunnel.version}', 'stop')" class="flex-1 bg-red-600 hover:bg-red-500 text-white py-2 px-4 rounded text-sm">🛑 توقف</button>` : 
                                    `<button onclick="sendAction('${tunnel.version}', 'start')" class="flex-1 bg-green-600 hover:bg-green-500 text-white py-2 px-4 rounded text-sm">▶️ اجرا</button>`
                                }
                                <button onclick="changePortPrompt('${tunnel.version}')" class="w-full mt-2 bg-gray-700 hover:bg-gray-600 border border-gray-600 text-white py-2 px-4 rounded text-sm">⚙️ تغییر پورت</button>
                            </div>
                        </div>
                    `;
                    containerEl.innerHTML += cardHTML;
                });
            } catch (error) {
                containerEl.innerHTML = '<p class="text-red-500">❌ ارتباط با بک‌اند سرور برقرار نشد.</p>';
            }
        }

        async function sendAction(version, action, newPort = null) {
            try {
                // Send action request to the backend
                const res = await fetch(`${API_URL}/action`, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ version: version, action: action, new_port: newPort })
                });
                const result = await res.json();
                alert(result.message || "عملیات انجام شد.");
                loadDashboard(); // Refresh data
            } catch (err) {
                alert("خطا در ارسال درخواست به سرور");
            }
        }

        function changePortPrompt(version) {
            const newPort = prompt("پورت جدید را وارد کنید:");
            if (newPort && !isNaN(newPort)) {
                sendAction(version, 'edit_port', newPort);
            }
        }

        document.addEventListener('DOMContentLoaded', loadDashboard);
    </script>
</body>
</html>
EOF

echo -e "\e[34m>>> Creating Systemd service for the Web Panel...\e[0m"
cat << EOF > /etc/systemd/system/waterwall-panel.service
[Unit]
Description=Waterwall Web Panel API
After=network.target

[Service]
User=root
WorkingDirectory=/opt/waterwall-panel
ExecStart=/usr/local/bin/uvicorn panel_api:app --host 0.0.0.0 --port 8080
Restart=always

[Install]
WantedBy=multi-user.target
EOF

echo -e "\e[34m>>> Starting and enabling the service...\e[0m"
systemctl daemon-reload
systemctl enable waterwall-panel
systemctl restart waterwall-panel

# Get Server IP
SERVER_IP=$(curl -s -4 ifconfig.me)

echo -e "\e[32m============================================================\e[0m"
echo -e "\e[32m>>> Installation Complete! \e[0m"
echo -e "\e[32m>>> Access your panel at:\e[0m \e[33mhttp://${SERVER_IP}:8080\e[0m"
echo -e "\e[32m============================================================\e[0m"
