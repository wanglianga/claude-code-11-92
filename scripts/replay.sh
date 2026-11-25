#!/usr/bin/env bash
# 港口靠泊协同服务 —— 三种顺序 + 扰动重排 一键验证脚本
# 用法：bash scripts/replay.sh [BASE_URL]
# 依赖：curl、python3
set -u

BASE="${1:-${BASE_URL:-http://127.0.0.1:8080}}"
USERNAME="${DISPATCH_USER:-dispatch}"
PASSWORD="${DISPATCH_PASS:-dispatch123}"

echo "==> 目标服务: $BASE"

LOGIN_JSON=$(curl -sS --max-time 10 -X POST "$BASE/api/auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"$USERNAME\",\"password\":\"$PASSWORD\"}")
TOKEN=$(echo "$LOGIN_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))' 2>/dev/null)
if [ -z "$TOKEN" ]; then
  echo "登录失败：$LOGIN_JSON" >&2
  exit 2
fi
echo "==> 登录成功，开始完整回放（约 12 秒，含真实 TTL 等待与并发竞速）..."

TMP=$(mktemp -t pb-replay-XXXXXX.json)
trap 'rm -f "$TMP"' EXIT
HTTP=$(curl -sS --max-time 180 -X POST "$BASE/api/replays/full" \
  -H "Authorization: Bearer $TOKEN" -o "$TMP" -w '%{http_code}')
echo "==> POST /api/replays/full -> HTTP $HTTP"

python3 - "$TMP" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding='utf-8') as f:
    d = json.load(f)

failed = []
total_checks = 0
passed_checks = 0

def walk(obj):
    global total_checks, passed_checks
    if isinstance(obj, dict):
        if isinstance(obj.get("checks"), list):
            for c in obj["checks"]:
                total_checks += 1
                if c.get("pass"):
                    passed_checks += 1
                else:
                    failed.append((obj.get("title", "?"), c.get("name", "?")))
        for v in obj.values():
            walk(v)
    elif isinstance(obj, list):
        for v in obj:
            walk(v)

walk(d)
print(f"==> 断言：{passed_checks}/{total_checks} 通过；allPassed={d.get('allPassed')}")
for title, name in failed:
    print(f"  FAIL [{title}] {name}")

if d.get("allPassed") is True and not failed:
    print("ALL_REPLAY_CHECKS_PASSED")
    sys.exit(0)
print("REPLAY_HAS_FAILURES")
sys.exit(1)
PY
EXIT_CODE=$?

if [ "$HTTP" != "200" ]; then
  echo "接口返回非 200，响应前 500 字：" >&2
  head -c 500 "$TMP" >&2
  exit 3
fi
exit $EXIT_CODE
