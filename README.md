[README (1).md](https://github.com/user-attachments/files/33030163/README.1.md)
<div align="center">

# Terraform AWS Tech News AI Agent

### A reusable serverless reference implementation for curating and delivering AI-summarized technology news

[![Terraform](https://img.shields.io/badge/Terraform-1.6%2B-7B42BC?logo=terraform&logoColor=white)](https://www.terraform.io/)
[![AWS](https://img.shields.io/badge/AWS-Serverless-FF9900?logo=amazonaws&logoColor=white)](https://aws.amazon.com/)
[![Python](https://img.shields.io/badge/Lambda-Python-3776AB?logo=python&logoColor=white)](https://www.python.org/)
[![Amazon Bedrock](https://img.shields.io/badge/Amazon%20Bedrock-Generative%20AI-232F3E)](https://aws.amazon.com/bedrock/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Template](https://img.shields.io/badge/Type-Reusable%20Reference-blue)](#)

**EventBridge Scheduler → Lambda → DynamoDB → Amazon Bedrock → Slack**

A public-reference Terraform module and Python Lambda implementation for collecting configured technology feeds, filtering previously processed stories, curating a concise digest with Amazon Bedrock, and delivering it to Slack.

</div>

---

## Why this exists

Keeping up with technology is increasingly an **information filtering problem** rather than an information access problem.

This repository demonstrates one small, practical AI-agent workflow: collect recent content, remove stories already considered, ask a foundation model to rank and summarize the useful items, and deliver the resulting brief to a channel you already use.

The implementation intentionally keeps content sources, model selection, AWS region, schedule, interests, and destination details configurable. No publisher-specific feeds, personal identifiers, AWS account identifiers, or webhook values are included in the repository.

> **Reference implementation:** use sources you are authorized to consume and review their API, RSS, licensing, and usage requirements before deployment. The included Lambda reads RSS/Atom metadata and does not scrape full article bodies.

## Architecture

<p align="center">
  <img src="docs/architecture.png" alt="AWS Tech News AI Agent architecture" width="100%">
</p>

### Request flow

1. **Amazon EventBridge Scheduler** invokes the workflow on a configurable schedule and timezone.
2. **AWS Lambda** runs the bundled Python reference agent.
3. The agent retrieves its destination webhook from **AWS Secrets Manager**.
4. Configured RSS/Atom feeds are fetched over HTTPS.
5. Candidate stories are checked against **Amazon DynamoDB** to prevent repeated processing.
6. Unseen candidates are sent to **Amazon Bedrock** for curation and summarization.
7. The digest is delivered to **Slack**.
8. Candidate fingerprints are stored in DynamoDB with **TTL enabled** after a successful delivery.
9. **Amazon CloudWatch** receives Lambda logs and native execution metrics.

## What this module creates

| Component | Purpose |
|---|---|
| EventBridge Scheduler | Runs the agent on a configurable schedule and IANA timezone |
| AWS Lambda | Hosts the Python reference agent |
| DynamoDB | Stores hashed article identifiers for deduplication |
| DynamoDB TTL | Automatically expires stale dedupe records |
| Secrets Manager | Stores the destination webhook outside the code and Terraform variables |
| IAM roles and policies | Grants scoped service-to-service permissions |
| CloudWatch Logs | Captures Lambda application and execution logs |
| Amazon Bedrock permissions | Allows invocation of explicitly supplied model or inference-profile ARNs |

## Repository layout

```text
terraform-aws-tech-news-agent/
├── main.tf
├── variables.tf
├── outputs.tf
├── versions.tf
├── README.md
├── LICENSE
├── .gitignore
├── src/
│   └── handler.py
├── docs/
│   └── architecture.png
└── examples/
    └── basic/
        └── main.tf
```

## Design goals

- **Generic by default** — content sources and environment-specific values are inputs, not hard-coded implementation details.
- **Runnable reference code** — the repository now includes a small Python Lambda implementation rather than infrastructure alone.
- **Serverless** — no always-on compute is required.
- **Least privilege** — the Lambda can read one secret, access one DynamoDB table, invoke only supplied Bedrock resources, and write to its log group.
- **Secret-safe** — Terraform manages secret metadata, not the webhook value.
- **Timezone aware** — EventBridge Scheduler supports configurable IANA timezones.
- **Low dependency** — the Lambda uses the Python standard library plus the AWS SDK available in the Lambda runtime.
- **Extensible** — callers can override the Lambda ZIP, add environment variables, or add narrowly scoped IAM statements.

## Quick start

The included example requires your AWS region, Bedrock identifiers, and content sources as inputs instead of embedding example account IDs or real publishers.

```hcl
provider "aws" {
  region = var.aws_region
}

module "tech_news_agent" {
  source = "../../"

  name = "tech-news"

  bedrock_model_id   = var.bedrock_model_id
  bedrock_model_arns = var.bedrock_model_arns
  content_sources    = var.content_sources

  schedule_expression = "cron(30 8 * * ? *)"
  schedule_timezone   = "Etc/UTC"
}
```

A content source uses this shape:

```hcl
content_sources = [
  {
    name = "Example technology feed"
    url  = "https://example.com/feed.xml"
    kind = "feed"
  }
]
```

The names and URLs above are placeholders only. Configure feeds you are permitted to consume.

Then initialize and validate:

```bash
terraform init
terraform fmt -recursive
terraform validate
terraform plan
```

## Lambda packaging

By default, the module packages the bundled `src/` directory with the Terraform `archive` provider and deploys it to Lambda.

If you want to use your own implementation instead, provide a pre-built ZIP:

```hcl
lambda_package_path = "/path/to/your/lambda.zip"
```

The default handler is:

```text
handler.lambda_handler
```

## Content source configuration

The reference Lambda expects RSS or Atom feeds over HTTPS. Each source has a display name, URL, and optional descriptive kind.

```hcl
content_sources = [
  {
    name = "Example vendor updates"
    url  = "https://example.com/updates.xml"
    kind = "official"
  },
  {
    name = "Example industry feed"
    url  = "https://example.org/feed.xml"
    kind = "feed"
  }
]
```

The `kind` field is informational context supplied to the model. It does not grant trust or change network permissions.

## Curation controls

Useful behavior can be adjusted without changing the Python code:

```hcl
interests      = "cloud computing, security, software engineering, AI, and emerging technology"
top_n          = 10
lookback_hours = 24
dedupe_ttl_days = 14
digest_title   = "Tech brief"
```

The Lambda only gives Bedrock the feed-provided title and short summary for each candidate. The prompt instructs the model not to invent details beyond that supplied metadata.

## Deduplication model

URLs are canonicalized and hashed before being stored as DynamoDB keys. A stored record looks conceptually like:

```json
{
  "article_id": "sha256-of-canonical-url",
  "expires_at": 1791000000
}
```

The raw URL does not need to be stored in the dedupe table.

After a digest is successfully posted, the agent marks **all unseen candidates supplied to the model** as processed, not only the stories selected for the final digest. This prevents the same unselected candidates from consuming model input on every run.

## Slack webhook handling

Terraform creates the **Secrets Manager secret metadata only** by default. Populate the value separately so the webhook is not intentionally written into Terraform configuration or state.

The bundled Lambda accepts either:

```json
{
  "webhook_url": "https://your-webhook-endpoint.example/path"
}
```

or a raw HTTPS webhook URL as the secret string.

A generic CLI pattern is:

```bash
aws secretsmanager put-secret-value \
  --secret-id <secret-name-or-arn> \
  --secret-string '{"webhook_url":"https://your-webhook-endpoint.example/path"}'
```

Do not commit the actual webhook value to Git.

## Lambda environment variables

Terraform supplies the reference application with:

| Variable | Purpose |
|---|---|
| `TABLE_NAME` | DynamoDB deduplication table |
| `SLACK_SECRET_ID` | Secrets Manager secret name/ARN containing the webhook |
| `MODEL_ID` | Bedrock model or inference-profile identifier |
| `CONTENT_SOURCES_JSON` | JSON representation of configured RSS/Atom sources |
| `INTERESTS` | Topics used to rank candidate stories |
| `TOP_N` | Maximum stories requested for the digest |
| `LOOKBACK_HOURS` | Candidate publication-time window |
| `TTL_DAYS` | Deduplication retention period |
| `DIGEST_TITLE` | Heading for the Slack digest |
| `LOG_LEVEL` | Python logging level |

Additional environment variables can be supplied with `lambda_environment_variables`.

## Bedrock model access

The model identifier and IAM resources are intentionally separate inputs:

```hcl
bedrock_model_id   = var.bedrock_model_id
bedrock_model_arns = var.bedrock_model_arns
```

This allows the caller to use a supported Bedrock model or inference profile without hard-coding a particular model version in the repository.

For inference profiles, supply every Bedrock resource ARN required by the invocation path. The module grants only:

```text
bedrock:InvokeModel
```

by default.

## Security model

The reference IAM policy is deliberately narrower than a manually prototyped environment may be:

- `secretsmanager:GetSecretValue` is scoped to the configured webhook secret.
- DynamoDB access is limited to `BatchGetItem` and `BatchWriteItem` on the dedupe table.
- Bedrock access is limited to `InvokeModel` on caller-supplied ARNs.
- EventBridge Scheduler uses a dedicated role that can invoke only this Lambda function.
- Lambda log permissions are limited to its CloudWatch log group.
- Optional KMS keys can be supplied for Secrets Manager and CloudWatch Logs.
- No AWS-managed `FullAccess` policies are required by the reference implementation.

If a custom Lambda implementation needs additional AWS APIs, add only the required actions with `additional_lambda_policy_statements`.

## Observability

The module creates a CloudWatch log group with configurable retention. Lambda also publishes its standard execution metrics to CloudWatch automatically.

A CloudWatch alarm is **not** created by this reference module. Teams that need paging, dashboards, anomaly detection, or service-level alerting can add those controls according to their own operational requirements.

## Scheduling

The default schedule expression is:

```text
cron(30 8 * * ? *)
```

and the default timezone is:

```text
Etc/UTC
```

Override `schedule_timezone` with the IANA timezone appropriate for your deployment if you want a stable local wall-clock time across daylight-saving changes.

## Manual source check

You can invoke the Lambda manually with this test event to validate configured feeds without sending a Slack digest:

```json
{
  "check_sources": true
}
```

The response reports only source names, status, entry counts, and error types. It does not return secrets.

## Production hardening ideas

This repository is intentionally small. Depending on your requirements, you may want to add:

- an SQS dead-letter queue;
- structured JSON logging;
- CloudWatch dashboards or alarms;
- Lambda code signing or artifact controls;
- VPC connectivity for private dependencies;
- Bedrock Guardrails;
- source allow-list governance or content reputation controls;
- CI checks such as `terraform fmt`, `terraform validate`, `tflint`, and security scanning.

## Requirements

| Dependency | Version / expectation |
|---|---|
| Terraform | `>= 1.6` |
| AWS provider | `>= 6.0` |
| Archive provider | `>= 2.4` |
| Lambda runtime | Python 3.13 by default |
| Amazon Bedrock | Model access configured in the deployment region |
| AWS credentials | Permissions to create the resources used by this module |

## License

Released under the [MIT License](LICENSE).

This makes the reference implementation easy to reuse, modify, fork, and build on while preserving the standard MIT copyright and warranty notice.

---

<div align="center">

**Built as a reusable reference architecture for experimenting with small, practical AI-agent workflows on AWS.**

</div>
