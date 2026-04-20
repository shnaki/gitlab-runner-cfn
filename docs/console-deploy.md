# マネジメントコンソールからの手動デプロイ

## Quick-Create Link で楽をする

`parameters.json` / `parameters-iam.json` を編集済みであれば、`make quick-create-link` で各パラメータが事前入力された CloudFormation コンソール URL を生成できる。
URL をブラウザで開くと「スタックの作成（レビュー）」画面が開き、テンプレートのアップロードやパラメータ入力の大半を省略できる。

```bash
# テンプレートを事前に S3 にアップロードしておく
aws s3 cp gitlab-runner-iam.yaml s3://YOUR_BUCKET/
aws s3 cp gitlab-runner.yaml s3://YOUR_BUCKET/

make quick-create-link TEMPLATE_S3_BUCKET=YOUR_BUCKET
```

- `RegistrationToken` は NoEcho のため URL から除外される。コンソール上で手入力すること。
- IAM スタックの確認画面では「IAM リソース作成の承認」チェックボックスへのチェックが必要（CAPABILITY_NAMED_IAM）。

---

## 前提

- AWS マネジメントコンソールへログイン済みであること
- デプロイ先アカウントで CloudFormation・EC2・IAM・EBS の操作権限があること
- リポジトリをローカルにクローン済みで、テンプレートファイルを手元に用意できること

## `make deploy` との主な違い

コンソール手動デプロイでは、`make deploy`（`scripts/cfn-deploy.sh`）が自動で行う処理を手動で補う必要がある。

| 項目 | `make deploy` | コンソール手動 |
|---|---|---|
| `RunnerStateVolumeAvailabilityZone` | `SubnetId` から自動補完 | **手動で AZ 文字列を入力** |
| `CAPABILITY_IAM` | Makefile が自動付与 | チェックボックスで手動選択が必須 |
| 完了待機 | `wait` コマンドで自動待機 | コンソールでリロードしてステータスを確認 |

## デプロイの流れ

IAM スタックを先にデプロイし、その後メインスタックをデプロイする。

```
[ステップ 1]  gitlab-runner-iam.yaml  →  IAM ロール・インスタンスプロファイル
                        ↓
[ステップ 2]  gitlab-runner.yaml       →  EC2・EBS・セキュリティグループ等
```

---

## ステップ 1: IAM スタックのデプロイ

### テンプレートのアップロード

1. AWS マネジメントコンソールで **CloudFormation** を開く
2. **スタックの作成** → **新しいリソースを使用（標準）** を選択
3. **テンプレートの指定** で「テンプレートファイルのアップロード」を選択し、`gitlab-runner-iam.yaml` をアップロード
4. **次へ** をクリック

### パラメータの入力

| パラメータ名 | 必須 | 入力例 | 説明 |
|---|---|---|---|
| `RunnerStackName` | × | `gitlab-runner` | メインスタック名。デフォルト値のままで通常は問題ない |
| `CacheBucketName` | × | `my-runner-cache` | S3 キャッシュバケット名。使用しない場合は空欄 |
| `EcrRepositoryArns` | × | `arn:aws:ecr:ap-northeast-1:123456789012:repository/my-repo` | ECR リポジトリ ARN（カンマ区切り）。使用しない場合は空欄 |
| `GitLabOidcProviderArn` | × | `arn:aws:iam::123456789012:oidc-provider/gitlab.com` | GitLab OIDC プロバイダー ARN。OIDC を使用しない場合は空欄 |
| `GitLabOidcIssuerHost` | × | `gitlab.com` | OIDC 発行者ホスト名（https:// なし）。セルフホストの場合はそのホスト名 |
| `GitLabOidcAudience` | × | `https://gitlab.com` | OIDC の `aud` クレーム。セルフホストの場合はインスタンス URL |
| `GitLabOidcSubjectClaim` | × | `project_path:mygroup/myproject:*` | OIDC の `sub` クレームパターン。OIDC を使用しない場合は空欄 |

