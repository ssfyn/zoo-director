#!/usr/bin/env python3
"""校验并写入构建版本，正式版本与界面中的开发标记独立保存。"""
import argparse
import os
import plistlib
import re
from pathlib import Path


# 正式版本允许附加预发布或构建标记，标准版本字段只保存三段数字。
VERSION_PATTERN = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?")
# 所有构建号分配与清单写入共用同一格式约束。
BUILD_PATTERN = re.compile(r"[1-9][0-9]{0,3}(?:\.[0-9]{1,2}){0,2}")


def metadata(environment):
    """根据显式参数生成元信息，不根据编译优化模式推断是否正式发布。"""
    version = environment.get("APP_VERSION", "dev")
    build = environment.get("BUILD_NUMBER", "1")
    channel = environment.get("DISTRIBUTION_CHANNEL", "dev")
    match = VERSION_PATTERN.fullmatch(version)
    if version != "dev" and match is None:
        raise ValueError("APP_VERSION 必须是 dev 或有效版本，例如 1.0.0、1.1.0-beta.1。")
    if not BUILD_PATTERN.fullmatch(build):
        raise ValueError("BUILD_NUMBER 必须符合 Apple 构建号格式，例如 42 或 42.1。")
    if channel not in {"dev", "github", "appstore"}:
        raise ValueError("DISTRIBUTION_CHANNEL 必须是 dev、github 或 appstore。")
    if channel != "dev" and version == "dev":
        raise ValueError("分发构建必须显式提供 APP_VERSION。")
    short_version = ".".join(match.groups()) if match else "0.0.0"
    if channel == "appstore" and version != short_version:
        raise ValueError("App Store 版本只能使用三段数字，不能包含预发布标记。")
    return {"CFBundleShortVersionString": short_version, "CFBundleVersion": build,
            "ZooDirectorDisplayVersion": version, "ZooDirectorDistributionChannel": channel}


def main():
    """先校验所有参数，可独立检查，也可在签名前更新已有应用清单。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plist", nargs="?")
    parser.add_argument("--validate-only", action="store_true")
    args = parser.parse_args()
    values = metadata(os.environ)
    if args.validate_only:
        return
    if not args.plist:
        parser.error("请指定应用 Info.plist，或使用 --validate-only。")
    path = Path(args.plist)
    with path.open("rb") as stream:
        info = plistlib.load(stream)
    info.update(values)
    with path.open("wb") as stream:
        plistlib.dump(info, stream, sort_keys=False)


if __name__ == "__main__":
    try:
        main()
    except ValueError as error:
        raise SystemExit(str(error))
