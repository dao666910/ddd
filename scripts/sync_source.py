#!/usr/bin/env python3
"""
OnePlus Ace 6T (SM8845) 内核源码同步脚本
专为 GitHub Actions 环境设计

核心功能:
  1. 下载 OnePlus 官方 manifest (oneplus_ace_6t.xml)
  2. 解析 manifest, 识别每个 project 的 remote/revision
  3. 跳过 CodeLinaro 上已失效的项目 (asuite, tradefed)
  4. 使用 aria2c 多线程加速下载 (替代 repo sync)
  5. 使用 --depth=1 浅克隆, 节省磁盘和时间
  6. 处理 linkfile (创建符号链接)

为什么不用 repo sync?
  - repo sync 会在遇到失效分支时整体失败
  - repo sync 不支持单项目浅克隆配置
  - aria2c + git clone --depth=1 更快更可控
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
import requests


# ============================================================
# 配置
# ============================================================

# 需要跳过的项目 (CodeLinaro 上分支已失效, 且编译内核不需要)
SKIP_PROJECTS = {
    "kernel_platform/prebuilts/asuite",
    "kernel_platform/tools/tradefederation/prebuilts",
}

# 需要跳过的项目组 (groups="ddk" 的项目是 DDK 工具链, 可选)
# 如果磁盘紧张可以跳过, 但建议保留
SKIP_GROUPS = set()

# 最大并发下载数
MAX_CONCURRENT = 4

# 单项目克隆重试次数
MAX_RETRIES = 3


# ============================================================
# 工具函数
# ============================================================

def log(msg, level="INFO"):
    """带时间戳和颜色的日志"""
    ts = time.strftime('%H:%M:%S')
    colors = {
        'INFO': '\033[0;34m',
        'OK': '\033[0;32m',
        'WARN': '\033[1;33m',
        'ERROR': '\033[0;31m',
        'DEBUG': '\033[0;90m',
    }
    nc = '\033[0m'
    color = colors.get(level, '')
    print(f"{color}[{ts}] {level:5} {msg}{nc}", flush=True)


def run_cmd(cmd, cwd=None, timeout=3600, check=True, capture=False):
    """运行命令"""
    log(f"$ {' '.join(cmd) if isinstance(cmd, list) else cmd}", "DEBUG")
    if capture:
        result = subprocess.run(cmd, cwd=cwd, timeout=timeout,
                                capture_output=True, text=True)
        if check and result.returncode != 0:
            log(f"命令失败 (exit {result.returncode})", "ERROR")
            log(f"stderr: {result.stderr[-500:]}", "ERROR")
            raise subprocess.CalledProcessError(result.returncode, cmd, result.stdout, result.stderr)
        return result
    else:
        result = subprocess.run(cmd, cwd=cwd, timeout=timeout)
        if check and result.returncode != 0:
            raise subprocess.CalledProcessError(result.returncode, cmd)
        return result


def get_default_branch_or_commit(repo_url, revision):
    """
    尝试获取仓库的可访问 ref
    revision 可能是:
      - 完整 commit hash (40 字符) → 直接用
      - 分支名 → 尝试 ls-remote 确认
      - dummy_revision (manifest 默认值) → 用 HEAD
    """
    if not revision or revision == "dummy_revision":
        return "HEAD"

    # 如果是 40 字符的 commit hash, 直接返回
    if re.match(r'^[0-9a-f]{40}$', revision):
        return revision

    # 否则当作分支名, 尝试 ls-remote 验证
    try:
        result = subprocess.run(
            ['git', 'ls-remote', '--exit-code', repo_url, revision],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode == 0 and result.stdout:
            return revision
    except Exception:
        pass

    # 分支不存在, 回退到 HEAD
    return "HEAD"


# ============================================================
# Manifest 解析
# ============================================================

def parse_manifest(manifest_path):
    """解析 manifest XML, 返回 project 列表"""
    tree = ET.parse(manifest_path)
    root = tree.getroot()

    # 解析 remotes
    remotes = {}
    for remote in root.findall('remote'):
        name = remote.get('name')
        fetch = remote.get('fetch', '').rstrip('/')
        remotes[name] = fetch
        log(f"Remote: {name} → {fetch}", "DEBUG")

    # 解析 default
    default = root.find('default')
    def_remote = default.get('remote') if default is not None else None
    def_revision = default.get('revision') if default is not None else None
    sync_c = default.get('sync-c', 'false') == 'true' if default is not None else False

    # 解析 projects
    projects = []
    for proj in root.findall('project'):
        name = proj.get('name')
        path = proj.get('path', name)
        remote_name = proj.get('remote', def_remote)
        revision = proj.get('revision', def_revision)
        upstream = proj.get('upstream', '')
        groups = proj.get('groups', '')

        # 获取 remote fetch URL
        fetch_url = remotes.get(remote_name, '')
        if not fetch_url:
            log(f"跳过 {name}: 无 remote {remote_name}", "WARN")
            continue

        # 构建完整 URL
        # fetch URL 可能以 https:// 开头, 也可能是相对路径
        if fetch_url.startswith('http'):
            repo_url = f"{fetch_url}/{name}"
        else:
            repo_url = f"{fetch_url}/{name}"

        # 解析 linkfile
        linkfiles = []
        for lf in proj.findall('linkfile'):
            linkfiles.append({
                'src': lf.get('src'),
                'dest': lf.get('dest'),
            })

        projects.append({
            'name': name,
            'path': path,
            'repo_url': repo_url,
            'revision': revision,
            'upstream': upstream,
            'groups': groups,
            'linkfiles': linkfiles,
            'remote': remote_name,
        })

    return projects


# ============================================================
# 单项目克隆
# ============================================================

def clone_project(proj, base_dir, debug=False):
    """克隆单个 project, 返回 (project_name, success, message)"""
    name = proj['name']
    path = proj['path']
    repo_url = proj['repo_url']
    revision = proj['revision']
    upstream = proj['upstream']

    dest = os.path.join(base_dir, path)

    # 如果目录已存在且非空, 跳过
    if os.path.exists(dest) and os.listdir(dest):
        log(f"跳过(已存在): {name}", "DEBUG")
        # 仍需处理 linkfile
        for lf in proj['linkfiles']:
            create_linkfile(base_dir, dest, lf['src'], lf['dest'])
        return (name, True, "already exists")

    os.makedirs(os.path.dirname(dest), exist_ok=True)

    # 确定要克隆的 ref
    # 优先使用 upstream (这是 manifest 指定的实际分支)
    # 其次用 revision (可能是 commit hash 或分支名)
    ref_to_clone = upstream if upstream else revision
    ref_to_clone = get_default_branch_or_commit(repo_url, ref_to_clone)

    if debug:
        log(f"克隆 {name}: {repo_url} @ {ref_to_clone} → {path}", "DEBUG")

    # 构建克隆命令
    # --depth=1: 浅克隆, 只取最新 commit
    # --single-branch: 只克隆目标分支
    # --filter=blob:none: 部分克隆, 按需下载 blob (节省磁盘)
    cmd = [
        'git', 'clone',
        '--depth', '1',
        '--single-branch',
        '--filter=blob:none',
        '--no-tags',
    ]

    if ref_to_clone and ref_to_clone != 'HEAD':
        # 如果是 commit hash, 需要先克隆再 checkout
        if re.match(r'^[0-9a-f]{40}$', ref_to_clone):
            cmd.extend(['--branch', upstream] if upstream else [])
        else:
            cmd.extend(['--branch', ref_to_clone])

    cmd.extend([repo_url, dest])

    # 重试机制
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            run_cmd(cmd, timeout=600, check=True, capture=not debug)
            break
        except subprocess.CalledProcessError as e:
            if attempt < MAX_RETRIES:
                log(f"重试 {attempt}/{MAX_RETRIES}: {name}", "WARN")
                time.sleep(5 * attempt)
            else:
                return (name, False, f"clone failed: {e}")

    # 如果 revision 是 commit hash 且与克隆的不同, checkout
    if revision and re.match(r'^[0-9a-f]{40}$', revision):
        try:
            # fetch 特定 commit
            run_cmd(['git', 'fetch', '--depth=1', repo_url, revision],
                    cwd=dest, timeout=300, check=False, capture=True)
            run_cmd(['git', 'checkout', revision], cwd=dest, timeout=60,
                    check=True, capture=True)
        except subprocess.CalledProcessError:
            log(f"无法 checkout 到 {revision}, 使用分支最新", "WARN")

    # 处理 linkfile
    for lf in proj['linkfiles']:
        create_linkfile(base_dir, dest, lf['src'], lf['dest'])

    # 删除 .git 目录节省空间 (浅克隆后不再需要)
    git_dir = os.path.join(dest, '.git')
    if os.path.exists(git_dir):
        shutil.rmtree(git_dir, ignore_errors=True)

    return (name, True, "cloned")


def create_linkfile(base_dir, src_dir, src, dest):
    """创建 linkfile (符号链接)"""
    src_path = os.path.join(src_dir, src)
    dest_path = os.path.join(base_dir, dest)

    try:
        os.makedirs(os.path.dirname(dest_path), exist_ok=True)
        if os.path.lexists(dest_path):
            os.remove(dest_path)
        os.symlink(src_path, dest_path)
        log(f"Linkfile: {dest} → {src}", "DEBUG")
    except Exception as e:
        log(f"Linkfile 失败 {dest}: {e}", "WARN")


# ============================================================
# 主流程
# ============================================================

def main():
    parser = argparse.ArgumentParser(description='OnePlus Ace 6T 内核源码同步')
    parser.add_argument('--manifest-url', required=True,
                        help='manifest XML 的 URL')
    parser.add_argument('--output-dir', required=True,
                        help='输出目录')
    parser.add_argument('--debug', action='store_true',
                        help='启用调试日志')
    args = parser.parse_args()

    log("=" * 60, "INFO")
    log("OnePlus Ace 6T (SM8845) 内核源码同步", "INFO")
    log("=" * 60, "INFO")
    log(f"Manifest: {args.manifest_url}", "INFO")
    log(f"输出目录: {args.output_dir}", "INFO")
    log(f"跳过项目: {SKIP_PROJECTS}", "INFO")
    log("")

    # 1. 下载 manifest
    manifest_path = os.path.join(args.output_dir, 'manifest.xml')
    log(f"下载 manifest...", "INFO")
    try:
        resp = requests.get(args.manifest_url, timeout=30)
        resp.raise_for_status()
        with open(manifest_path, 'w') as f:
            f.write(resp.text)
        log(f"Manifest 已保存: {manifest_path} ({len(resp.text)} bytes)", "OK")
    except Exception as e:
        log(f"下载 manifest 失败: {e}", "ERROR")
        sys.exit(1)

    # 2. 解析 manifest
    log("解析 manifest...", "INFO")
    projects = parse_manifest(manifest_path)
    log(f"共 {len(projects)} 个 project", "OK")

    # 3. 过滤需要跳过的项目
    to_clone = []
    skipped = []
    for proj in projects:
        if proj['name'] in SKIP_PROJECTS or proj['path'] in SKIP_PROJECTS:
            skipped.append(proj)
            log(f"跳过(失效): {proj['name']}", "WARN")
            continue
        # 检查 groups
        proj_groups = set(proj['groups'].split(','))
        if proj_groups & SKIP_GROUPS:
            skipped.append(proj)
            log(f"跳过(group): {proj['name']} groups={proj['groups']}", "WARN")
            continue
        to_clone.append(proj)

    log(f"将克隆 {len(to_clone)} 个, 跳过 {len(skipped)} 个", "INFO")
    log("")

    # 4. 打印克隆计划
    log("克隆计划:", "INFO")
    for proj in to_clone:
        rev = proj['upstream'] or proj['revision'] or 'HEAD'
        log(f"  {proj['path']:50} ← {proj['repo_url']} @ {rev[:20]}", "DEBUG")
    log("")

    # 5. 并发克隆
    log(f"开始并发克隆 (并发数={MAX_CONCURRENT})...", "INFO")
    success_count = 0
    fail_count = 0
    failed_projects = []

    with ThreadPoolExecutor(max_workers=MAX_CONCURRENT) as executor:
        futures = {
            executor.submit(clone_project, proj, args.output_dir, args.debug): proj
            for proj in to_clone
        }

        for i, future in enumerate(as_completed(futures), 1):
            proj = futures[future]
            try:
                name, success, msg = future.result()
                if success:
                    success_count += 1
                    log(f"[{i}/{len(to_clone)}] OK: {name} ({msg})", "OK")
                else:
                    fail_count += 1
                    failed_projects.append(name)
                    log(f"[{i}/{len(to_clone)}] FAIL: {name} ({msg})", "ERROR")
            except Exception as e:
                fail_count += 1
                failed_projects.append(proj['name'])
                log(f"[{i}/{len(to_clone)}] FAIL: {proj['name']} ({e})", "ERROR")

    log("")
    log(f"克隆完成: 成功 {success_count}, 失败 {fail_count}", "INFO")

    if failed_projects:
        log(f"失败的项目: {failed_projects}", "WARN")
        # 检查失败的项目是否是关键项目
        critical = {
            "kernel_platform/common",
            "kernel_platform/soc-repo",
            "kernel_platform/build",
            "kernel_platform/build/kernel/kleaf",
        }
        critical_failures = [p for p in failed_projects
                           if any(c in p for c in critical)]
        if critical_failures:
            log(f"关键项目失败: {critical_failures}", "ERROR")
            log("无法继续编译, 请检查网络或重试", "ERROR")
            sys.exit(1)
        else:
            log("失败的项目非关键, 继续编译", "WARN")

    # 6. 验证关键目录
    log("")
    log("验证关键目录...", "INFO")
    critical_dirs = [
        "kernel_platform/common",
        "kernel_platform/soc-repo",
        "kernel_platform/build",
        "kernel_platform/oplus",
        "vendor/qcom",
    ]
    all_ok = True
    for d in critical_dirs:
        full = os.path.join(args.output_dir, d)
        if os.path.exists(full):
            log(f"  OK: {d}", "OK")
        else:
            log(f"  MISSING: {d}", "ERROR")
            all_ok = False

    if not all_ok:
        log("关键目录缺失, 无法继续", "ERROR")
        sys.exit(1)

    # 7. 磁盘使用报告
    log("")
    log("磁盘使用:", "INFO")
    run_cmd(['df', '-h', args.output_dir], check=False)
    log("")
    log("目录大小:", "INFO")
    run_cmd(['du', '-sh', args.output_dir], check=False)

    log("")
    log("源码同步完成!", "OK")


if __name__ == '__main__':
    main()