OIDC を使用しない場合、`GitLabOidcProviderArn`・`GitLabOidcSubjectClaim` を空欄にすれば OIDC トラストは無効になる。

### CAPABILITY_IAM の確認

**重要**: IAM ロールとインスタンスプロファイルを作成するため、確認画面で以下のチェックが必要。

1. 「スタックの作成」前の確認画面を下にスクロール
2. **「AWS CloudFormation によって IAM リソースが作成される場合があることを承認します」** のチェックボックスにチェックを入れる
3. チェックせずに作成しようとするとエラーになる

### 完了確認

1. スタック一覧で作成した IAM スタックを選択
2. **ステータス** が `CREATE_COMPLETE` になるまで待つ（数分）
3. **出力** タブで `RunnerInstanceProfileArn` が出力されていることを確認

---

## ステップ 2: メインスタックのデプロイ

### テンプレートのアップロード

1. CloudFormation で **スタックの作成** → **新しいリソースを使用（標準）** を選択
2. `gitlab-runner.yaml` をアップロードして **次へ**

### パラメータの入力

#### ネットワーク

| パラメータ名 | 必須 | 入力例 | 説明 |
|---|---|---|---|
| `VpcId` | ✓ | `vpc-0a1b2c3d4e5f67890` | デプロイ対象の既存 VPC ID |
| `SubnetId` | ✓ | `subnet-0a1b2c3d4e5f67890` | 既存サブネット ID |
| `AssignPublicIp` | × | `No` | パブリック IP の割り当て。`Yes` / `No` / `SubnetDefault` |
| `ExistingSecurityGroupIds` | × | `sg-0a1b2c3d4e5f67890` | 既存セキュリティグループ ID（カンマ区切り）。空欄で自動作成 |
| `AllowedSshCidr` | × | `203.0.113.0/32` | SSH 許可 CIDR。`ExistingSecurityGroupIds` が空欄の場合のみ有効 |

#### GitLab Runner

| パラメータ名 | 必須 | 入力例 | 説明 |
|---|---|---|---|
| `GitLabUrl` | ✓ | `https://gitlab.example.com/` | GitLab インスタンス URL（末尾スラッシュ必須） |
| `RegistrationToken` | ✓ | `glrt-xxxxxxxxxxxxxxxxxxxx` | Runner 登録トークン |
| `RunnerDescription` | × | `cfn-gitlab-runner` | Runners ページに表示される説明文 |
| `RunnerTags` | × | `aws,docker` | Runner タグ（カンマ区切り） |
| `RunnerConcurrent` | × | `2` | 最大並行ジョブ数 |
| `RunnerDefaultDockerImage` | × | `alpine:latest` | デフォルト Docker イメージ |
| `EcrDockerRegistries` | × | `123456789012.dkr.ecr.ap-northeast-1.amazonaws.com` | ECR レジストリホスト（カンマ区切り）。空欄でスキップ |
| `RunnerPrivileged` | × | `false` | 特権モード。DinD を使う場合は `true` |
| `RunnerLocked` | × | `true` | Runner をプロジェクトにロック |
| `RunnerRunUntagged` | × | `false` | タグなしジョブの実行許可 |

#### コンピュート・ストレージ

| パラメータ名 | 必須 | 入力例 | 説明 |
|---|---|---|---|
| `InstanceType` | × | `t3.small` | EC2 インスタンスタイプ |
| `VolumeSizeGiB` | × | `30` | ルート EBS ボリュームサイズ（GiB） |
| `KeyPairName` | × | `my-keypair` | SSH 接続用 EC2 キーペア名。空欄で SSM のみ |
| `RunnerStateVolumeId` | × | `vol-0a1b2c3d4e5f67890` | 既存 EBS ボリューム ID（`/etc/gitlab-runner` 永続化用）。空欄で新規作成 |
| `RunnerStateVolumeSizeGiB` | × | `8` | 新規作成時の Runner 状態ボリュームサイズ（GiB）。`RunnerStateVolumeId` 指定時は無視 |
| `RunnerStateVolumeAvailabilityZone` | ※ | `ap-northeast-1a` | **下記「AZ の手動入力」を参照** |

