#!/bin/bash
#
# 为本地开发建一个稳定的签名身份。
#
# 为什么需要它：ad-hoc 签名的 App 每次重新构建都会生成新的 cdhash，而 TCC（辅助功能授权）
# 是按 cdhash 记的——**每重建一次就得重新授权一次**。用一次稳定身份的证书签名，授权就
# 一直有效了。开发期这点尤其重要，否则改一行代码就要去系统设置里点一遍。
#
# 做法：在独立的 keychain 里自签一张代码签名证书，不动你登录 keychain 里的任何东西。
#
# 用法：scripts/setup-dev-signing.sh
# 卸载：security delete-keychain ~/Library/Keychains/sugarnote-dev.keychain
#       （证书和私钥都在这个 keychain 里，删掉它即可完全清理）

set -euo pipefail

KEYCHAIN_NAME="sugarnote-dev.keychain"
# 这个密码只用于本地这个一次性的开发 keychain（只装一张自签证书），不是任何账号凭据，
# 也不涉及你的登录 keychain。写成明文是为了脚本能无人值守跑。
KEYCHAIN_PASS="sugarnote-dev"
CERT_CN="sugarnote Dev Signing"
KEYCHAIN_PATH="$HOME/Library/Keychains/$KEYCHAIN_NAME"

if security find-certificate -c "$CERT_CN" "$KEYCHAIN_PATH" >/dev/null 2>&1; then
  echo "签名身份已存在：$CERT_CN（$KEYCHAIN_PATH）"
  security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN_PATH"
  exit 0
fi

echo "==> 生成自签证书"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/openssl.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = sugarnote Dev Signing
[ext]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -days 3650 -config "$WORK/openssl.cnf" 2>/dev/null

# 用旧算法打包：OpenSSL 3 默认的 AES-256-CBC + SHA-256 让 macOS 的 Security 框架
# 报 "MAC verification failed during PKCS12 import"。
if ! openssl pkcs12 -export -legacy -out "$WORK/cert.p12" \
      -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
      -passout "pass:$KEYCHAIN_PASS" 2>/dev/null; then
  openssl pkcs12 -export -out "$WORK/cert.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
    -passout "pass:$KEYCHAIN_PASS" 2>/dev/null
fi

echo "==> 建独立 keychain（不动登录 keychain）"
# 上一次失败可能留下了空 keychain，先清掉
security delete-keychain "$KEYCHAIN_PATH" 2>/dev/null || true
security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"   # 6 小时不自动锁
security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN_PATH"

echo "==> 导入证书与私钥"
security import "$WORK/cert.p12" -k "$KEYCHAIN_PATH" \
  -P "$KEYCHAIN_PASS" -T /usr/bin/codesign -T /usr/bin/security >/dev/null

# 没有这一步，codesign 每次用私钥都会弹窗要授权
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "$KEYCHAIN_PASS" "$KEYCHAIN_PATH" >/dev/null

echo "==> 校验"
security find-identity -v -p codesigning "$KEYCHAIN_PATH" | sed 's/^/    /'

echo ""
echo "完成。scripts/build-app.sh 现在会自动用这个身份签名，"
echo "辅助功能授权在重新构建后不会再失效。"
