# gitlab-runner-cfn

セルフホスト GitLab に接続する **GitLab Runner (Docker executor)** を、AWS 上で **Spot EC2 1 台** として立ち上げる CloudFormation テンプレート。

## 構成

```
                 ┌──────────────────────────────────────┐
                 │             (your VPC or new)        │
                 │                                      │
  self-hosted    │   ┌────────────────────────────┐     │
  GitLab  ◄──────┼───┤  EC2 (Spot, AL2023)        │     │
                 │   │   - docker                 │     │
                 │   │   - gitlab-runner          │     │
                 │   │   - IAM: SSM + optional S3 │     │
                 │   └────────────────────────────┘     │
                 │                                      │
                 └──────────────────────────────────────┘
```

- EC2 は常時 1 台（Spot）。中断されると ASG なしのため再作成は手動（または `make delete` → `make deploy`）。
- VPC / Subnet は **既存利用** と **新規作成** を切替可能（`CreateVpc`）。
- Security Group も **既存利用** と **新規作成** を切替可能。セルフホスト GitLab 側で固定 SG をホワイトリスト登録しているケースでは、Runner スタックを作り直しても SG ID が変わらないように **外部管理の SG を渡す** 運用を推奨。
- EC2 には SSM Session Manager でアクセス（`AmazonSSMManagedInstanceCore`）。SSH は任意。

## 前提条件

- AWS CLI v2、`jq`、`make`
- CloudFormation / EC2 / IAM / (任意で VPC) の権限
- セルフホスト GitLab で取得済みの Runner **Registration Token**
- 既存 VPC/Subnet を使う場合、そのサブネットが Public（または NAT 越しでインターネット到達可）で、GitLab サーバに到達できること

## クイックスタート

```bash
cp parameters.sample.json parameters.json
# parameters.json を編集（GitLabUrl / RegistrationToken / VpcId / SubnetId など）

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
| `CreateVpc` | - | `No` | `Yes` で VPC/Subnet/IGW を新規作成 |
| `VpcId` | `CreateVpc=No` 時 | `""` | 既存 VPC ID |
| `SubnetId` | `CreateVpc=No` 時 | `""` | 既存 Public Subnet ID |
| `NewVpcCidr` | - | `10.0.0.0/16` | 新規 VPC の CIDR |
| `NewSubnetCidr` | - | `10.0.1.0/24` | 新規 Subnet の CIDR |
| `ExistingSecurityGroupIds` | - | `""` | 既存 SG の ID（カンマ区切り）。指定時は新規 SG を作成しない |
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

## ネットワークモード

### A. 既存 VPC を使う（デフォルト）

```json
{ "ParameterKey": "CreateVpc", "ParameterValue": "No" },
{ "ParameterKey": "VpcId",     "ParameterValue": "vpc-abc..." },
{ "ParameterKey": "SubnetId",  "ParameterValue": "subnet-abc..." }
```

### B. VPC ごと新規作成

```json
{ "ParameterKey": "CreateVpc",     "ParameterValue": "Yes" },
{ "ParameterKey": "NewVpcCidr",    "ParameterValue": "10.0.0.0/16" },
{ "ParameterKey": "NewSubnetCidr", "ParameterValue": "10.0.1.0/24" }
```

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
- **`cfn-signal` タイムアウト**: UserData が 15 分以内に終わらなかった。`/var/log/cloud-init-output.log` と `/var/log/user-data.log` を確認。
- **GitLab 側に Runner が現れない**: `GitLabUrl` 末尾 `/`、トークン、ネットワーク到達性（SG / ルーティング）を確認。
- **docker ジョブが権限エラー**: DinD を使うなら `RunnerPrivileged=true`。

## ファイル

- `gitlab-runner.yaml` — CloudFormation テンプレート
- `parameters.sample.json` — パラメータのサンプル（コピーして `parameters.json` に）
- `Makefile` — `validate` / `deploy` / `changeset` / `outputs` / `session` / `delete`
