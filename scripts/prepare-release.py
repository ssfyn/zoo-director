#!/usr/bin/env python3
"""从发布标签解析版本，避免覆盖不可变发行版或重复构建已上传的资产。"""
import json
import os
import subprocess
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
import importlib.util

# 共享版本校验规则，避免标签、应用版本及文件名采用不同的解析方式。
spec = importlib.util.spec_from_file_location("build_metadata", Path(__file__).with_name("build-metadata.py"))
build_metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build_metadata)


def release_values(tag, run_number, run_attempt):
    """只接受带 v 的语义版本标签，两个架构共享一次运行的构建号。"""
    if not tag.startswith("v"):
        raise ValueError("发布标签必须以 v 开头，例如 v1.0.0。")
    version = tag[1:]
    values = {"APP_VERSION": version, "BUILD_NUMBER": f"{run_number}.{run_attempt}", "DISTRIBUTION_CHANNEL": "github"}
    build_metadata.metadata(values)
    return values


def should_build(event, release, version):
    """已发布且附件完整时跳过，锁定但缺少附件的发行版明确拒绝补传。"""
    if release is None:
        return True
    names = {asset["name"] for asset in release.get("assets", [])}
    expected = {f"ZooDirector-{version}-{arch}.dmg" for arch in ["arm64", "x86_64"]}
    if expected <= names and (event == "release" or release.get("immutable", False)):
        return False
    if release.get("immutable", False):
        raise ValueError("该发行版已不可变且附件不完整。请使用新标签，通过手动工作流先构建草稿再发布。")
    return True


def fetch_release(tag):
    """只读查询当前仓库的发行版；仅将明确的 404 视为尚未创建。"""
    repository = os.environ["GITHUB_REPOSITORY"]
    api = os.environ.get("GITHUB_API_URL", "https://api.github.com")
    url = f"{api}/repos/{repository}/releases/tags/{urllib.parse.quote(tag, safe='')}"
    request = urllib.request.Request(url, headers={"Authorization": "Bearer " + os.environ["GH_TOKEN"],
        "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise ValueError(f"读取 Release 失败，HTTP {error.code}。") from None


def main():
    """核对检出的提交与标签一致，再输出经过校验的 Actions 参数。"""
    tag = os.environ["RELEASE_TAG"]
    values = release_values(tag, os.environ["GITHUB_RUN_NUMBER"], os.environ["GITHUB_RUN_ATTEMPT"])
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    tagged = subprocess.check_output(["git", "rev-parse", f"refs/tags/{tag}^{{commit}}"], text=True).strip()
    if commit != tagged:
        raise ValueError("检出的代码与发布标签不一致。")
    build = should_build(os.environ["GITHUB_EVENT_NAME"], fetch_release(tag), values["APP_VERSION"])
    outputs = {"tag": tag, "version": values["APP_VERSION"], "build_number": values["BUILD_NUMBER"], "build": str(build).lower()}
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.writelines(f"{key}={value}\n" for key, value in outputs.items())


if __name__ == "__main__":
    try:
        main()
    except (ValueError, urllib.error.URLError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
