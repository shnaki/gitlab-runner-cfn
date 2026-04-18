# cfn-deploy.sh — CloudFormation デプロイラッパー

## 概要

`scripts/cfn-deploy.sh` は、CloudFormation スタックの作成・更新・change-set 作成を統一的に扱うラッパースクリプト。
`aws cloudformation` コマンドを直接呼び出す際の定型処理（スタック存在確認、`--capabilities` 付与、完了待機、エラー判定）をまとめている。

## 前提コマンド

以下のコマンドが `PATH` に存在する必要がある。

| コマンド | 用途 |
|---|---|
| `aws` | CloudFormation・EC2 の API 呼び出し |
| `jq` | パラメータ JSON の読み取り・加工 |

## 使い方

```bash
scripts/cfn-deploy.sh <deploy|changeset> <stack-name> <region> <template-file> <params-file> [change-set-name]
```

| 引数 | 必須 | 説明 |
|---|---|---|
| `deploy\|changeset` | 必須 | 動作モード |
| `stack-name` | 必須 | CloudFormation スタック名 |
| `region` | 必須 | AWS リージョン |
| `template-file` | 必須 | テンプレートファイルのパス |
| `params-file` | 必須 | パラメータ JSON ファイルのパス |
| `change-set-name` | changeset モード時必須 | change-set 名 |

## モード

### deploy モード

スタックの新規作成または更新を実行し、完了まで待機する。

**スタックが存在しない場合（新規作成）**

1. `--disable-rollback` 付きで `create-stack` を実行
2. `wait stack-create-complete` で完了を待機
3. `describe-stacks` で最終 `StackStatus` を表示

**スタックが存在する場合（更新）**

1. `update-stack` を実行
2. "No updates are to be performed" が返った場合は正常終了（終了コード 0）
3. それ以外のエラーは標準エラーに出力して異常終了
4. 更新成功時は `wait stack-update-complete` で完了を待機し、最終 `StackStatus` を表示

### changeset モード

change-set を作成してステータスと変更内容を表示する（実行はしない）。

1. スタック存在確認で `change-set-type` を決定（新規: `CREATE` / 既存: `UPDATE`）
2. `create-change-set` を実行
3. `wait change-set-create-complete` で完了を待機
4. "didn't contain changes" が含まれる場合は正常終了（終了コード 0、変更なし）
5. 成功時は `describe-change-set` で以下を表示

```json
{
  "Status": "...",
  "ExecutionStatus": "...",
  "Changes": [
    {
      "Action": "Add|Modify|Remove",
      "LogicalResourceId": "...",
      "ResourceType": "...",
      "Replacement": "True|False|Conditional"
    }
  ]
}
```

## AZ 自動補完

テンプレートに `RunnerStateVolumeAvailabilityZone` パラメータが存在し、かつ以下の条件をすべて満たす場合に AZ を自動解決する。

- `RunnerStateVolumeId` が未指定（既存ボリュームの再利用でない）
- `RunnerStateVolumeAvailabilityZone` が未指定

**処理フロー**

1. `SubnetId` パラメータの値を取得（未指定の場合はエラー終了）
2. `aws ec2 describe-subnets` で `SubnetId` が属する AZ を取得
3. 一時ファイル（`mktemp`）を作成し、元の `params-file` に `RunnerStateVolumeAvailabilityZone` を追加した JSON を書き込む
4. 以降の API 呼び出しは一時ファイルを `params-file` として使用

## CFN_CAPABILITIES 環境変数

`CFN_CAPABILITIES` 環境変数を設定すると、`--capabilities` オプションとして渡される。

```bash
CFN_CAPABILITIES=CAPABILITY_NAMED_IAM scripts/cfn-deploy.sh deploy ...
```

IAM リソースを含むテンプレートをデプロイする際に必要。`Makefile` の `deploy` / `changeset` ターゲットがこの変数をセットして呼び出している。

## エラー処理と終了コード

`set -euo pipefail` を有効にし、意図しないエラーで即時終了する。
以下の 2 ケースは CloudFormation API のエラー応答だが、**正常終了（終了コード 0）として扱う**。

| メッセージ | 発生タイミング | 意味 |
|---|---|---|
| `No updates are to be performed` | deploy モード（更新時） | 差分なし、スタックは変更されない |
| `didn't contain changes` | changeset モード | change-set に変更内容がない |

## 一時ファイルの扱い

AZ 自動補完が発動すると `mktemp` で一時ファイルを作成する。
`trap cleanup EXIT` により、スクリプト終了時（正常・エラー問わず）に自動削除される。
