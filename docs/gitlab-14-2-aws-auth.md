# GitLab 14.2 での AWS 認証と Runner 運用

このドキュメントは **CI/CD 利用者向け** のガイドです。  
このリポジトリで構築した Runner を GitLab 14.2 からどう使うか、AWS 認証をどう分けるか、`.gitlab-ci.yml` をどう書くかを整理します。

## 背景

- **GitLab 14.2 では CI/CD の OIDC は使えない**
- そのため、GitLab ジョブから AWS に対して `AssumeRoleWithWebIdentity` を使う構成は現行運用では採用しない
- AWS 認証は Runner 実行環境に付けた IAM 権限、または固定シークレットで扱う

この前提で、このリポジトリの標準運用は **専用Runner + IAM Role** とする。

## 推奨構成

### 専用Runner + IAM Role

- Runner を AWS 上の専用 EC2 として分ける
- その EC2 に必要最小限の IAM Role を付ける
- ジョブは Runner の IAM 権限をそのまま使って AWS API を呼ぶ

この構成を推奨する理由:

- GitLab に長期 AWS キーを置かずに済む
- GitLab 14.2 でもそのまま使える
- OIDC が使えない前提でも、権限境界を Runner 単位で分けられる

### Runner を分ける粒度

最低でも以下は分ける。

- `nonprod` 用 Runner
- `prod` 用 Runner

できれば用途でも分ける。

- `deploy` 用 Runner
- `infra-apply` 用 Runner
- `readonly` 用 Runner

避けるべき構成:

- 共有 Runner に広い AWS 権限を付ける
- `dev` と `prod` で同じ Runner を使う
- アプリデプロイと Terraform apply を同じ強権限 Runner に載せる

## 代替案

### 固定 AWS キーを CI/CD Variables に入れる

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- 必要なら `AWS_SESSION_TOKEN`

最短で動くが、長期鍵の保管とローテーションが必要になる。  
一時対応としては使えるが、標準運用にはしない。

### Vault

Vault を使えば GitLab 14.2 でも仲介認証の構成は取れるが、このリポジトリの前提には含めない。  
Vault 導入済みの組織なら検討余地はあるが、標準案は **専用Runner + IAM Role**。

## `.gitlab-ci.yml` の基本ルール

- `tags:` で利用する Runner を明示する
- 強い権限の Runner を汎用ジョブに使わない
- `prod` 用ジョブは `prod` Runner にしか載らないようにする
- DinD が必要なジョブだけ `RunnerPrivileged=true` の Runner を使う

### 例: nonprod デプロイ

```yaml
deploy-nonprod:
  tags:
    - nonprod
    - deploy
  script:
    - aws sts get-caller-identity
    - aws s3 ls s3://my-nonprod-bucket
```

### 例: prod デプロイ

```yaml
deploy-prod:
  tags:
    - prod
    - deploy
  script:
    - aws sts get-caller-identity
    - aws ecs update-service --cluster my-prod-cluster --service my-app --force-new-deployment
```

### 例: Terraform apply

```yaml
terraform-apply:
  tags:
    - prod
    - infra
    - apply
  script:
    - terraform init
    - terraform apply -auto-approve
```

## private ECR を使う場合

Runner が private ECR のイメージを pull できるようにするには、構築側で以下を設定しておく。

- IAM スタックの `EcrRepositoryArns`
- メインスタックの `EcrDockerRegistries`

`EcrRepositoryArns` は既存 private ECR repository への IAM 権限付与用。`EcrDockerRegistries` は Docker credential helper の認証先 registry host 設定用で、repository 作成は行わない。

通常、private ECR repository は AWS 側で push 前に事前作成しておく。`docker push` 時の自動作成に依存する運用は、このテンプレートの前提に含めない。

利用側では通常の `image:` として参照できる。

`EcrRepositoryArns` の例:

- 個別 repository のみ許可: `arn:aws:ecr:ap-northeast-1:111111111111:repository/base-ci`
- 同一アカウント内の全 repository を許可: `arn:aws:ecr:ap-northeast-1:111111111111:repository/*`

### 例: ECR のイメージをジョブに使う

```yaml
build:
  tags:
    - nonprod
    - deploy
  image: 111111111111.dkr.ecr.ap-northeast-1.amazonaws.com/base-ci:latest
  script:
    - aws --version
    - node --version
```

### クロスアカウント ECR pull

別 AWS アカウントの ECR を pull する場合は、Runner 側 IAM だけでは足りない。  
相手先 ECR repository policy に Runner ロール ARN の許可が必要。

代表的に必要な権限:

- `ecr:BatchCheckLayerAvailability`
- `ecr:BatchGetImage`
- `ecr:GetDownloadUrlForLayer`

## DinD を使う場合

`docker build` や `docker push` をジョブ内で行うなら、対応する Runner 側で `RunnerPrivileged=true` が必要。  
DinD が不要な Runner まで privileged にしないこと。

```yaml
docker-build:
  tags:
    - nonprod
    - deploy
  image: docker:27-cli
  services:
    - docker:27-dind
  variables:
    DOCKER_HOST: tcp://docker:2375
    DOCKER_TLS_CERTDIR: ""
  script:
    - docker version
    - docker build -t my-app:$CI_COMMIT_SHA .
```

## 運用上の注意

- 権限はジョブ単位ではなく **Runner 単位** で効くと考える
- そのため、Runner のタグ設計がそのまま権限境界になる
- 本番権限を持つ Runner は protected branch / protected tag 向けジョブに寄せる
- 長期鍵を使う場合は、変数のスコープとローテーション手順を明確にする

## OIDC について

- GitLab 14.2 では CI/CD の OIDC は使えない
- このリポジトリの IAM テンプレートには将来向けに OIDC trust 用パラメータがある
- ただし **現行運用では使わない**
- GitLab を **15.7 以降** に上げたときに、`id_tokens:` を使う構成を別途検討する
