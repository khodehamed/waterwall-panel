#!/bin/bash

# ==============================================================================
# Waterwall Web Panel - Interactive Manager
# ==============================================================================

GREEN="\e[32m"
BLUE="\e[34m"
RED="\e[31m"
YELLOW="\e[33m"
RESET="\e[0m"
PANEL_PORT=12020

function install_panel() {
    echo -e "${BLUE}>>> Updating system and installing prerequisites...${RESET}"
    apt update
    apt install -y python3 python3-pip curl

    echo -e "${BLUE}>>> Installing Python packages...${RESET}"
    pip3 install fastapi uvicorn pydantic --ignore-installed --break-system-packages

    echo -e "${BLUE}>>> Creating working directory at /opt/waterwall-panel...${RESET}"
    mkdir -p /opt/waterwall-panel
    cd /opt/waterwall-panel

    echo -e "${BLUE}>>> Generating backend API code...${RESET}"
    cat << 'EOF' > panel_api.py
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse
from pydantic import BaseModel
import subprocess
import re
import os

app = FastAPI(title="Waterwall Web Panel")

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
    try:
        result = subprocess.run(command, shell=True, capture_output=True, text=True)
        return result.stdout.strip(), result.returncode
    except Exception as e:
        return str(e), 1

def check_tunnel(version: str, service_name: str):
    stdout, code = run_shell(f"systemctl list-units --all | grep {service_name}.service")
    if service_name not in stdout:
        return None

    status_out, _ = run_shell(f"systemctl is-active {service_name}")
    is_active = (status_out == "active")

    uptime = "Stopped"
    if is_active:
        time_out, _ = run_shell(f"systemctl show {service_name} --property=ActiveEnterTimestamp")
        uptime = time_out.replace("ActiveEnterTimestamp=", "") or "Running"

    port = "Unknown"
    config_cat, _ = run_shell(f"cat /etc/systemd/system/{service_name}.service")
    port_match = re.search(r'(-p|--port)\s+(\d+)', config_cat)
    if port_match:
        port = port_match.group(2)

    return {
        "version": version,
        "service_name": service_name,
        "status": "active" if is_active else "inactive",
        "uptime": uptime,
        "port": port
    }

@app.get("/")
def serve_frontend():
    if os.path.exists("index.html"):
        with open("index.html", "r", encoding="utf-8") as file:
            return HTMLResponse(content=file.read())
    return HTMLResponse(content="<h1>Error: index.html not found!</h1>", status_code=404)

@app.get("/api/status")
def get_status():
    tunnels = []
    
    v1 = check_tunnel("v1", "waterwall-proto51")
    if v1: tunnels.append(v1)
        
    v2 = check_tunnel("v2", "waterwall-proto51-v2")
    if v2: tunnels.append(v2)

    hostname, _ = run_shell("hostname")
    location = "ایران" if "ir" in hostname.lower() else "خارج"

    return {
        "server_location": location,
        "active_tunnels": tunnels
    }

@app.post("/api/action")
def manage_tunnel(req: ActionRequest):
    service = "waterwall-proto51" if req.version == "v1" else "waterwall-proto51-v2"
    
    if req.action in ["start", "stop", "restart"]:
        out, code = run_shell(f"sudo systemctl {req.action} {service}")
        if code == 0:
            return {"message": f"عملیات {req.action} با موفقیت انجام شد."}
        raise HTTPException(status_code=500, detail="خطا در اجرای دستور.")
        
    elif req.action == "edit_port" and req.new_port:
        run_shell(f"sudo sed -i -E 's/(-p|--port) [0-9]+/\\1 {req.new_port}/g' /etc/systemd/system/{service}.service")
        run_shell("sudo systemctl daemon-reload")
        run_shell(f"sudo systemctl restart {service}")
        return {"message": f"پورت انتقال با موفقیت به {req.new_port} تغییر یافت."}

    raise HTTPException(status_code=400, detail="درخواست نامعتبر")
EOF

    echo -e "${BLUE}>>> Generating frontend UI code...${RESET}"
    cat << 'EOF' > index.html
<!DOCTYPE html>
<html lang="fa" dir="rtl">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>پنل مدیریت Waterwall</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <link href="https://cdn.jsdelivr.net/gh/rastikerdar/vazirmatn@v33.003/Vazirmatn-font-face.css" rel="stylesheet" type="text/css" />
    <style>body { font-family: 'Vazirmatn', sans-serif; }</style>
</head>
<body class="bg-gray-900 text-gray-100 min-h-screen">
    <header class="bg-gray-800 shadow-lg border-b border-gray-700">
        <div class="max-w-6xl mx-auto px-4 py-5 flex justify-between items-center">
            <h1 id="server-title" class="text-2xl font-bold text-blue-400">در حال بررسی...</h1>
            <button onclick="loadDashboard()" class="bg-gray-700 hover:bg-gray-600 px-4 py-2 rounded-lg transition text-sm">🔄 بروزرسانی</button>
        </div>
    </header>
    <main class="max-w-6xl mx-auto px-4 py-8">
        <div id="tunnels-container" class="grid grid-cols-1 md:grid-cols-2 gap-6"></div>
    </main>

    <script>
        const API_URL = window.location.origin + "/api";

        async function loadDashboard() {
            const titleEl = document.getElementById('server-title');
            const containerEl = document.getElementById('tunnels-container');
            containerEl.innerHTML = '<p class="text-gray-400">در حال دریافت اطلاعات...</p>';

            try {
                const response = await fetch(`${API_URL}/status`);
                const data = await response.json();

                titleEl.innerHTML = `🎛️ مدیریت تانل - سرور <span class="text-white">${data.server_location}</span>`;
                containerEl.innerHTML = '';

                if (data.active_tunnels.length === 0) {
                    containerEl.innerHTML = '<p class="text-yellow-400">سرویس Waterwall روی این سرور یافت نشد.</p>';
                    return;
                }

                data.active_tunnels.forEach(tunnel => {
                    const isActive = tunnel.status === 'active';
                    const statusColor = isActive ? 'text-green-400' : 'text-red-400';
                    const statusBg = isActive ? 'bg-green-400/10 border-green-500/30' : 'bg-red-400/10 border-red-500/30';
                    const statusText = isActive ? '🟢 آنلاین' : '🔴 آفلاین';

                    const cardHTML = `
                        <div class="bg-gray-800 rounded-xl p-6 shadow-xl border border-gray-700 flex flex-col justify-between">
                            <div>
                                <div class="flex justify-between items-start border-b border-gray-700 pb-4 mb-4">
                                    <div>
                                        <h2 class="text-xl font-bold mb-1">نسخه: Waterwall ${tunnel.version.toUpperCase()}</h2>
                                        <p class="text-sm text-gray-400 font-mono">${tunnel.service_name}</p>
                                    </div>
                                    <div class="px-3 py-1 rounded-lg border ${statusBg} ${statusColor} text-sm font-semibold">${statusText}</div>
                                </div>
                                <div class="grid grid-cols-2 gap-4 mb-6">
                                    <div class="bg-gray-900 rounded p-3 border border-gray-700">
                                        <p class="text-xs text-gray-400 mb-1">آپتایم</p>
                                        <p class="font-medium text-left dir-ltr text-sm">${tunnel.uptime}</p>
                                    </div>
                                    <div class="bg-gray-900 rounded p-3 border border-gray-700">
                                        <p class="text-xs text-gray-400 mb-1">پورت انتقال</p>
                                        <p class="font-medium font-mono text-blue-400">${tunnel.port}</p>
                                    </div>
                                </div>
                            </div>
                            <div class="flex flex-wrap gap-2 mt-4">
                                <button onclick="sendAction('${tunnel.version}', 'restart')" class="flex-1 bg-blue-600 hover:bg-blue-500 text-white py-2 px-2 rounded text-sm">🔄 ری‌استارت</button>
                                ${isActive ? 
                                    `<button onclick="sendAction('${tunnel.version}', 'stop')" class="flex-1 bg-red-600 hover:bg-red-500 text-white py-2 px-2 rounded text-sm">🛑 توقف</button>` : 
                                    `<button onclick="sendAction('${tunnel.version}', 'start')" class="flex-1 bg-green-600 hover:bg-green-500 text-white py-2 px-2 rounded text-sm">▶️ اجرا</button>`
                                }
                                <button onclick="changePortPrompt('${tunnel.version}')" class="w-full mt-2 bg-gray-700 hover:bg-gray-600 border border-gray-600 text-white py-2 px-4 rounded text-sm">⚙️ تغییر پورت پروتکل</button>
                            </div>
                        </div>
                    `;
                    containerEl.innerHTML += cardHTML;
                });
            } catch (error) {
                containerEl.innerHTML = '<p class="text-red-500">❌ ارتباط با سرور قطع است.</p>';
            }
        }

        async function sendAction(version, action, newPort = null) {
            try {
                const res = await fetch(`${API_URL}/action`, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ version: version, action: action, new_port: newPort })
                });
                const result = await res.json();
                alert(result.message || "عملیات انجام شد.");
                setTimeout(loadDashboard, 1000);
            } catch (err) {
                alert("خطا در ارسال درخواست!");
            }
        }

        function changePortPrompt(version) {
            const newPort = prompt("شماره پورت انتقال جدید را وارد کنید:");
            if (newPort && !isNaN(newPort)) {
                sendAction(version, 'edit_port', newPort);
            }
        }

        document.addEventListener('DOMContentLoaded', loadDashboard);
    </script>