#### IAM・キャッシュ・監視

| パラメータ名 | 必須 | 入力例 | 説明 |
|---|---|---|---|
| `IamStackName` | × | `gitlab-runner-iam` | IAM スタック名。ステップ 1 で作成したスタック名と一致させる |
| `CacheBucketName` | × | `my-runner-cache` | S3 キャッシュバケット名。空欄でキャッシュなし |
| `CacheBucketLocation` | × | `ap-northeast-1` | S3 バケットのリージョン。空欄でスタックと同じリージョン |
| `CachePathPrefix` | × | `gitlab-runner` | S3 キャッシュの prefix。空欄でデフォルト値 `gitlab-runner` |
| `CloudWatchLogsRetentionDays` | × | `30` | CloudWatch Logs の保持期間（日） |

#### スケジューリング

| パラメータ名 | 必須 | 入力例 | 説明 |
|---|---|---|---|
| `ScheduleEnabled` | × | `false` | `true` にすると平日営業時間スケジュールを有効化 |
| `ScheduleTimezone` | × | `Asia/Tokyo` | スケジュールのタイムゾーン（IANA 形式） |
| `BusinessHoursStartHour` | × | `9` | 起動時刻の「時」（0〜23） |
| `BusinessHoursStartMinute` | × | `0` | 起動時刻の「分」（0〜59） |
| `BusinessHoursStopHour` | × | `18` | 停止時刻の「時」（0〜23） |
| `BusinessHoursStopMinute` | × | `0` | 停止時刻の「分」（0〜59） |

### RunnerStateVolumeAvailabilityZone の手動入力

**`make deploy` ではこのパラメータを `SubnetId` から自動で解決するが、コンソールでは手動入力が必要。**

`RunnerStateVolumeId` が空欄（新規ボリュームを作成する）場合、`RunnerStateVolumeAvailabilityZone` に対象サブネットと同じ AZ を入力する。

AZ の確認方法:
1. AWS コンソールで **VPC** → **サブネット** を開く
2. `SubnetId` で指定したサブネットを選択
3. 詳細タブの **アベイラビリティーゾーン** に表示された値（例: `ap-northeast-1a`）をコピー
4. `RunnerStateVolumeAvailabilityZone` に貼り付け

`RunnerStateVolumeId` を指定する（既存ボリュームを再利用する）場合は空欄のままでよい。

### 完了確認

1. **CAPABILITY_IAM のチェックは不要**（メインスタックには IAM リソースが含まれない）
2. スタック一覧でメインスタックのステータスが `CREATE_COMPLETE` になるまで待つ（5〜10 分程度）
3. **出力** タブで `InstanceId`・`RunnerStateVolumeIdUsed` などが出力されていることを確認

---

## スタックの更新

1. CloudFormation のスタック一覧から更新するスタックを選択
2. **スタックアクション** → **スタックの更新** を選択
3. テンプレートを差し替える場合は「既存のテンプレートを置き換える」を選択してアップロード、変更しない場合は「現在のテンプレートの使用」を選択
4. パラメータを変更して **次へ** → **送信**
5. ステータスが `UPDATE_COMPLETE` になるまで待つ

---

## スタックの削除

**削除順序はデプロイと逆順**。メインスタックを先に削除してから IAM スタックを削除する。

1. メインスタックを選択 → **削除**
2. `DELETE_COMPLETE` になったことを確認
3. IAM スタックを選択 → **削除**

`RunnerStateVolumeIdUsed` 出力に表示されている EBS ボリュームは、スタック削除後も保持される（`DeletionPolicy: Retain`）。
次回デプロイで引き継ぐ場合は `RunnerStateVolumeId` に指定する。不要な場合は EC2 コンソールから手動で削除する。
