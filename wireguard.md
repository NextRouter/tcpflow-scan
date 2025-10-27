# WireGuard VPN Server on GCP

このドキュメントでは、GCP (Google Cloud Platform) 上の VM インスタンスで WireGuard サーバを展開する方法を説明します。

## 概要

WireGuard は、高速で安全な VPN プロトコルです。このセットアップスクリプトを使用すると、GCP VM 上に WireGuard サーバを簡単に構築できます。

## 前提条件

- GCP プロジェクトと VM インスタンス（Ubuntu 20.04/22.04 または Debian 推奨）
- root アクセス権限
- VM インスタンスの外部 IP アドレス

## セットアップ手順

### 1. VM インスタンスの作成

```bash
gcloud compute instances create wireguard-server \
    --zone=asia-northeast1-a \
    --machine-type=e2-micro \
    --image-family=ubuntu-2204-lts \
    --image-project=ubuntu-os-cloud \
    --boot-disk-size=10GB \
    --tags=wireguard-server
```

### 2. VM インスタンスに SSH 接続

```bash
gcloud compute ssh wireguard-server --zone=asia-northeast1-a
```

### 3. セットアップスクリプトのダウンロードと実行

```bash
# スクリプトをダウンロード
curl -O https://raw.githubusercontent.com/NextRouter/tcpflow-scan/main/setup-wireguard.sh

# 実行権限を付与
chmod +x setup-wireguard.sh

# rootで実行
sudo ./setup-wireguard.sh
```

### 4. ファイアウォールルールの確認

スクリプトは自動的にファイアウォールルールを作成しようとしますが、手動で確認・作成する場合は以下のコマンドを使用します：

```bash
# ファイアウォールルールの作成
gcloud compute firewall-rules create wireguard-51820 \
    --allow=udp:51820 \
    --description="WireGuard VPN" \
    --direction=INGRESS \
    --target-tags=wireguard-server

# VMインスタンスにタグを追加（まだ追加していない場合）
gcloud compute instances add-tags wireguard-server \
    --zone=asia-northeast1-a \
    --tags=wireguard-server
```

## クライアントの追加

セットアップ完了後、以下のコマンドで新しいクライアントを追加できます：

```bash
sudo wg-add-client <クライアント名> <IPアドレス>
```

例：

```bash
sudo wg-add-client laptop 10.8.0.2
sudo wg-add-client smartphone 10.8.0.3
sudo wg-add-client tablet 10.8.0.4
```

このコマンドは以下を実行します：

1. クライアント用の鍵ペアを生成
2. クライアント設定ファイルを作成
3. QR コードを表示（モバイルアプリで簡単にスキャン可能）
4. サーバ設定を更新してクライアントを追加

## クライアント設定の取得

### デスクトップクライアント（Windows/macOS/Linux）

```bash
# 設定ファイルの場所
/etc/wireguard/clients/<クライアント名>/<クライアント名>.conf
```

設定ファイルをダウンロードして、WireGuard クライアントアプリにインポートします：

```bash
# ローカルマシンでSCPを使用してダウンロード
gcloud compute scp wireguard-server:/etc/wireguard/clients/laptop/laptop.conf . \
    --zone=asia-northeast1-a
```

### モバイルクライアント（iOS/Android）

1. WireGuard アプリをダウンロード
2. サーバ上で QR コードを表示：
   ```bash
   sudo qrencode -t ansiutf8 < /etc/wireguard/clients/<クライアント名>/<クライアント名>.conf
   ```
3. アプリで QR コードをスキャン

## 管理コマンド

### ステータス確認

```bash
# WireGuardの状態を確認
sudo wg show

# サービスの状態を確認
sudo systemctl status wg-quick@wg0
```

### サービスの管理

```bash
# サービスの再起動
sudo systemctl restart wg-quick@wg0

# サービスの停止
sudo systemctl stop wg-quick@wg0

# サービスの開始
sudo systemctl start wg-quick@wg0

# サービスの無効化
sudo systemctl disable wg-quick@wg0
```

### 設定ファイルの編集

```bash
# サーバ設定を編集
sudo nano /etc/wireguard/wg0.conf

# 設定を反映
sudo systemctl restart wg-quick@wg0
```

### クライアント接続の確認

```bash
# 接続中のピア（クライアント）を表示
sudo wg show wg0 peers

# 詳細な統計情報を表示
sudo wg show wg0
```

## ネットワーク構成

- **サーバ VPN IP**: 10.8.0.1/24
- **クライアント VPN IP 範囲**: 10.8.0.2 - 10.8.0.254
- **WireGuard ポート**: 51820/UDP
- **DNS**: 8.8.8.8, 8.8.4.4（Google DNS）

## トラブルシューティング

### 接続できない場合

1. ファイアウォールルールを確認：

   ```bash
   gcloud compute firewall-rules list --filter="name:wireguard"
   ```

2. VM インスタンスのタグを確認：

   ```bash
   gcloud compute instances describe wireguard-server \
       --zone=asia-northeast1-a \
       --format="value(tags.items)"
   ```

3. WireGuard サービスのログを確認：

   ```bash
   sudo journalctl -u wg-quick@wg0 -n 50
   ```

4. ネットワーク接続を確認：
   ```bash
   sudo wg show
   sudo ip addr show wg0
   ```

### IP フォワーディングの確認

```bash
# 現在の設定を確認
sysctl net.ipv4.ip_forward

# 有効化（1が表示されればOK）
sudo sysctl -w net.ipv4.ip_forward=1
```

### iptables ルールの確認

```bash
# NATルールを確認
sudo iptables -t nat -L POSTROUTING -v -n

# FORWARDルールを確認
sudo iptables -L FORWARD -v -n
```

## セキュリティのベストプラクティス

1. **定期的な更新**: システムと WireGuard を最新の状態に保つ

   ```bash
   sudo apt update && sudo apt upgrade -y
   ```

2. **鍵の保護**: プライベートキーのパーミッションを確認

   ```bash
   ls -la /etc/wireguard/*.key
   # すべて600であることを確認
   ```

3. **不要なクライアントの削除**: 使用しなくなったクライアントは設定から削除

4. **ログの監視**: 定期的に接続ログを確認

5. **ファイアウォール**: 必要なポート（51820/UDP）のみを開放

## コスト最適化

- **e2-micro インスタンス**: 無料枠で利用可能（月間制限あり）
- **Preemptible VM**: コストを約 70%削減（24 時間以内に停止される可能性あり）
- **リージョン選択**: 最も近いリージョンを選択してレイテンシを削減

## 参考リンク

- [WireGuard 公式サイト](https://www.wireguard.com/)
- [GCP Compute Engine ドキュメント](https://cloud.google.com/compute/docs)
- [WireGuard クライアントダウンロード](https://www.wireguard.com/install/)

## サポート

問題が発生した場合は、以下を確認してください：

- GCP の VM インスタンスが実行中であること
- ファイアウォールルールが正しく設定されていること
- クライアント設定の Endpoint が正しい IP アドレスであること

## ライセンス

このスクリプトは MIT ライセンスの下で提供されています。
