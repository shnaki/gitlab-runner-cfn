# gitlab-runner-cfn

セルフホスト GitLab に接続する **GitLab Runner (Docker executor)** を、AWS 上で **Spot EC2 1 台** として立ち上げる CloudFormation テンプレート。

**前提環境**: 既存 VPC へのデプロイに特化。プライベートサブネット（NAT Gateway）・パブリックサブネット（IGW + `AssignPublicIp=Yes`）の両構成をサポート。

## 構成

パターン A（デフォルト）: プライベートサブネット + NAT Gateway

```
                 ┌──────────────────────────────────────┐
                 │           your existing VPC          │
                 │                                      │
                 │   ┌── private subnet ─────────┐      │
  self-hosted    │   │                           │      │
  GitLab  ◄──────┼───┤  EC2 (Spot, AL2023)       │      │
                 │   │   - docker                │      │
                 │   │   - gitlab-runner         │      │
                 │   │   - IAM: SSM + opt S3/ECR │      │
                 │   └───────────┬───────────────┘      │
                 │               │ outbound             │
                 │               ▼                      │
                 │          NAT Gateway ──► Internet    │
                 │     (DockerHub / packages / ssm)     │
                 └──────────────────────────────────────┘
                               │ logs
                               ▼
                      CloudWatch Logs
```

パターン B: パブリックサブネット + IGW（`AssignPublicIp=Yes` が必要）

```
                 ┌──────────────────────────────────────┐
                 │           your existing VPC          │
                 │                                      │
                 │   ┌── public subnet ──────────┐      │
  self-hosted    │   │                           │      │
  GitLab  ◄──────┼───┤  EC2 (Spot, AL2023)       │      │
                 │   │   - docker                │      │
                 │   │   - gitlab-runner         │      │
                 │   │   - IAM: SSM + opt S3/ECR │      │
                 │   └───────────┬───────────────┘      │
                 │               │ outbound             │
                 │               ▼                      │
                 │      Internet Gateway ──► Internet   │
                 │     (DockerHub / packages / ssm)     │
                 └──────────────────────────────────────┘
                               │ logs
                               ▼
                      CloudWatch Logs
```

- EC2 は常時 1 台（Spot）。中断されると ASG なしのため再作成は手動（または `make delete` → `make deploy`）。
- `RunnerStateVolumeId` を使うと、`/etc/gitlab-runner` を永続 EBS に退避して同じ runner 登録を引き継げる。未指定時は retained な state volume を新規作成する。
- **VPC / Subnet は既存を渡す前提**。Private subnet（NAT GW 経由 outbound）と public subnet（IGW + `AssignPublicIp=Yes`）の両方に対応。
- Security Group は **既存利用** と **新規作成** を切替可能。セルフホスト GitLab 側で固定 SG をホワイトリスト登録しているケースでは、Runner スタックを作り直しても SG ID が変わらないように **外部管理の SG を渡す** 運用を推奨。
- Public IP の付与は `AssignPublicIp` で制御（デフォルト `No`）。
- EC2 には SSM Session Manager でアクセス（`AmazonSSMManagedInstanceCore`）。SSH は任意。
- IAM ロールは **別スタック** (`gitlab-runner-iam.yaml`) で管理する。これにより IAM 権限を持つ管理者のみが IAM 変更を担当でき、メインスタックのデプロイには IAM 権限が不要になる。

## 前提条件

- AWS CLI v2、`jq`、`make`
- CloudFormation / EC2 権限（メインスタック）
- CloudFormation / IAM 権限（IAM スタック — 初回のみ）
- セルフホスト GitLab で取得済みの Runner トークン
  - GitLab 14.2: **Registration Token**
  - 新しい GitLab: **Runner Authentication Token** (`glrt-...`)
- Runner を置くサブネットから下記への到達性:
  - GitLab サーバ（VPC 内 / Peering / TGW / DX など）
  - インターネット（NAT Gateway、IGW + public IP、または VPC Endpoint 経由）
    （`dnf`, Docker Hub, `packages.gitlab.com`, `cfn-signal`, SSM エンドポイント）

## クイックスタート

### ステップ 1: IAM スタックをデプロイ（初回のみ・IAM 権限が必要）

```bash
cp parameters-iam.sample.json parameters-iam.json
# parameters-iam.json を編集（必要な S3/ECR 権限のみ値を設定）

make validate-iam
make deploy-iam
make outputs-iam
```

### ステップ 2: メインスタックをデプロイ

```bash
cp parameters.sample.json parameters.json
# parameters.json を編集（VpcId / SubnetId / GitLabUrl / RegistrationToken / IamStackName など）
# 初回は RunnerStateVolumeId を空のままにしてよい。make outputs の RunnerStateVolumeIdUsed を控えておくと再利用できる。

make validate
make deploy
make outputs
make session   # SSM Session Manager で接続
```

