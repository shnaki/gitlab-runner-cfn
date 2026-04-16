# gitlab-runner-cfn

セルフホスト GitLab に接続する **GitLab Runner (Docker executor)** を、AWS 上で **Spot EC2 1 台** として立ち上げる CloudFormation テンプレート。

**前提環境**: 既存 VPC（通常は NAT Gateway を持つプライベートサブネット）へのデプロイに特化。

## 構成

```
                 ┌──────────────────────────────────────┐
                 │           your existing VPC          │
                 │                                      │
                 │   ┌── private subnet ─────────┐      │
  self-hosted    │   │                           │      │
  GitLab  ◄──────┼───┤  EC2 (Spot, AL2023)       │      │
                 │   │   - docker                │      │
                 │   │   - gitlab-runner         │      │
                 │   │   - IAM: SSM + opt S3     │      │
                 │   └───────────┬───────────────┘      │
                 │               │ outbound             │
                 │               ▼                      │
                 │          NAT Gateway ──► Internet    │
                 │     (DockerHub / packages / ssm)     │
                 └──────────────────────────────────────┘
```

- EC2 は常時 1 台（Spot）。中断されると ASG なしのため再作成は手動（または `make delete` → `make deploy`）。
- **VPC / Subnet は既存を渡す前提**。NAT Gateway 経由で outbound を通す private subnet を想定。
- Security Group は **既存利用** と **新規作成** を切替可能。セルフホスト GitLab 側で固定 SG をホワイトリスト登録しているケースでは、Runner スタックを作り直しても SG ID が変わらないように **外部管理の SG を渡す** 運用を推奨。
- Public IP の付与は `AssignPublicIp` で制御（デフォルト `No`）。
- EC2 には SSM Session Manager でアクセス（`AmazonSSMManagedInstanceCore`）。SSH は任意。

## 前提条件

- AWS CLI v2、`jq`、`make`
- CloudFormation / EC2 / IAM の権限
- セルフホスト GitLab で取得済みの Runner **Registration Token**
- Runner を置くサブネットから下記への到達性:
  - GitLab サーバ（VPC 内 / Peering / TGW / DX など）
  - NAT Gateway または VPC Endpoint 経由でインターネット（`dnf`, Docker Hub, `packages.gitlab.com`, `cfn-signal`, SSM エンドポイント）

## クイックスタート

```bash
cp parameters.sample.json parameters.json
# parameters.json を編集（VpcId / SubnetId / GitLabUrl / RegistrationToken など）

make validate
make deploy
make outputs
make session   # SSM Session Manager で接続
```

削除:

```bash
make delete
```

## パラメータ一覧

| 名前 | 必須 | デフォルト | 説明 |
|---|---|---|---|
| `VpcId` | ✓ | - | 既存 VPC ID |
| `SubnetId` | ✓ | - | 既存 Subnet ID（通常は NAT GW route の private subnet） |
| `AssignPublicIp` | - | `No` | `Yes` / `No` / `SubnetDefault`（下記参照） |
| `ExistingSecurityGroupIds` | - | `""` | 既存 SG ID（カンマ区切り）。指定時は新規 SG を作成しない |
| `GitLabUrl` | ✓ | `https://gitlab.example.com/` | セルフホスト GitLab の URL（末尾 `/` 必要） |
| `RegistrationToken` | ✓ | - | Runner 登録トークン（`NoEcho`） |
| `RunnerDescription` | - | `cfn-gitlab-runner` | Runner 説明 |
| `RunnerTags` | - | `aws,docker` | Runner タグ（カンマ区切り） |
| `RunnerConcurrent` | - | `4` | 同時実行ジョブ数 |
| `RunnerDefaultDockerImage` | - | `alpine:latest` | デフォルト Docker イメージ |
| `RunnerPrivileged` | - | `false` | privileged モード（DinD 用途なら `true`） |
| `RunnerLocked` | - | `true` | 現プロジェクトにロック |
| `RunnerRunUntagged` | - | `false` | タグなしジョブを受ける |
| `InstanceType` | - | `t3.small` | `t3.nano` / `t3.micro` / `t3.small` / `t3.medium` / `t3.large` / `m6i.large` |
| `SpotMaxPrice` | - | `""` | Spot 最大価格 USD/時。空ならオンデマンド価格上限 |
| `VolumeSizeGiB` | - | `30` | ルート EBS サイズ |
| `AmiId` | - | AL2023 の SSM Public Parameter | 上書き可 |
| `KeyPairName` | - | `""` | SSH 用 KeyPair（任意） |
| `AllowedSshCidr` | - | `""` | SSH 許可 CIDR（任意、新規 SG 作成時のみ有効） |
| `CacheBucketName` | - | `""` | Runner 分散キャッシュ用 S3 バケット名。指定時のみ S3 ポリシー付与 |

