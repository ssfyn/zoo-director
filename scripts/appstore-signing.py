#!/usr/bin/env python3
"""选择同团队的商店签名身份，校验可选描述文件并生成受控的签名参数。"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess


def identities(policy=None):
    """只读取有效签名身份的公开名称及指纹，不导出私钥。"""
    command = ["security", "find-identity", "-v"]
    if policy:
        command += ["-p", policy]
    result = subprocess.run(command, check=True, capture_output=True, text=True)
    return [{"sha1": match[0], "name": match[1]} for match in
            re.findall(r'\d+\)\s+([A-Fa-f0-9]{40})\s+"([^"]+)"', result.stdout)]


def choose_identity(available, requested, prefixes, label):
    """只选择明确的商店证书，多个候选时要求显式配置，拒绝模糊名称。"""
    candidates = [value for value in available if value["name"].startswith(prefixes)]
    if requested:
        candidates = [value for value in candidates
                      if value["name"] == requested or value["sha1"].upper() == requested.upper()]
    if len(candidates) != 1:
        raise ValueError(f"无法唯一确定{label}，请配置对应的 APPSTORE 签名身份，并确认钥匙串中证书有效且有私钥。")
    return candidates[0]


def team_for(identity):
    """从苹果标准证书名称提取团队标识，避免混用公司和个人的凭据。"""
    match = re.search(r"\(([A-Z0-9]{10})\)$", identity["name"])
    if not match:
        raise ValueError("签名身份名称中缺少有效的 Team ID。")
    return match[1]


def profile_entitlements(profile, team, certificate, bundle):
    """检查平台、期限、团队、应用标识和签名证书，拒绝开发或站外描述文件。"""
    expires = profile.get("ExpirationDate")
    if isinstance(expires, datetime):
        expires = expires.replace(tzinfo=timezone.utc) if expires.tzinfo is None else expires.astimezone(timezone.utc)
    if not isinstance(expires, datetime) or expires <= datetime.now(timezone.utc):
        raise ValueError("App Store 描述文件已过期或缺少有效期。")
    if "OSX" not in profile.get("Platform", []) or team not in profile.get("TeamIdentifier", []):
        raise ValueError("描述文件的平台或团队与商店签名证书不一致。")
    values = profile.get("Entitlements", {})
    if profile.get("ProvisionsAllDevices") or "ProvisionedDevices" in profile or values.get("get-task-allow"):
        raise ValueError("请使用 Mac App Store Connect 分发描述文件，不要使用开发或 Developer ID 描述文件。")
    prefixes = profile.get("ApplicationIdentifierPrefix", [])
    identifier = values.get("com.apple.application-identifier")
    if identifier not in [prefix + "." + bundle for prefix in prefixes]:
        raise ValueError("描述文件必须明确匹配 fan.yanan.zoodirector，不能使用通配符或其他应用标识。")
    fingerprints = [hashlib.sha1(value).hexdigest().upper() for value in profile.get("DeveloperCertificates", [])]
    if certificate["sha1"].upper() not in fingerprints:
        raise ValueError("描述文件没有包含选定的商店应用签名证书。")
    result = {"com.apple.application-identifier": identifier,
              "com.apple.developer.team-identifier": team}
    if values.get("com.apple.developer.team-identifier") != team:
        raise ValueError("描述文件中的团队权限不一致。")
    if values.get("beta-reports-active") is True:
        result["beta-reports-active"] = True
    return result


def prepare(directory, environment):
    """生成本次构建的公开签名参数及权限文件，不读取发布密码。"""
    application = choose_identity(identities("codesigning"), environment.get("APPSTORE_SIGNING_IDENTITY", ""),
                                  ("Apple Distribution: ", "3rd Party Mac Developer Application: "), "商店应用证书")
    installer = choose_identity(identities(), environment.get("APPSTORE_INSTALLER_IDENTITY", ""),
                                ("3rd Party Mac Developer Installer: ", "Mac Installer Distribution: "), "商店安装包证书")
    team = team_for(application)
    if team_for(installer) != team or environment.get("APPSTORE_TEAM_ID", team) != team:
        raise ValueError("应用证书、安装包证书和 APPSTORE_TEAM_ID 必须属于同一团队。")
    entitlements = plistlib.loads(Path("Resources/ZooDirector.entitlements").read_bytes())
    profile_path = environment.get("APPSTORE_PROVISIONING_PROFILE", "")
    if profile_path:
        path = Path(profile_path).expanduser().resolve(strict=True)
        decoded = subprocess.run(["security", "cms", "-D", "-i", str(path)], check=True, capture_output=True)
        profile = plistlib.loads(decoded.stdout)
        entitlements.update(profile_entitlements(profile, team, application, "fan.yanan.zoodirector"))
        profile_path = str(path)
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "appstore.entitlements").write_bytes(plistlib.dumps(entitlements))
    config = {"application": application["sha1"], "installer": installer["sha1"],
              "application_name": application["name"], "installer_name": installer["name"],
              "team": team, "profile": profile_path}
    (directory / "signing.json").write_text(json.dumps(config))
    print("商店应用签名：", application["name"])
    print("商店安装包签名：", installer["name"])
    print("描述文件：", "已校验" if profile_path else "未配置；当前权限可直接分发到商店，TestFlight 需提供描述文件")


def main():
    """为 shell 发布流程生成经校验的配置，错误时不回显私密凭据。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    prepare(args.directory, os.environ)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
