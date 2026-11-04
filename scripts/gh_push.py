#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
通过 GitHub REST API 创建仓库、上传文件、触发 Actions、查询状态。
无需 git、无需浏览器，仅需一个 PAT（含 repo + workflow 权限）。

用法:
  python gh_push.py check
  python gh_push.py push  [仓库名]
  python gh_push.py trigger [仓库名]
  python gh_push.py status [仓库名]
  python gh_push.py artifact [仓库名] [输出目录]

令牌来源: 环境变量 GITHUB_TOKEN，或同目录 ../.gh_token 文件
"""
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

API = "https://api.github.com"
ROOT = Path(__file__).resolve().parent.parent  # kernel-build/
DEFAULT_REPO = "cezanne-kernel"

# 要上传的文件（相对 ROOT）
FILES = [
    ".gitattributes",
    "README.md",
    ".github/workflows/build.yml",
    "anykernel/anykernel.sh",
    "configs/vermagic.fragment",
    "configs/base.config",
    "configs/vendor_versions.txt",
    "configs/descope.fragment",
    "configs/erofs.fragment",
    "configs/ksu.fragment",
    "scripts/build.sh",
    "scripts/fetch_erofs.sh",
    "scripts/patch_vendor.sh",
]


def token():
    t = os.environ.get("GITHUB_TOKEN", "").strip()
    if not t:
        p = ROOT / ".gh_token"
        if p.exists():
            t = p.read_text(encoding="utf-8").strip()
    if not t:
        sys.exit("缺少令牌：设置环境变量 GITHUB_TOKEN，或写入 %s" % (ROOT / ".gh_token"))
    return t


def req(method, path, body=None, tok=None, raw=False):
    url = path if path.startswith("http") else API + path
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
    r = urllib.request.Request(url, data=data, method=method)
    r.add_header("Authorization", "Bearer " + (tok or token()))
    r.add_header("Accept", "application/vnd.github+json")
    r.add_header("User-Agent", "cezanne-kernel-build")
    r.add_header("X-GitHub-Api-Version", "2022-11-28")
    if data:
        r.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(r, timeout=60) as resp:
            headers = dict(resp.headers)
            payload = resp.read()
            if raw:
                return payload, headers
            return (json.loads(payload) if payload else {}), headers
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:500]
        sys.exit("HTTP %s %s %s\n%s" % (e.code, method, url, detail))


def cmd_check():
    me, h = req("GET", "/user")
    print("账号:", me["login"])
    print("令牌 scopes:", h.get("X-OAuth-Scopes", "(fine-grained 不显示)"))
    scopes = h.get("X-OAuth-Scopes", "")
    need = []
    if "repo" not in scopes and "fine-grained" not in scopes and not scopes:
        pass
    if scopes and "repo" not in scopes:
        need.append("repo")
    if scopes and "workflow" not in scopes:
        need.append("workflow")
    if need:
        print("⚠️  缺少 scope:", ", ".join(need), "——传 .github/workflows 必须要有 workflow")
    else:
        print("✅ scope 检查通过（或为 fine-grained 令牌，靠仓库权限控制）")
    # 能否创建仓库 / 剩余额度
    rl, _ = req("GET", "/rate_limit")
    core = rl["resources"]["core"]
    print("API 额度: %s/%s" % (core["remaining"], core["limit"]))
    return me["login"]


def cmd_push(repo_name):
    login = cmd_check()
    print()
    # 1) 建仓库（已存在则复用）
    try:
        repo, _ = req("GET", "/repos/%s/%s" % (login, repo_name))
        print("仓库已存在，复用:", repo["html_url"])
    except SystemExit:
        repo, _ = req("POST", "/user/repos", {
            "name": repo_name,
            "description": "Redmi K30 Ultra (cezanne) 4.14 kernel with EROFS backport for HyperOS 4 port",
            "private": False,
            "auto_init": False,
            "has_issues": False,
            "has_wiki": False,
            "has_projects": False,
        })
        print("已创建仓库:", repo["html_url"])

    branch = repo.get("default_branch") or "main"

    # 2) 逐个上传文件
    ok = 0
    for rel in FILES:
        src = ROOT / rel
        if not src.exists():
            print("  ✗ 本地缺失，跳过:", rel)
            continue
        data = src.read_bytes().replace(b"\r\n", b"\n")  # 强制 LF
        body = {
            "message": "add " + rel,
            "content": base64.b64encode(data).decode("ascii"),
            "branch": branch,
        }
        # 若已存在需要 sha
        try:
            cur, _ = req("GET", "/repos/%s/%s/contents/%s?ref=%s" % (login, repo_name, rel, branch))
            body["sha"] = cur["sha"]
            body["message"] = "update " + rel
        except SystemExit:
            pass
        req("PUT", "/repos/%s/%s/contents/%s" % (login, repo_name, rel), body)
        ok += 1
        print("  ✓ %-32s %6d bytes" % (rel, len(data)))

    print("\n上传完成: %d/%d 个文件" % (ok, len(FILES)))

    # 3) 校验 workflow 是否被识别
    time.sleep(3)
    wfs, _ = req("GET", "/repos/%s/%s/actions/workflows" % (login, repo_name))
    if wfs.get("total_count"):
        for w in wfs["workflows"]:
            print("✅ Actions 已识别:", w["name"], "|", w["path"], "| state=", w["state"])
    else:
        print("❌ Actions 未识别到任何 workflow —— .github/workflows/build.yml 可能没传上去")
    print("\n仓库地址:", repo["html_url"])
    return login


def cmd_trigger(repo_name, diag=False):
    login = cmd_check_quiet()
    req("POST", "/repos/%s/%s/actions/workflows/build.yml/dispatches" % (login, repo_name), {
        "ref": "main",
        "inputs": {"enable_erofs": True, "enable_ksu": False,
                   "localversion": "-perf-00252-g2f26b5917fd6",
                   "relax_modversions": True,
                   "diag_only": bool(diag)},
    })
    print("已触发 workflow（enable_erofs=true, enable_ksu=false, diag_only=%s）" % bool(diag))


def cmd_check_quiet():
    me, _ = req("GET", "/user")
    return me["login"]


def cmd_status(repo_name):
    login = cmd_check_quiet()
    runs, _ = req("GET", "/repos/%s/%s/actions/runs?per_page=3" % (login, repo_name))
    if not runs.get("total_count"):
        print("还没有任何运行记录")
        return
    for r in runs["workflow_runs"]:
        print("run #%s  %s  status=%s  conclusion=%s  %s"
              % (r["run_number"], r["created_at"], r["status"],
                 r["conclusion"], r["html_url"]))
        if r["status"] != "completed":
            # 打印各 job 步骤
            jobs, _ = req("GET", "/repos/%s/%s/actions/runs/%s/jobs" % (login, repo_name, r["id"]))
            for j in jobs.get("jobs", []):
                print("    job:", j["name"], j["status"], j["conclusion"])
                for s in j.get("steps", []):
                    mark = {"success": "✓", "failure": "✗", "skipped": "-"}.get(s["conclusion"] or "", "…")
                    print("      %s %s" % (mark, s["name"]))


def cmd_artifact(repo_name, out_dir):
    login = cmd_check_quiet()
    runs, _ = req("GET", "/repos/%s/%s/actions/runs?per_page=1" % (login, repo_name))
    if not runs.get("total_count"):
        sys.exit("没有运行记录")
    run = runs["workflow_runs"][0]
    if run["status"] != "completed":
        sys.exit("最近一次运行尚未完成: status=%s" % run["status"])
    arts, _ = req("GET", "/repos/%s/%s/actions/runs/%s/artifacts" % (login, repo_name, run["id"]))
    if not arts.get("total_count"):
        sys.exit("该次运行没有产物，结论: %s" % run["conclusion"])
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    for a in arts["artifacts"]:
        dst = out / (a["name"] + ".zip")
        data, _ = req("GET", a["archive_download_url"], raw=True)
        dst.write_bytes(data)
        print("已下载 %s  (%.1f MB) -> %s" % (a["name"], len(data) / 1048576, dst))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    cmd = sys.argv[1]
    repo = sys.argv[3] if len(sys.argv) > 3 else (sys.argv[2] if len(sys.argv) > 2 and not sys.argv[2].startswith("-") else DEFAULT_REPO)
    if cmd == "check":
        cmd_check()
    elif cmd == "push":
        cmd_push(sys.argv[2] if len(sys.argv) > 2 else DEFAULT_REPO)
    elif cmd == "trigger":
        cmd_trigger(sys.argv[2] if len(sys.argv) > 2 else DEFAULT_REPO,
                  diag=(len(sys.argv) > 3 and sys.argv[3] == "diag"))
    elif cmd == "status":
        cmd_status(sys.argv[2] if len(sys.argv) > 2 else DEFAULT_REPO)
    elif cmd == "artifact":
        cmd_artifact(sys.argv[2] if len(sys.argv) > 2 else DEFAULT_REPO,
                     sys.argv[3] if len(sys.argv) > 3 else str(ROOT.parent / "kernel-dist"))
    else:
        sys.exit(__doc__)
