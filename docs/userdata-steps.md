# UserData の実行内容

`gitlab-runner.yaml` の UserData スクリプトが EC2 起動時に実行する処理の一覧。

スクリプト全体のログは `/var/log/user-data.log` に記録される。  
最後に `cfn-signal` で CloudFormation へ成否を通知し、CreationPolicy タイムアウト（15 分）を制御する。

---

## 1. ロギング・エラーハンドリングの設定

- 全出力を `/var/log/user-data.log` に転送（`tee -a`）
- `ERR` トラップで最後に失敗したコマンドを記録
- `EXIT` トラップで `cfn-signal` を実行（成功 / 失敗どちらでも通知）

## 2. パッケージのインストール

```
dnf update
dnf install docker aws-cfn-bootstrap jq amazon-ecr-credential-helper amazon-cloudwatch-agent
```

- Docker を有効化・起動（`systemctl enable --now docker`）

## 3. GitLab Runner のインストール

- GitLab 公式 RPM リポジトリ（`packages.gitlab.com`）を登録
- `dnf install gitlab-runner`
- `gitlab-runner` ユーザーを `docker` グループに追加

## 4. 永続 state ボリュームの待機とマウント

| 手順 | 内容 |
|---|---|
| ボリューム待機 | ルートデバイス以外のディスクが検出されるまで最大 5 分待機（5 秒 × 60 回）。タイムアウトで失敗終了 |
| フォーマット | 未フォーマットの場合のみ `mkfs.ext4 -L runner-state` |
| `/etc/fstab` 登録 | UUID ベースで `/mnt/runner-state` を登録（`nofail`） |
| マウント | `/mnt/runner-state` にマウント |

## 5. `/etc/gitlab-runner` のバインドマウント

- `/mnt/runner-state/etc-gitlab-runner` を作成
- `/etc/gitlab-runner` にバインドマウント（`mount --bind`）
- `/etc/fstab` に登録

Runner の設定や登録情報が state volume に永続化され、インスタンス再起動後も引き継がれる。

## 6. `config.toml` の設定

| ケース | 処理 |
|---|---|
| `config.toml` が存在しない | `concurrent`（`RunnerConcurrent`）と `check_interval = 0` を含む最小構成を新規作成 |
| `config.toml` が存在する（再利用時） | `concurrent`（`RunnerConcurrent`）/ `check_interval` の値だけ上書き。登録済みの `[[runners]]` セクションはそのまま維持 |

**再利用時の注意**: state volume 再利用でも `RunnerConcurrent`（→ `concurrent`）と `check_interval` は毎回パラメータ値で上書きされる。一方、以下は初回登録時に config.toml の `[[runners]]` セクションに書き込まれたまま更新されない（ステップ 7・9 参照）:

- `RunnerDefaultDockerImage` → `runners.docker.image`
- `RunnerPrivileged` → `runners.docker.privileged`
- S3 キャッシュ設定（`CacheBucketName` 非空時）→ `runners.cache`
- `RunnerDescription` / `RunnerTags` / `RunnerLocked` / `RunnerRunUntagged`（レガシートークンのみ）

## 7. 登録テンプレートの作成

`/etc/gitlab-runner/register-template.toml` を書き込む。このテンプレートは `gitlab-runner register --template-config` で使われ、内容が config.toml の `[[runners]]` セクションにマージされる。

常に含まれる設定:

- Docker executor のデフォルトイメージ（`RunnerDefaultDockerImage` → `runners.docker.image`）
- privileged モード（`RunnerPrivileged` → `runners.docker.privileged`）
- volumes: `/cache`, `/certs/client`（DinD の TLS 証明書共有用）

**条件付き**: `CacheBucketName`（または IAM スタック export）が非空の場合、S3 分散キャッシュ設定を追記（→ `runners.cache`）:

```toml
[runners.cache]
  Type = "s3"
  Path = "gitlab-runner"
  Shared = true
  [runners.cache.s3]
    BucketName  = "<バケット名>"
    BucketLocation = "<リージョン>"
    AuthenticationType = "iam"
```

## 8. ECR Docker credential helper の設定（条件付き）

`EcrDockerRegistries` が非空のとき実行。

- `/home/gitlab-runner/.docker/config.json` を作成
- 指定した各 ECR レジストリホストに対して `credHelpers` エントリを追加（`"ecr-login"`）

## 9. Runner の登録

`config.toml` に `[[runners]]` セクションが存在しない場合のみ登録（state volume 再利用時は省略）。

| トークン種別 | 登録コマンド | config.toml への反映 |
|---|---|---|
| 認証トークン（`glrt-` プレフィックス） | `gitlab-runner register --token` | `[[runners]]` セクションを生成。テンプレート（ステップ 7）から `RunnerDefaultDockerImage` / `RunnerPrivileged` / S3 キャッシュ設定がマージされる。description / tags / locked / run-untagged は GitLab UI または API で管理するため config.toml には書かれない |
| レガシー登録トークン | `gitlab-runner register --registration-token` | `[[runners]]` セクションを生成。テンプレートから上記と同じ設定がマージされるほか、`RunnerDescription` / `RunnerTags` / `RunnerLocked` / `RunnerRunUntagged` も書き込まれる。いずれも**初回登録時のみ**反映され、state volume 再利用時は更新されない（ステップ 6 参照） |

登録後、`gitlab-runner` サービスを有効化・起動（`systemctl enable --now gitlab-runner`）。

## 10. ログフォワーダーサービスの作成

`/etc/systemd/system/gitlab-runner-log-forwarder.service` を作成・起動。

- `journalctl -u gitlab-runner.service -f` の出力を `/var/log/gitlab-runner.log` に追記
- `BindsTo=gitlab-runner.service` で gitlab-runner と連動して停止

CloudWatch Agent がファイルを読んで転送するための中継ログファイルを生成する。

## 11. CloudWatch Agent の設定・起動

`/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json` を書き込み、エージェントを起動。

| ログファイル | CloudWatch ロググループ | ストリーム名 |
|---|---|---|
| `/var/log/user-data.log` | `/<スタック名>/runner` | `<instance-id>/user-data` |
| `/var/log/gitlab-runner.log` | `/<スタック名>/runner` | `<instance-id>/gitlab-runner` |

## 12. CloudFormation への成否通知

EXIT トラップが `cfn-signal` を呼び出し、RunnerInstance の CreationPolicy に通知。  
失敗した場合は失敗コマンド（`line N: <command>`）を reason として記録。
