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
                 │   │   - IAM: SSM + opt S3/ECR │      │
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
- private ECR を `.gitlab-ci.yml` の `image:` で使う場合、Runner EC2 ロールに pull 権限を付与し、`amazon-ecr-credential-helper` を自動設定できる。

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
| `EcrPullRepositoryArns` | - | `""` | pull を許可する ECR repository ARN（カンマ区切り）。空なら ECR pull 権限なし |
| `EcrDockerRegistries` | - | `""` | Docker credential helper を有効化する ECR registry host（カンマ区切り） |
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

## private ECR をジョブ `image:` に使う

同一アカウント・クロスアカウントを問わず、Runner が private ECR からビルド用イメージを pull するには以下を設定する。

```json
{ "ParameterKey": "EcrPullRepositoryArns", "ParameterValue": "arn:aws:ecr:ap-northeast-1:111111111111:repository/base-ci,arn:aws:ecr:ap-northeast-1:222222222222:repository/shared-ci" },
{ "ParameterKey": "EcrDockerRegistries",   "ParameterValue": "111111111111.dkr.ecr.ap-northeast-1.amazonaws.com,222222222222.dkr.ecr.ap-northeast-1.amazonaws.com" }
```

- `EcrPullRepositoryArns` は Runner EC2 ロールに `ecr:GetAuthorizationToken` と対象 repository の pull 権限を付与する
- `EcrDockerRegistries` を指定すると、`gitlab-runner` ユーザーに `amazon-ecr-credential-helper` を設定する
- `image:` で指定するイメージは、上記 registry / repository に一致している必要がある

`.gitlab-ci.yml` の例:

```yaml
build:
  image: 111111111111.dkr.ecr.ap-northeast-1.amazonaws.com/base-ci:latest
  script:
    - aws --version
    - node --version
```

### クロスアカウント ECR pull

別 AWS アカウントの ECR を pull する場合、このテンプレートの IAM 追加だけでは不十分で、相手先 repository policy に Runner ロール ARN の許可が必要。

許可すべき代表アクション:

- `ecr:BatchCheckLayerAvailability`
- `ecr:BatchGetImage`
- `ecr:GetDownloadUrlForLayer`

`ecr:GetAuthorizationToken` は Runner 側 IAM ロールに対して `Resource: "*"` で許可される。

## ECR push は GitLab OIDC を使う

このテンプレートは ECR push 権限を Runner EC2 ロールに付与しない。push は各ジョブが GitLab OIDC で AWS IAM Role を AssumeRole して行う前提。

前提:

- AWS 側で GitLab OIDC provider を作成済み
- push 用 IAM Role の trust policy で対象 GitLab project / branch / tag 条件を制限済み
- push 用 IAM Role に `ecr:InitiateLayerUpload` などの push 権限を付与済み

`.gitlab-ci.yml` の最小例:

```yaml
push-image:
  image: docker:27-cli
  services:
    - docker:27-dind
  id_tokens:
    GITLAB_OIDC_TOKEN:
      aud: sts.amazonaws.com
  variables:
    AWS_REGION: ap-northeast-1
    AWS_ROLE_ARN: arn:aws:iam::111111111111:role/gitlab-ecr-push
    ECR_REGISTRY: 111111111111.dkr.ecr.ap-northeast-1.amazonaws.com
    ECR_REPOSITORY: app
    IMAGE_TAG: $CI_COMMIT_SHA
    DOCKER_HOST: tcp://docker:2375
    DOCKER_TLS_CERTDIR: ""
  script:
    - apk add --no-cache aws-cli jq
    - printf '%s' "$GITLAB_OIDC_TOKEN" > /tmp/gitlab-oidc-token
    - aws sts assume-role-with-web-identity --role-arn "$AWS_ROLE_ARN" --role-session-name "gitlab-${CI_PIPELINE_ID}" --web-identity-token file:///tmp/gitlab-oidc-token --duration-seconds 3600 > /tmp/creds.json
    - export AWS_ACCESS_KEY_ID="$(jq -r '.Credentials.AccessKeyId' /tmp/creds.json)"
    - export AWS_SECRET_ACCESS_KEY="$(jq -r '.Credentials.SecretAccessKey' /tmp/creds.json)"
    - export AWS_SESSION_TOKEN="$(jq -r '.Credentials.SessionToken' /tmp/creds.json)"
    - aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REGISTRY"
    - docker build -t "$ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG" .
    - docker push "$ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG"
```

この例で `docker build` / `docker push` を行う場合は `RunnerPrivileged=true` を有効にして DinD を使う。

## セキュリティ上の注意

- **Registration token は UserData に埋め込まれる**。`ec2:DescribeInstanceAttribute` 権限を持つ者は取得可能。
- **Registration token 方式は GitLab 16.6 以降で非推奨**。長期運用では、GitLab UI で事前に取得する **Runner Authentication Token** + SSM Parameter Store への移行を推奨。
- **Spot 中断時にジョブは中断される**。本テンプレートは単一 EC2 のため自動復旧しない。
- EBS は暗号化（gp3）。IMDS は v2 強制。
- `EcrPullRepositoryArns` を広く取りすぎると Runner が pull できる ECR 範囲も広がる。必要最小限の repository ARN に絞ること。

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
- **private ECR イメージを pull できない**: `EcrPullRepositoryArns` に対象 repo ARN が入っているか、`EcrDockerRegistries` に registry host が入っているか、クロスアカウントなら相手先 ECR repository policy が Runner ロールを許可しているかを確認。

## ファイル

- `gitlab-runner.yaml` — CloudFormation テンプレート
- `parameters.sample.json` — パラメータのサンプル（コピーして `parameters.json` に）
- `Makefile` — `validate` / `deploy` / `changeset` / `outputs` / `session` / `delete`