削除:

```bash
make delete      # メインスタック（RunnerStateVolumeId 未指定時に作られた state volume は retain される）
make delete-iam  # IAM スタック（メインスタック削除後）
```

再デプロイ時に同じ runner を引き継ぐには、前回の `make outputs` で確認した `RunnerStateVolumeIdUsed` を `parameters.json` の `RunnerStateVolumeId` に設定してから `make deploy` する。

## ドキュメントの分担

- この README は **Runner 構築者向け**。CloudFormation スタックの前提、デプロイ、パラメータ、運用保守だけを扱う。
- GitLab 14.2 での AWS 認証方針、Runner の使い分け、`.gitlab-ci.yml` の運用例、OIDC の制約は [docs/gitlab-14-2-aws-auth.md](docs/gitlab-14-2-aws-auth.md) を参照。

## IAM スタックのパラメータ一覧

`gitlab-runner-iam.yaml` のパラメータ。変更後は `make deploy-iam` または `make changeset-iam` で適用する。

| 名前 | 必須 | デフォルト | 説明 |
|---|---|---|---|
| `CacheBucketName` | - | `""` | Runner 分散キャッシュ用 S3 バケット名。空なら S3 権限なし |
| `EcrRepositoryArns` | - | `""` | 既存 private ECR repository への push / pull を許可する repository ARN または ARN パターン（カンマ区切り）。空なら ECR 権限なし |

## メインスタックのパラメータ一覧

`gitlab-runner.yaml` のパラメータ。

| 名前 | 必須 | デフォルト | 説明 |
|---|---|---|---|
| `VpcId` | ✓ | - | 既存 VPC ID |
| `SubnetId` | ✓ | - | 既存 Subnet ID（private subnet または public subnet） |
| `AssignPublicIp` | - | `No` | `Yes` / `No` / `SubnetDefault`（下記参照） |
| `ExistingSecurityGroupIds` | - | `""` | 既存 SG ID（カンマ区切り）。指定時は新規 SG を作成しない |
| `GitLabUrl` | ✓ | `https://gitlab.example.com/` | セルフホスト GitLab の URL（末尾 `/` 必要） |
| `RegistrationToken` | ✓ | - | Runner トークン（`NoEcho`）。GitLab 14.2 では Registration Token、新しい GitLab では Runner Authentication Token (`glrt-...`) |
| `RunnerDescription` | - | `cfn-gitlab-runner` | legacy registration token 利用時の Runner 説明。authentication token 利用時は GitLab UI/API 側で管理 |
| `RunnerTags` | - | `aws,docker` | legacy registration token 利用時の Runner タグ（カンマ区切り）。authentication token 利用時は GitLab UI/API 側で管理 |
| `RunnerConcurrent` | - | `2` | 同時実行ジョブ数 |
| `RunnerDefaultDockerImage` | - | `alpine:latest` | デフォルト Docker イメージ |
| `EcrDockerRegistries` | - | `""` | Docker credential helper を有効化する ECR registry host（カンマ区切り）。IAM 権限範囲や repository 作成は制御しない |
| `RunnerPrivileged` | - | `false` | privileged モード（DinD 用途なら `true`） |
| `RunnerLocked` | - | `true` | legacy registration token 利用時のみ有効。authentication token 利用時は GitLab UI/API 側で管理 |
| `RunnerRunUntagged` | - | `false` | legacy registration token 利用時のみ有効。authentication token 利用時は GitLab UI/API 側で管理 |
| `InstanceType` | - | `t3.small` | `t3.nano` / `t3.micro` / `t3.small` / `t3.medium` / `t3.large` / `m6i.large` |
| `SpotMaxPrice` | - | `""` | Spot 最大価格 USD/時。空ならオンデマンド価格上限 |
| `VolumeSizeGiB` | - | `50` | ルート EBS サイズ |
| `RunnerStateVolumeId` | - | `""` | `/etc/gitlab-runner` を保持する既存 EBS volume ID。空なら retained な state volume を新規作成 |
| `RunnerStateVolumeSizeGiB` | - | `20` | `RunnerStateVolumeId` が空のときに作成する state volume のサイズ |
| `RunnerStateVolumeAvailabilityZone` | - | `""` | 新規 state volume の AZ。通常は `make deploy` / `make changeset` が `SubnetId` から自動補完する |
| `AmiId` | - | AL2023 の SSM Public Parameter | 上書き可 |
| `IamStackName` | - | `gitlab-runner-iam` | `RunnerInstanceProfileArn` と `CacheBucketName` を export している IAM スタック名 |
| `KeyPairName` | - | `""` | SSH 用 KeyPair（任意） |
| `AllowedSshCidr` | - | `""` | SSH 許可 CIDR（任意、新規 SG 作成時のみ有効） |
| `CloudWatchLogsRetentionDays` | - | `30` | CloudWatch Logs の保持日数 |
| `CacheBucketName` | - | `""` | Runner 分散キャッシュを有効化する S3 バケット名 |
| `CacheBucketLocation` | - | スタックと同じリージョン | `CacheBucketName` のリージョン。別リージョンの S3 バケットを使う場合に指定 |

