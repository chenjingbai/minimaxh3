#!/usr/bin/env bash
# ============================================================================
# check-secrets.sh —— 推 GitHub 前扫一遍敏感信息
#
# 用法：bash check-secrets.sh
# 退出码 0 = 没发现问题；1 = 发现可疑内容
# ============================================================================
set -uo pipefail

RED='\033[0m'; R='\033[31m'; Y='\033[33m'; G='\033[32m'; B='\033[36m'
HITS=0

scan() { # $1=说明 $2=正则
  local desc="$1" pat="$2"
  local out
  out=$(grep -rnE "$pat" \
        --include='*.sh' --include='*.py' --include='*.html' \
        --include='*.md' --include='*.json' --include='*.txt' \
        --exclude-dir='.git' --exclude-dir='__pycache__' \
        --exclude='check-secrets.sh' --exclude='.gitignore' \
        . 2>/dev/null || true)
  if [ -n "$out" ]; then
    printf "\033[31m[!]\033[0m %s\n" "$desc"
    echo "$out" | sed 's/^/     /'
    echo
    HITS=$((HITS+1))
  fi
}

echo "=============================================="
echo "  敏感信息扫描"
echo "=============================================="
echo

scan "平台容器主机名（暴露账号/实例）" 'j-[a-z0-9]{15,}'
scan "真实隧道域名" 'rc-[a-f0-9]{12,}\.radeon\.firstdg\.ai|trycloudflare\.com'
scan "集群内网地址" 's3?\.amazonaws|\.svc\.cluster\.local|notebook-egress-proxy'
scan "凭证赋值" '(token|passwd|password|secret|api[_-]?key|access[_-]?key|private[_-]?key)[[:space:]]*[=:][[:space:]]*["'"'"']?[A-Za-z0-9_\-\.]{12,}'
scan "Bearer / Basic 认证头" '(Bearer|Basic)[[:space:]]+[A-Za-z0-9_\-\.=]{20,}'
scan "私钥块" 'BEGIN (RSA|OPENSSH|EC|PGP) PRIVATE KEY'
scan "HF / GitHub token 前缀" '(hf_[A-Za-z0-9]{20,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_)'
scan "疑似邮箱+密码组合" '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}.*(密码|password)[^\n]{0,20}[：:][^\n]{4,}'

echo "=============================================="
if [ "$HITS" -eq 0 ]; then
  printf "\033[32m✓ 没发现明显敏感信息，可以推${NC}\033[0m\n" 2>/dev/null || printf '\033[32m✓ 没发现明显敏感信息，可以推\033[0m\n'
else
  printf '\033[31m发现 %d 类可疑内容，逐条确认后再推\033[0m\n' "$HITS"
fi
echo "=============================================="
echo
echo "提示：文档里的示例地址建议改成占位符："
echo "  rc-xxxxxxxx.radeon.firstdg.ai   ->  rc-<域名>.radeon.firstdg.ai"
echo "  j-xxxxxxxxxxxxxxxx                ->  <实例ID>"
echo

exit $([ "$HITS" -eq 0 ] && echo 0 || echo 1)