## `AssignPublicIp` の挙動

| 値 | 動作 | 想定シナリオ |
|---|---|---|
| `No`（デフォルト） | ENI に public IP を付与しない | NAT GW 経由で outbound する private subnet。public IPv4 課金も回避 |
| `Yes` | public IP を強制付与 | IGW 付きの public subnet にデプロイする場合 |
| `SubnetDefault` | サブネットの `MapPublicIpOnLaunch` に従う | 環境ごとの挙動をサブネット管理者に委ねたい場合 |

**注意**: `No` で IGW のみの public subnet に置くと outbound できずスタック作成が失敗する。NAT GW もしくは VPC Endpoint を確保すること。

## Security Group モード

### A. 新規 SG を作成（デフォルト）

`ExistingSecurityGroupIds` を空にすると、このスタックが SG を作成・管理する。スタック削除時に SG も消える。

### B. 既存 SG を使う（セルフホスト GitLab で許可済みの SG を再利用）

```json
{ "ParameterKey": "ExistingSecurityGroupIds", "ParameterValue": "sg-0123456789abcdef0" }
```

複数指定可:

```json
{ "ParameterKey": "ExistingSecurityGroupIds", "ParameterValue": "sg-aaaa,sg-bbbb" }
```

このモードでは:
- 新規 SG は作成されず、渡した SG がそのまま EC2 に付く
- スタックを削除しても渡した SG は消えない（外部所有のため）
- スタックを作り直しても SG ID は変わらないので、GitLab 側の許可設定をやり直す必要がない
- `AllowedSshCidr` / SSH 関連は無視される（ingress は既存 SG の設定に従う）

## アクセス

- **SSM Session Manager**（推奨）: `make session`
- **SSH**（任意）: 新規 SG 作成モードで `KeyPairName` と `AllowedSshCidr` の両方を指定した場合のみ 22/tcp が開く

## セキュリティ上の注意

- **Registration token は UserData に埋め込まれる**。`ec2:DescribeInstanceAttribute` 権限を持つ者は取得可能。
- **Registration token 方式は GitLab 16.6 以降で非推奨**。長期運用では、GitLab UI で事前に取得する **Runner Authentication Token** + SSM Parameter Store への移行を推奨。
- **Spot 中断時にジョブは中断される**。本テンプレートは単一 EC2 のため自動復旧しない。
- EBS は暗号化（gp3）。IMDS は v2 強制。

## トラブルシュート

EC2 に入ったら:

```bash
sudo cat /var/log/user-data.log        # UserData 実行ログ
sudo systemctl status gitlab-runner    # サービス状態
sudo journalctl -u gitlab-runner -e    # Runner ログ
sudo gitlab-runner verify              # GitLab への接続確認
sudo cat /etc/gitlab-runner/config.toml
```

よくある失敗:
- **`cfn-signal` タイムアウト**: UserData が 15 分以内に終わらなかった。`/var/log/cloud-init-output.log` と `/var/log/user-data.log` を確認。outbound 不通が典型原因。
- **outbound できない**: サブネットに NAT GW ルートがあるか、SG egress が `0.0.0.0/0` allow か、`AssignPublicIp` の設定がサブネット種別と整合しているかを確認。
- **GitLab 側に Runner が現れない**: `GitLabUrl` 末尾 `/`、トークン、ネットワーク到達性（SG / ルーティング）を確認。
- **docker ジョブが権限エラー**: DinD を使うなら `RunnerPrivileged=true`。

## ファイル

- `gitlab-runner.yaml` — CloudFormation テンプレート
- `parameters.sample.json` — パラメータのサンプル（コピーして `parameters.json` に）
- `Makefile` — `validate` / `deploy` / `changeset` / `outputs` / `session` / `delete`
