#!/usr/bin/env python3
"""只在 GitHub 临时机器中导入发布凭据，退出前恢复钥匙串搜索列表并清理。"""
import base64
import json
import os
from pathlib import Path
import secrets
import shlex
import shutil
import subprocess
import sys


def run(*arguments):
    """调用系统签名工具，失败时不在异常中回显可能包含密码的完整参数。"""
    try:
        subprocess.run(arguments, check=True)
    except subprocess.CalledProcessError as error:
        raise ValueError(f"签名工具执行失败，退出码 {error.returncode}。请检查上方工具日志。") from None


def work_directory():
    """将凭据工作目录限制在 GitHub 的任务临时目录，拒绝本机误调用。"""
    if os.environ.get("GITHUB_ACTIONS") != "true" or not os.environ.get("RUNNER_TEMP"):
        raise ValueError("此脚本仅供 GitHub Actions 使用；本机请使用已有钥匙串配置。")
    return Path(os.environ["RUNNER_TEMP"]) / "zoodirector-signing"


def setup(directory):
    """验证必要参数后创建专用临时钥匙串，导入证书和团队公证密钥。"""
    required = ["MACOS_CERTIFICATE_P12_BASE64", "MACOS_CERTIFICATE_PASSWORD", "SIGNING_IDENTITY",
                "APPLE_API_KEY_P8_BASE64", "APPLE_API_KEY_ID", "APPLE_API_ISSUER_ID"]
    missing = ["MACOS_SIGNING_IDENTITY" if name == "SIGNING_IDENTITY" else name
               for name in required if not os.environ.get(name)]
    if missing:
        raise ValueError("请在仓库配置以下发布 Secrets：" + ", ".join(missing))
    directory.mkdir(mode=0o700)
    original = shlex.split(subprocess.check_output(["security", "list-keychains", "-d", "user"], text=True))
    (directory / "original-keychains.json").write_text(json.dumps(original))
    for variable, filename in [("MACOS_CERTIFICATE_P12_BASE64", "certificate.p12"), ("APPLE_API_KEY_P8_BASE64", "notary.p8")]:
        data = base64.b64decode("".join(os.environ[variable].split()), validate=True)
        path = directory / filename
        path.write_bytes(data)
        path.chmod(0o600)
    keychain = str(directory / "release.keychain-db")
    password = secrets.token_urlsafe(32)
    run("security", "create-keychain", "-p", password, keychain)
    run("security", "set-keychain-settings", "-lut", "21600", keychain)
    run("security", "unlock-keychain", "-p", password, keychain)
    run("security", "import", str(directory / "certificate.p12"), "-k", keychain,
        "-P", os.environ["MACOS_CERTIFICATE_PASSWORD"], "-T", "/usr/bin/codesign", "-T", "/usr/bin/security")
    run("security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", password, keychain)
    run("security", "list-keychains", "-d", "user", "-s", keychain, *original)
    run("xcrun", "notarytool", "store-credentials", "zoodirector-ci", "--key", str(directory / "notary.p8"),
        "--key-id", os.environ["APPLE_API_KEY_ID"], "--issuer", os.environ["APPLE_API_ISSUER_ID"], "--keychain", keychain)
    with open(os.environ["GITHUB_ENV"], "a") as output:
        output.write(f"NOTARY_PROFILE=zoodirector-ci\nNOTARY_KEYCHAIN={keychain}\n")
    (directory / "certificate.p12").unlink()
    (directory / "notary.p8").unlink()


def cleanup(directory):
    """即使导入中途失败也恢复搜索列表并移除本任务的证书和密钥文件。"""
    if not directory.exists():
        return
    try:
        original = directory / "original-keychains.json"
        if original.exists():
            run("security", "list-keychains", "-d", "user", "-s", *json.loads(original.read_text()))
        keychain = directory / "release.keychain-db"
        if keychain.exists():
            run("security", "delete-keychain", str(keychain))
    finally:
        shutil.rmtree(directory)


if __name__ == "__main__":
    try:
        if len(sys.argv) != 2 or sys.argv[1] not in {"setup", "cleanup"}:
            raise ValueError("用法：ci-signing.py setup|cleanup")
        (setup if sys.argv[1] == "setup" else cleanup)(work_directory())
    except (ValueError, OSError) as error:
        raise SystemExit(str(error))
