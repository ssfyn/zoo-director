#!/usr/bin/env python3
"""在真实 App Sandbox 中验证生产隧道源码，只使用临时密钥和回环服务。"""
import getpass
import http.server
from pathlib import Path
import platform
import plistlib
import shutil
import socket
import subprocess
import tempfile
import threading


class Handler(http.server.BaseHTTPRequestHandler):
    """仅返回固定数据，不向测试客户端暴露本机文件。"""

    def do_GET(self):
        """返回可经隧道核对的固定响应。"""
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"sandbox-tunnel-ok")

    def log_message(self, *arguments):
        """测试不记录请求内容。"""


def free_port():
    """申请当前可用的回环端口供隔离 SSH 服务使用。"""
    with socket.socket() as connection:
        connection.bind(("127.0.0.1", 0))
        return connection.getsockname()[1]


def prepare_fixture(work, port):
    """创建隔离应用和服务器配置，所有密钥均在本轮临时生成。"""
    app = work / "SandboxProbe.app"
    resources = app / "Contents/Resources"
    resources.mkdir(parents=True)
    (app / "Contents/MacOS").mkdir()
    (app / "Contents/Helpers").mkdir()
    for key in [work / "host", resources / "identity"]:
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)], check=True)
    public = (work / "host.pub").read_text().split()
    (resources / "known_hosts").write_text(f"[127.0.0.1]:{port} {public[0]} {public[1]}\n")
    (work / "outside-fixture").write_text("must not be readable by the probe")
    config = work / "sshd_config"
    config.write_text(f"""ListenAddress 127.0.0.1
Port {port}
HostKey {work / 'host'}
PidFile {work / 'sshd.pid'}
AuthorizedKeysFile {resources / 'identity.pub'}
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
AllowTcpForwarding local
LogLevel ERROR
""")
    return app, config


def build_probe(root, app):
    """直接编译生产授权、主机信任、隧道和钥匙串代码，并施加实际沙箱权限。"""
    helper = root / f".build/apps/{platform.machine()}/ZooDirector.app/Contents/Helpers/ZooDirectorSSHAskpass.app"
    if not helper.is_dir():
        raise SystemExit(f"请先运行 ./scripts/build-app.sh debug {platform.machine()}")
    plist = {"CFBundleIdentifier": "fan.yanan.zoodirector.sandboxprobe", "CFBundleExecutable": "SandboxProbe",
             "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
             "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True}}
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(plist))
    sources = [Path(__file__).with_name("Probe.swift")]
    sources += [root / "Sources/ZooDirector" / name for name in
                ["SSHTunnel.swift", "SSHPrivateKey.swift", "SSHKnownHosts.swift", "DigestAuthentication.swift"]]
    subprocess.run(["swiftc", "-parse-as-library", "-o", str(app / "Contents/MacOS/SandboxProbe"),
                    *map(str, sources)], check=True)
    shutil.copytree(helper, app / "Contents/Helpers/ZooDirectorSSHAskpass.app")
    subprocess.run(["codesign", "--force", "--sign", "-", "--entitlements",
                    str(root / "Resources/ZooDirector.entitlements"), str(app)], check=True)


def run_probe(work, app, config, port):
    """启动本机服务并验证真实数据转发，成功和失败路径都关闭服务。"""
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with (work / "sshd.log").open("w") as log:
            sshd = subprocess.Popen(["/usr/sbin/sshd", "-D", "-e", "-f", str(config)], stdout=log, stderr=log)
            try:
                # 连接探针只用于等待 SSH 监听，不进行认证或访问其他服务。
                for _ in range(100):
                    if sshd.poll() is not None:
                        raise RuntimeError("本机 SSH 服务未能启动，请检查日志。")
                    try:
                        with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                            break
                    except OSError:
                        threading.Event().wait(0.05)
                subprocess.run([str(app / "Contents/MacOS/SandboxProbe"), str(port), getpass.getuser(),
                                f"127.0.0.1:{server.server_address[1]}", str(work / "outside-fixture")],
                               check=True, timeout=35)
            finally:
                sshd.terminate()
                sshd.wait(timeout=5)
    finally:
        server.shutdown()
        server.server_close()


def main():
    """保留失败诊断，成功后移除临时应用及本轮生成的测试私钥。"""
    root = Path(__file__).resolve().parents[2]
    work = Path(tempfile.mkdtemp(prefix="sandbox-check-", dir=root / ".build"))
    try:
        port = free_port()
        app, config = prepare_fixture(work, port)
        build_probe(root, app)
        run_probe(work, app, config, port)
    except Exception:
        print("失败诊断目录：", work)
        raise
    else:
        shutil.rmtree(work)


if __name__ == "__main__":
    main()