## `AssignPublicIp` の挙動

| 値 | 動作 | 想定シナリオ |
|---|---|---|
| `No`（デフォルト） | ENI に public IP を付与しない | NAT GW 経由で outbound する private subnet。public IPv4 課金も回避 |
| `Yes` | public IP を強制付与 | IGW 付きの public subnet にデプロイする場合 |
| `SubnetDefault` | サブネットの `MapPublicIpOnLaunch` に従う | サブネット側で自動割り当てが有効な場合のみ有効。無効（No）の場合はパブリック IP が付かない点に注意 |

**注意**: public subnet（IGW ルートあり）に置く場合は `AssignPublicIp=Yes` を必ず指定すること。サブネットの「IPv4 自動割り当て（`MapPublicIpOnLaunch`）」が無効でも `Yes` を指定すれば EC2 起動時にパブリック IP が付与される。`No` または `SubnetDefault`（サブネット設定が無効な場合）のままにすると outbound できずスタック作成が失敗する。

## Runner token の扱い

- このテンプレートは `RegistrationToken` パラメータ名を互換のため維持しているが、値としては 2 種類を受け付ける
  - GitLab 14.2 向けの legacy **Registration Token**
  - 将来の GitLab 向け **Runner Authentication Token** (`glrt-...`)
- `RegistrationToken` が `glrt-` で始まる場合、CloudFormation は `gitlab-runner register --token ...` を使う
- `glrt-` 以外の場合は、従来どおり `gitlab-runner register --registration-token ...` を使う
- authentication token 利用時、GitLab の仕様上、以下の属性は `register` コマンド引数では設定しない
  - `RunnerDescription`
  - `RunnerTags`
  - `RunnerLocked`
  - `RunnerRunUntagged`
- これらは runner を GitLab UI または API で事前作成するときに設定する

### GitLab 14.2 のまま使う場合

- これまでどおり project / group / instance の Registration Token を `RegistrationToken` に設定する
- `RunnerDescription` / `RunnerTags` / `RunnerLocked` / `RunnerRunUntagged` は CloudFormation 側で適用される
- **重要**: legacy registration token のまま state volume を使わずに再デプロイすると、GitLab 上では別 runner として再登録される
- 同じ runner を継続したい場合は、`RunnerStateVolumeId` で前回の state volume を再利用する

### 将来 Authentication Token へ移行する場合

1. GitLab UI または API で runner を事前作成する
2. GitLab 側で description / tags / locked / run untagged を設定する
3. 発行された `glrt-...` トークンを `RegistrationToken` に設定する
4. スタックを更新する

この移行では CloudFormation テンプレート自体の差し替えは不要で、トークン種別の切り替えで新フローに移行できる。

## Persistent runner state (`RunnerStateVolumeId`)

- このテンプレートは `gitlab-runner` の `config.toml` を永続 EBS に置く
- `RunnerStateVolumeId=""` の場合、スタックが state volume を新規作成し、スタック削除時も **retain** する
- `make deploy` / `make changeset` は `RunnerStateVolumeId=""` の場合、`SubnetId` から state volume 用 AZ を自動補完する
- `RunnerStateVolumeId=vol-...` を指定した場合、その既存 volume をアタッチして既存 runner 設定を再利用する
- 既存 `config.toml` に `[[runners]]` があれば、UserData は `gitlab-runner register` を再実行しない
- root volume は従来どおり削除される。永続化されるのは runner 状態のみ

### 推奨フロー

1. 初回デプロイでは `RunnerStateVolumeId` を空にする
2. `make outputs` で `RunnerStateVolumeIdUsed` を控える
3. Spot 中断や `make delete` 後に再作成するときは、その volume ID を `RunnerStateVolumeId` に設定して再デプロイする

### 注意点

- retained volume は CloudFormation が自動再利用しない。再利用したい場合は **明示的に** `RunnerStateVolumeId` を設定する
- `make` を使わずに CloudFormation を直接叩く場合は、新規 state volume 用に `RunnerStateVolumeAvailabilityZone` も明示する
- EBS volume は EC2 と同じ Availability Zone にしかアタッチできない。別 AZ の subnet に切り替える場合は同じ volume を再利用できない
- `RunnerConcurrent` は起動時に既存 `config.toml` のトップレベル設定を更新するが、runner 自体の登録情報は保持される

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

## S3 分散キャッシュを使う

