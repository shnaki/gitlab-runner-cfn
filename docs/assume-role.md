# make deploy 前の AssumeRole 手順

## 概要

以下のケースでは、`make deploy` を実行する前に AssumeRole で一時的な認証情報を取得する必要がある。

| ケース | 説明 |
|---|---|
| クロスアカウントデプロイ | デプロイ先 AWS アカウントが、ローカルの認証情報が属するアカウントと異なる |
| MFA 必須ポリシー | IAM ポリシーで MFA 認証済みセッションの提示が必須になっている |

AssumeRole で得た一時認証情報を環境変数にセットしてから `make deploy` を実行すると、AWS CLI がその認証情報を使ってデプロイを行う。

## 前提

- `aws` CLI がインストールされ、`PATH` に存在すること
- `jq` がインストールされていること（`make deploy` が内部で使用する）
- AssumeRole 先の IAM ロール ARN（`arn:aws:iam::<account-id>:role/<role-name>`）を把握していること
- ローカルの AWS 認証情報（プロファイルまたは環境変数）が、そのロールへの `sts:AssumeRole` を許可されていること

## 1. AssumeRole の実行

```bash
aws sts assume-role \
  --role-arn arn:aws:iam::<account-id>:role/<role-name> \
  --role-session-name deploy-session
```

成功すると以下の形式で JSON が返る。

```json
{
  "Credentials": {
    "AccessKeyId": "ASIA...",
    "SecretAccessKey": "...",
    "SessionToken": "...",
    "Expiration": "2099-01-01T00:00:00+00:00"
  },
  "AssumedRoleUser": { ... }
}
```

## 2. 認証情報の環境変数セット

`aws sts assume-role` の出力から各フィールドを環境変数にセットする。

```bash
export AWS_ACCESS_KEY_ID=$(aws sts assume-role \
  --role-arn arn:aws:iam::<account-id>:role/<role-name> \
  --role-session-name deploy-session \
  --query 'Credentials.AccessKeyId' \
  --output text)

export AWS_SECRET_ACCESS_KEY=$(aws sts assume-role \
  --role-arn arn:aws:iam::<account-id>:role/<role-name> \
  --role-session-name deploy-session \
  --query 'Credentials.SecretAccessKey' \
  --output text)

export AWS_SESSION_TOKEN=$(aws sts assume-role \
  --role-arn arn:aws:iam::<account-id>:role/<role-name> \
  --role-session-name deploy-session \
  --query 'Credentials.SessionToken' \
  --output text)
```

`assume-role` を 3 回呼ぶとセッションがずれる場合があるため、以下のように一度 JSON を変数に保存してから展開するほうが確実。

```bash
CREDS=$(aws sts assume-role \
  --role-arn arn:aws:iam::<account-id>:role/<role-name> \
  --role-session-name deploy-session)

export AWS_ACCESS_KEY_ID=$(echo "$CREDS"     | jq -r '.Credentials.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r '.Credentials.SecretAccessKey')
export AWS_SESSION_TOKEN=$(echo "$CREDS"     | jq -r '.Credentials.SessionToken')
```

環境変数がセットされると、`aws` CLI はデフォルトプロファイルよりも環境変数を優先して使用する。

セット後に現在の認証情報を確認するには:

```bash
aws sts get-caller-identity
```

出力の `Arn` が AssumeRole 先のロール ARN になっていれば正常。

## 3. make deploy の実行

環境変数をセットしたシェルから通常どおり `make deploy` を実行する。

```bash
make deploy
```

IAM スタックを先にデプロイする場合も同様。

```bash
make deploy-iam
make deploy
```

## 4. セッションのリセット

デプロイ後に元の認証情報（プロファイル）に戻すには、セットした環境変数を unset する。

```bash
unset AWS_ACCESS_KEY_ID
unset AWS_SECRET_ACCESS_KEY
unset AWS_SESSION_TOKEN
```

unset 後は `aws sts get-caller-identity` でデフォルトプロファイルの IAM エンティティに戻っていることを確認できる。

---

## 補足: MFA が必要な場合

IAM ポリシーで MFA 認証済みセッション（`aws:MultiFactorAuthPresent: true`）が必要な場合は、`--serial-number` と `--token-code` を追加する。

```bash
CREDS=$(aws sts assume-role \
  --role-arn arn:aws:iam::<account-id>:role/<role-name> \
  --role-session-name deploy-session \
  --serial-number arn:aws:iam::<your-account-id>:mfa/<iam-user-name> \
  --token-code <6桁のワンタイムコード>)
```

| オプション | 説明 |
|---|---|
| `--serial-number` | MFA デバイスの ARN（仮想 MFA の場合: `arn:aws:iam::<account-id>:mfa/<user-name>`） |
| `--token-code` | 認証アプリに表示されている 6 桁のコード |

以降の手順（環境変数セット・`make deploy` 実行）は「2. 認証情報の環境変数セット」以降と同じ。
