# Docket: infrastructure

Infrastructure for [Docket](https://github.com/sjamillah/Docket-app), a task list
running on ECS Fargate in a single region. Reads are served from ElastiCache for
Redis; writes go to PostgreSQL through an RDS Proxy.

Everything here is CloudFormation, deployed through Git sync.

## Stack layout

One stack this repository deploys; thirteen CloudFormation creates for you.

| Stack | Repository | Deployed by |
|---|---|---|
| `docket-bootstrap` | [Docket-bootstrap](https://github.com/sjamillah/Docket-bootstrap) | by hand once, then Git sync |
| `docket-main` | here | Git sync from `deployments/main.yaml` |

The bootstrap stack creates the roles everything else assumes, including the
ones Git sync itself uses, so it lives in its own repository and is deployed
before this one. Nothing here refers to it except through Parameter Store.

| File | Holds |
|---|---|
| `main.yaml` | The parent, referencing the thirteen templates below by path |
| `main.packaged.yaml` | What Git sync deploys. Written by `make package`, committed with the change |
| `templates/ecr.yaml` | The container registry, built on the first pass |
| `templates/alerts.yaml` | The SNS topic every alarm and the pipeline publish to |
| `templates/network.yaml` | VPC, eight subnets across four tiers and two AZs, routing |
| `templates/security.yaml` | Six security groups and every rule between them |
| `templates/endpoints.yaml` | The gateway and interface endpoints that replace a NAT gateway |
| `templates/database.yaml` | PostgreSQL, the RDS Proxy, and the proxy target group |
| `templates/cache.yaml` | Redis replication group, Multi-AZ with automatic failover |
| `templates/iam.yaml` | The six roles the running system assumes, and the parameters naming them |
| `templates/service.yaml` | Load balancer, target group pair, cluster, task, service, scaling |
| `templates/codedeploy.yaml` | Blue/green, and the two alarms that gate a cutover |
| `templates/artifacts.yaml` | The artifact bucket, where the app repo drops its deploy config |
| `templates/pipeline.yaml` | EventBridge rule and CodePipeline |
| `templates/monitoring.yaml` | Alarms that notify, not ones that block |

### Changing a template

```bash
git add -A && git commit -m "..." && git push
```

That is the whole flow. One CI job lints, packages the children into S3, and
deploys `docket-main` with the parameters and tags in `deployments/main.yaml`.
Nothing is committed back, so there is no second workflow run and no generated
file in the repository.

`make package` locally is only for seeing the rewritten URLs before you push.

## Address plan

The brief requires ECS, the database and the cache in dedicated subnets, so
there are four tiers rather than three.

| Tier | AZ a | AZ b | Usable | Holds |
|---|---|---|---|---|
| Public | `10.30.0.0/26` | `10.30.0.64/26` | 59 | the load balancer |
| Private &middot; app | `10.30.1.0/26` | `10.30.1.64/26` | 59 | tasks and the endpoint ENIs |
| Private &middot; data | `10.30.2.0/27` | `10.30.2.32/27` | 27 | RDS and the proxy |
| Private &middot; cache | `10.30.3.0/27` | `10.30.3.32/27` | 27 | Redis |

`10.30.4.0/22` onward is unallocated, three quarters of the VPC.

There are no NAT gateways. The private route tables carry `local` and the S3
prefix list, nothing else, so no task has a path to the internet in either
direction. Seven endpoints replace it.

## How a request is served

A read reaches the task, which asks Redis first. On a miss it queries
PostgreSQL **through the proxy**, caches the result and returns it. Every write
goes through the proxy and evicts the cached list.

The tasks never open a connection to PostgreSQL. `docket-db-sg` accepts from
`docket-proxy-sg` and from nothing else, which is enforced in
`security.yaml` rather than left to convention.

## Getting it running

Three repositories, three stacks' worth of responsibility, and one rule: no
value is ever copied from a console into a config file. Every identifier is
written to Parameter Store by the stack that creates it, and resolved from
there by whatever needs it.

| Repository | Deploys | How |
|---|---|---|
| [Docket-bootstrap](https://github.com/sjamillah/Docket-bootstrap) | `docket-bootstrap` | by hand once, then Git sync |
| Docket-infra (here) | `docket-main` | Git sync, from `main.packaged.yaml` |
| [Docket-app](https://github.com/sjamillah/Docket-app) | nothing | GitHub Actions pushes an image and a deploy config |

**1. Deploy the bootstrap stack.** It creates the roles Git sync asks for in
step 3, so it cannot deploy itself the first time. The command and its
parameters are in the [bootstrap repository](https://github.com/sjamillah/Docket-bootstrap).

It publishes `/docket/alert-email`, `/docket/template-bucket`, the four role
ARNs, and `/docket/s3-prefix-list-id`, which it looks up rather than being
told. Nothing here needs to be created by hand afterwards:

```bash
R=$(aws configure get region)
aws ssm get-parameters-by-path --path /docket --recursive --region $R   --query 'Parameters[].[Name,Value]' --output table
```

Seven rows, none of them `None`.

**2. The GitHub connection.** One connection covering all three repositories,
reading `AVAILABLE`. Git sync uses it; nothing in a template does.

```bash
aws codeconnections list-connections --region $R   --query "Connections[].[ConnectionName,ConnectionStatus]" --output table
```

If it does not cover them, add the repositories in Developer Tools,
Connections, under the connection's GitHub Apps link.

**3. Package and push this repository.** CI verifies the packaged file; Git
sync deploys it in step 4.

| Name | Kind | Source |
|---|---|---|
| `AWS_ROLE_ARN` | secret | `/docket/gha-infra-role-arn` |
| `AWS_REGION` | variable | the deployment region |

```bash
aws ssm get-parameter --name /docket/gha-infra-role-arn --query Parameter.Value --output text
make package
git add -A && git commit -m "..." && git push
```

`main.packaged.yaml` does not exist until `make package` writes it.

**4. Create the synced stack.** CloudFormation, Create stack, Sync from Git.

| Field | Value |
|---|---|
| Stack name | `docket-main` |
| Repository | your connection, branch `main` |
| Deployment file | `deployments/main.yaml` |
| Git sync role | `docket-gitsync` |
| Stack operations role | `docket-cfn-deployment` |

Choose the existing roles; do not let the console create new ones. Around
forty minutes, most of it Multi-AZ PostgreSQL, the proxy and Redis.

This pass runs with `DeployApplication: 'false'`, which still builds the
registry, the IAM roles and the artifact bucket — everything the application
repository needs in step 6.

**5. Set the one application repository secret.**

| Name | Kind | Source |
|---|---|---|
| `AWS_ROLE_ARN` | secret | `/docket/gha-app-role-arn`, published by **bootstrap** |
| `AWS_REGION` | variable | the same region |

That role is bootstrap's, not this stack's, so it exists from step 1 — but the
workflow cannot succeed until this stack has run once, because it resolves the
registry, the artifact bucket, both task role ARNs and the two endpoints from
parameters that only exist afterwards.

**6. Push the application.** One run does two things: uploads
`config/deploy.zip`, holding the rendered `taskdef.json` and `appspec.yaml`,
then moves `:latest`, which is the tag the EventBridge rule watches.

```bash
aws ecr describe-images --repository-name docket --region $R   --query 'imageDetails[].imageTags' --output table
aws s3 ls "s3://$(aws ssm get-parameter --name /docket/artifact-bucket   --query Parameter.Value --output text)/config/"
```

**7. Flip to the second pass.** Set `DeployApplication: 'true'` in
`deployments/main.yaml`, commit and push. That is a deployment-file change,
not a template one, so Git sync deploys it directly and no repackaging is
needed. The service, CodeDeploy and the pipeline appear.

**8. Confirm the SNS subscription.** The email went out back at step 4, when
the alerts child created the subscription, and the link expires after three
days. Until it is clicked the subscription reads `PendingConfirmation` and all
ten alarms publish into nothing.

```bash
aws sns list-subscriptions --region $R   --query "Subscriptions[?contains(TopicArn,'docket-alerts')].[Endpoint,SubscriptionArn]" --output table
```

## When something needs a nudge

**A config-only change does not deploy.** The pipeline's S3 source sets
`PollForSourceChanges: false`, so only an image push starts a deployment.
Changing `taskdef.json` alone needs `aws codepipeline start-pipeline-execution
--name docket-pipeline`. The retry arrow replays the same source revision.

**The deploy config is uploaded, not read from git.** CodePipeline reads
`config/deploy.zip` out of the artifact bucket. If it is missing, the app
repository has not run a successful build yet, and the Deploy stage will fail
on a missing source rather than on anything to do with the image.

## Roles

Nothing is created by hand in the console. The four in the bootstrap
repository are deployment identity — the two GitHub Actions roles and the two
Git sync assumes — and have to exist before anything here is deployed. The six
in `iam.yaml` belong to the running system and nothing outside it can assume
them.

| Role | Assumed by | Permitted to |
|---|---|---|
| `docket-gha-infra` | Actions, infra repo, `main` | Write the template bucket, read two parameters |
| `docket-cfn-deployment` | `cloudformation.amazonaws.com` | The project's services; IAM confined to `docket-*`; denied outside the region |
| `docket-gitsync` | Git sync | Read the repo, drive change sets, pass the deployment role |
| `docket-proxy` | `rds.amazonaws.com` | Read the master secret RDS generated |
| `docket-task-execution` | The ECS agent | Pull the image, create log streams, read one secret |
| `docket-task` | The application | Open ECS Exec channels. Nothing else |
| `docket-codedeploy` | CodeDeploy | Create task sets, shift target groups |
| `docket-pipeline` | CodePipeline | Artifacts, the connection, register task definitions, drive CodeDeploy |
| `docket-eventbridge-pipeline` | EventBridge | Start this one pipeline |
| `docket-gha-app` | Actions, app repo, `main` | Push to this registry |

The application's own role holds no database or cache permission, because it
needs none: credentials are injected by the agent before the container starts,
and Redis is reached over the network.

Both GitHub roles pin `aud` to `sts.amazonaws.com` and `sub` to one repository
on `main`, accepting both the classic and the immutable subject shapes.

## Decisions

**RDS manages the master password.** `ManageMasterUserPassword: true` means RDS
generates, stores and rotates it. There is no `AWS::SecretsManager::Secret` here
and no `SecretTargetAttachment`; the proxy and the task both read
`Database.MasterUserSecret.SecretArn`. Rotation comes free, which hand-rolling
the secret does not give you.

**The proxy is not optional decoration.** Fargate tasks come and go, and each
one opening its own PostgreSQL connections is what exhausts a `db.t3.micro`.
The proxy holds a warm pool, survives a failover without dropping clients, and
is why the application's pool is capped at five connections per task.

**The cache is read-through with whole-list eviction.** The list is small and
eviction that is obviously correct beats eviction that is clever. A test asserts
every mutating method evicts the key the read populates, because a new mutation
without an eviction would be invisible until the TTL.

**Nested children over separate stacks.** Children take parameters rather than
`Fn::ImportValue`, so nothing locks: an export cannot be changed or deleted
while an import exists, which would turn teardown into thirteen deletes in a fixed
order.

**Every log group is declared.** RDS, ElastiCache and Lambda all create their
own with retention set to never expire, and all three outlive the stack.
Declaring them means neither happens.

## Teardown

Three steps, and only the middle one is automated. CloudFormation cannot empty
an S3 bucket, and it will not delete one that still holds objects — that gap is
worth a make target. Deleting the stacks is a decision, so it stays yours.

**1. Unsync both stacks**, or a stray push recreates what you delete.
Stack actions, Stop sync from Git in the console, or:

```bash
for s in docket-main docket-bootstrap; do
  aws codeconnections delete-sync-configuration --sync-type CFN_STACK_SYNC --resource-name $s
done
```

**2. Empty the buckets.**

```bash
make empty CONFIRM=docket
```

Two buckets, both holding only regenerable build artefacts: the artifact bucket
belongs to `docket-main`, the template bucket to `docket-bootstrap`. The
artifact bucket *is* versioned, because a CodePipeline S3 source action
requires it, so `rm --recursive` alone would leave delete markers behind and
the stack delete would stall; the `empty` target loops over
`list-object-versions` until nothing is left. `CONFIRM` is required because
emptying the template bucket of a *live* stack breaks its next update until
you run `make package` again.

**3. Delete the stacks yourself** — `docket-main` first, then
`docket-bootstrap`. Console, or `aws cloudformation delete-stack`. Delete one
before its bucket is empty and it stops at that resource: run step 2 and retry
the delete.

Then three things that survive on purpose, each destroying something
irreplaceable:

```bash
R=eu-north-1

# billed, and kept because DeletionPolicy: Snapshot
aws rds describe-db-snapshots --snapshot-type manual --region $R \
  --query 'DBSnapshots[].DBSnapshotIdentifier' --output text

# every /docket parameter is owned by one of the two stacks and goes with it,
# so this is a check that nothing was left behind rather than a cleanup step
aws ssm get-parameters-by-path --path /docket --recursive --region $R   --query 'Parameters[].Name' --output text

# last of all, and only after the stack is gone
aws iam delete-role --role-name docket-cfn-deployment
aws iam delete-role --role-name docket-gitsync
```

The two roles carry `DeletionPolicy: Retain` because CloudFormation assumes the
first of them to tear its own stack down. Delete it early and the stack delete
fails with *"role is invalid or cannot be assumed"* — permanently, because the
failure is cached against the request token.

## Known gaps

- **The ALB is HTTP.** ACM will not issue without a domain. The fix without
  buying one is a CloudFront distribution in front of the ALB using its default
  certificate.
- **No VPC Flow Logs.** The security argument here is that nothing can reach the
  internet, and there is no record proving it.
- **No ALB access logs.** Container logs cover the application; there is no
  per-request record at the load balancer.
- **ECS Exec is always on.** Deliberate, because it is how you diagnose a task
  that cannot reach the proxy, but it is shell access into a running task with
  no switch to turn it off.
- **Scaling tracks CPU only.** `ALBRequestCountPerTarget` reacts to load more
  directly and would be the second signal under real traffic.
