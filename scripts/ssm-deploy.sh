#!/usr/bin/env bash
# Usage: ssm-deploy.sh <environment> <image-tag>
#
# Runs /opt/app/deploy.sh <image-tag> on every instance tagged environment=<environment> and Role=app,
# through SSM Run Command, and waits for it. cd.yml calls this from the deploy-staging job and from
# the production job.
#
#   <environment>  the value of the instances' "environment" tag: staging or prod
#   <image-tag>    the short commit SHA that build-and-push pushed to ECR
#
# How it behaves, and why:
# - One instance at a time, and stop at the first error (--max-concurrency 1, --max-errors 0). The
#   other instance keeps serving the old version while the first one is updated, and a failed deploy
#   does not reach it.
# - It waits for each instance with "aws ssm wait command-executed", and when that fails it prints
#   the instance's stdout and stderr (aws ssm get-command-invocation) and exits 1. The waiter gives up
#   after 100 seconds, which a deploy that pulls images and runs migrations can exceed, so a waiter that
#   gave up while the command is still running is simply called again, until DEPLOY_TIMEOUT.
# - A command whose tags match no instance is a FAILURE. SSM reports it as a success (with TargetCount 0,
#   which is also what it reports for a command that does reach instances), so without this check a
#   deploy to an environment that is down, or whose instances are not registered with SSM, would pass.
# - The command as a whole must end in Success, not just the instances this script happened to see. That
#   catches an instance whose invocation appeared after the others had finished.
#
# Environment (all optional): DEPLOY_TIMEOUT seconds for the whole deploy (default 900), EXECUTION_TIMEOUT
# seconds deploy.sh may run on one instance (default 600), POLL_DELAY seconds between checks (default 5),
# NO_TARGET_GRACE seconds to wait for the first instance to show up (default 60). The AWS region and
# credentials come from the environment, as for any aws command.
#
# Tests: scripts/tests/ssm-deploy.test.sh
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: ssm-deploy.sh <environment> <image-tag>" >&2
  exit 2
fi

ENVIRONMENT="$1"
TAG="$2"
# Both end up inside a JSON document that becomes a shell command on the instances, so only the
# characters they can really contain are accepted (the tag check is the one deploy.sh makes too).
[[ "$ENVIRONMENT" =~ ^[a-z0-9-]+$ ]] || { echo "invalid environment: $ENVIRONMENT" >&2; exit 2; }
[[ "$TAG" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "invalid image tag: $TAG" >&2; exit 2; }

DEPLOY_TIMEOUT="${DEPLOY_TIMEOUT:-900}"
EXECUTION_TIMEOUT="${EXECUTION_TIMEOUT:-600}"
POLL_DELAY="${POLL_DELAY:-5}"
NO_TARGET_GRACE="${NO_TARGET_GRACE:-60}"

echo "==> deploying ${TAG} to the instances tagged environment=${ENVIRONMENT}, Role=app"
COMMAND_ID=$(aws ssm send-command \
  --document-name AWS-RunShellScript \
  --targets "Key=tag:environment,Values=${ENVIRONMENT}" "Key=tag:Role,Values=app" \
  --parameters "{\"commands\":[\"/opt/app/deploy.sh ${TAG}\"],\"executionTimeout\":[\"${EXECUTION_TIMEOUT}\"]}" \
  --max-concurrency 1 \
  --max-errors 0 \
  --comment "deploy ${TAG} (GitHub run ${GITHUB_RUN_ID:-manual})" \
  --query Command.CommandId --output text)
echo "SSM command ${COMMAND_ID}"

STARTED=$SECONDS
HANDLED=" "

# show_output <instance>: what deploy.sh printed on that instance.
show_output() {
  local instance="$1" out err
  out=$(aws ssm get-command-invocation --command-id "$COMMAND_ID" --instance-id "$instance" \
    --query StandardOutputContent --output text || true)
  err=$(aws ssm get-command-invocation --command-id "$COMMAND_ID" --instance-id "$instance" \
    --query StandardErrorContent --output text || true)
  [ "$out" = "None" ] || [ -z "$out" ] || { echo "--- stdout of ${instance}"; echo "$out"; }
  [ "$err" = "None" ] || [ -z "$err" ] || { echo "--- stderr of ${instance}"; echo "$err"; }
}

# wait_for <instance>: returns when deploy.sh has succeeded there, and exits 1 when it has not.
wait_for() {
  local instance="$1" status
  echo "==> waiting for ${instance}"
  while true; do
    if aws ssm wait command-executed --command-id "$COMMAND_ID" --instance-id "$instance" 2>/dev/null; then
      show_output "$instance"
      return 0
    fi
    # The waiter exits non-zero both for a failed command and for "gave up after 100 seconds".
    status=$(aws ssm get-command-invocation --command-id "$COMMAND_ID" --instance-id "$instance" \
      --query Status --output text)
    case "$status" in
      Pending | InProgress | Delayed)
        if [ $((SECONDS - STARTED)) -ge "$DEPLOY_TIMEOUT" ]; then
          echo "ERROR: the deploy on ${instance} did not finish within ${DEPLOY_TIMEOUT} seconds (status ${status})" >&2
          show_output "$instance"
          exit 1
        fi
        ;;
      *)
        echo "ERROR: deploying ${TAG} on ${instance} ended with status ${status}" >&2
        aws ssm get-command-invocation --command-id "$COMMAND_ID" --instance-id "$instance" \
          --query '[StatusDetails,ResponseCode]' --output text >&2 || true
        show_output "$instance"
        exit 1
        ;;
    esac
  done
}

while true; do
  # Every instance that has an invocation and has not been waited for yet, one at a time.
  for instance in $(aws ssm list-command-invocations --command-id "$COMMAND_ID" \
      --query 'CommandInvocations[].InstanceId' --output text); do
    [[ "$HANDLED" == *" ${instance} "* ]] && continue
    wait_for "$instance"
    HANDLED="${HANDLED}${instance} "
  done

  status=$(aws ssm list-commands --command-id "$COMMAND_ID" --query 'Commands[0].Status' --output text)
  case "$status" in
    Success)
      if [ "$HANDLED" != " " ]; then
        break
      fi
      echo "ERROR: no instance with the tags environment=${ENVIRONMENT} and Role=app took the command." >&2
      echo "Is the environment up, and are its instances registered with Systems Manager?" >&2
      exit 1
      ;;
    Failed | Cancelled | TimedOut)
      echo "ERROR: the SSM command ended with status ${status}" >&2
      exit 1
      ;;
    *)
      if [ "$HANDLED" = " " ] && [ $((SECONDS - STARTED)) -ge "$NO_TARGET_GRACE" ]; then
        echo "ERROR: no instance with the tags environment=${ENVIRONMENT} and Role=app took the command" >&2
        echo "within ${NO_TARGET_GRACE} seconds. Is the environment up, and are its instances registered with Systems Manager?" >&2
        exit 1
      fi
      if [ $((SECONDS - STARTED)) -ge "$DEPLOY_TIMEOUT" ]; then
        echo "ERROR: the deploy did not finish within ${DEPLOY_TIMEOUT} seconds (command status ${status})" >&2
        exit 1
      fi
      sleep "$POLL_DELAY"
      ;;
  esac
done

echo "deployed ${TAG} to ${ENVIRONMENT}"
