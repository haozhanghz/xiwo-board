# 发布签名

发布包用项目自己的证书签名，不再用 ad-hoc 签名。

## 为什么

macOS 记录录屏、麦克风这些权限时，记的是应用签名里的「指定要求」（designated requirement）。
ad-hoc 签名的指定要求就是这一次构建的哈希，每个版本都不一样，所以更新以后系统把它当成另一个应用：
设置里讲课板还开着，录制时却又要权限。

用固定证书签名后，指定要求变成

    identifier "io.github.haozhanghz.xiwoboard" and certificate root = H"<证书的 SHA-1>"

以后的版本只要还用这个证书，就都满足它，权限一直有效。从 ad-hoc 签名的旧版本升级上来时，还要最后重新授权一次。

这是自签名证书，不是 Apple 签发的，Gatekeeper 仍然把应用当作「未识别的开发者」，第一次打开的步骤和以前一样。

## 证书放在哪

证书和私钥只放在仓库的 Actions 密钥 `XIWOBOARD_SIGNING_P12` 里（base64 编码的 PKCS#12），不进仓库。

- CI 用 `scripts/import-signing-identity.sh` 把它导入一个临时钥匙串，`scripts/build-app.sh` 用它签名，并在日志里打印指定要求。
- 推送到 `main` 或推送标签时，没有这个密钥构建会失败，免得发出 ad-hoc 签名的版本；PR 构建拿不到密钥时退回 ad-hoc 签名。

## 第一次设置

在自己的 Mac 上运行一次：

    scripts/signing/make-certificate.sh

它生成证书（有效期 25 年），复制到剪贴板，并打开新建密钥的网页：Name 填 `XIWOBOARD_SIGNING_P12`，
Secret 里粘贴，点 Add secret。本机不留副本。

## 换证书

再运行一次 `make-certificate.sh`，用新内容更新同名密钥。换证书后，所有人更新时都要重新授权一次，所以只在私钥泄露时才换。