</body>
</html>
EOF

    echo -e "${BLUE}>>> Creating Systemd service (Port: ${PANEL_PORT})...${RESET}"
    cat << EOF > /etc/systemd/system/waterwall-panel.service
[Unit]
Description=Waterwall Web Panel
After=network.target

[Service]
User=root
WorkingDirectory=/opt/waterwall-panel
ExecStart=/usr/local/bin/uvicorn panel_api:app --host 0.0.0.0 --port ${PANEL_PORT}
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    echo -e "${BLUE}>>> Starting service...${RESET}"
    systemctl daemon-reload
    systemctl enable waterwall-panel
    systemctl restart waterwall-panel

    SERVER_IP=$(curl -s -4 ifconfig.me)
    echo -e "${GREEN}============================================================${RESET}"
    echo -e "${GREEN}>>> Installation Complete!${RESET}"
    echo -e "${GREEN}>>> Panel URL: ${YELLOW}http://${SERVER_IP}:${PANEL_PORT}${RESET}"
    echo -e "${GREEN}============================================================${RESET}"
}

function uninstall_panel() {
    echo -e "${RED}>>> Uninstalling Waterwall Panel...${RESET}"
    systemctl stop waterwall-panel 2>/dev/null
    systemctl disable waterwall-panel 2>/dev/null
    rm -f /etc/systemd/system/waterwall-panel.service
    rm -rf /opt/waterwall-panel
    systemctl daemon-reload
    echo -e "${GREEN}>>> Uninstallation complete. Panel has been removed.${RESET}"
}

clear
echo -e "${BLUE}=======================================${RESET}"
echo -e "${YELLOW}      Waterwall Panel Installer${RESET}"
echo -e "${BLUE}=======================================${RESET}"
echo -e "1) ${GREEN}Install / Update Panel${RESET} (Port:${PANEL_PORT})"
echo -e "2) ${RED}Uninstall Panel${RESET}"
echo -e "3) Exit"
echo -e "${BLUE}=======================================${RESET}"
read -p "Select an option [1-3]: " choice

case $choice in
    1)
        install_panel
        ;;
    2)
        read -p "Are you sure you want to completely remove the panel? (y/n): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            uninstall_panel
        else
            echo "Uninstallation canceled."
        fi
        ;;
    3)
        echo "Exiting..."
        exit 0
        ;;
    *)
        echo -e "${RED}Invalid option!${RESET}"
        ;;
esac