IAM スタックの `CacheBucketName` を指定すると、Runner 登録時に S3 distributed cache を有効化できる。認証は EC2 インスタンスロールを使う。

`parameters-iam.json`:

```json
{ "ParameterKey": "CacheBucketName", "ParameterValue": "my-runner-cache" }
```

`parameters.json`:

```json
{ "ParameterKey": "IamStackName",        "ParameterValue": "gitlab-runner-iam" },
{ "ParameterKey": "CacheBucketLocation", "ParameterValue": "ap-northeast-1" }
```

- メインスタックの `CacheBucketName` が空なら、IAM スタックが export した `CacheBucketName` を自動利用する
- IAM スタックの `CacheBucketName` は S3 権限付与にも使用する
- `CacheBucketLocation` を省略した場合はスタックのリージョンを使う
- cache の prefix は `gitlab-runner` 固定
- バケット側には Runner ロールに対する `s3:GetObject` / `s3:PutObject` / `s3:DeleteObject` / `s3:ListBucket` が必要

メインスタックは `RunnerInstanceProfileArn` も IAM スタックの export から取得するため、通常は `parameters.json` に ARN を手入力する必要はない。IAM スタックとメインスタックは同一アカウント・同一リージョンに配置すること。

必要なら `parameters.json` に `CacheBucketName` を明示して IAM 側 export を上書きすることもできるが、通常運用では不要。

## CloudWatch Logs

Runner の以下ログが自動的に CloudWatch Logs に送信される:

- `/var/log/user-data.log` → `{InstanceId}/user-data`
- `gitlab-runner.service` (journald) → `{InstanceId}/gitlab-runner`

ログは `/${StackName}/runner` ロググループに収集される。保持日数は `CloudWatchLogsRetentionDays` で制御（デフォルト 30 日）。

```bash
# ログの確認（AWS Console の CloudWatch Logs を使うか CLI で）
aws logs tail /gitlab-runner/runner --follow --region ap-northeast-1
```

## セキュリティ上の注意

- **Registration token は UserData に埋め込まれる**。`ec2:DescribeInstanceAttribute` 権限を持つ者は取得可能。
- **Registration token 方式は GitLab 16.6 以降で非推奨**。長期運用では、GitLab UI で事前に取得する **Runner Authentication Token** + SSM Parameter Store への移行を推奨。
- **Spot 中断時にジョブは中断される**。本テンプレートは単一 EC2 のため自動復旧しない。
- **runner state volume には `/etc/gitlab-runner/config.toml` が残る**。再利用時は runner token を含む設定を引き継ぐため、不要になった volume は適切に破棄すること。
- EBS は暗号化（gp3）。IMDS は v2 強制。
- `EcrRepositoryArns` は既存 private ECR repository への権限付与に使う。repository 自体は通常 push 前に AWS 側で事前作成しておくこと。
- `EcrRepositoryArns` を広く取りすぎると Runner が操作できる ECR 範囲も広がる。必要最小限の repository ARN に絞ること。同一アカウント内の全 repository を許可したい場合のみ `arn:aws:ecr:<region>:<account-id>:repository/*` のような ARN パターンを使う。

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
- **outbound できない**: private subnet なら NAT GW ルートがあるか、public subnet なら `AssignPublicIp=Yes` と IGW ルートがあるか、SG egress が `0.0.0.0/0` allow か確認。
- **GitLab 側に Runner が現れない**: `GitLabUrl` 末尾 `/`、トークン、ネットワーク到達性（SG / ルーティング）を確認。
- **再デプロイ後に別 runner が増えた**: 前回の `RunnerStateVolumeIdUsed` を `RunnerStateVolumeId` に渡さずに新規 state volume で起動している可能性が高い。
- **state volume を再利用できない**: `RunnerStateVolumeId` の volume が runner を置く subnet と別 Availability Zone の可能性がある。
- **docker ジョブが権限エラー**: DinD を使うなら `RunnerPrivileged=true`。

## ファイル

- `gitlab-runner-iam.yaml` — IAM ロール / インスタンスプロファイル用 CloudFormation テンプレート（`CAPABILITY_IAM` が必要）
- `gitlab-runner.yaml` — メイン CloudFormation テンプレート（IAM 権限不要）
- `parameters-iam.sample.json` — IAM スタック用パラメータのサンプル
- `parameters.sample.json` — メインスタック用パラメータのサンプル（コピーして `parameters.json` に）
- `Makefile` — `validate` / `deploy` / `changeset` / `outputs` / `session` / `delete` および各 `-iam` バリアント
- `scripts/cfn-deploy.sh` — JSON パラメータを安全に扱う create/update/change-set ラッパー
- `docs/gitlab-14-2-aws-auth.md` — GitLab 14.2 での AWS 認証方針、Runner の使い分け、`.gitlab-ci.yml` 運用例
