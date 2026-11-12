# CloudWatch Logs Insights queries. Each one is written once, here, and used twice: as a saved query that can
# be opened from the Logs Insights console, and as a table on Dashboard 2. The backend logs one JSON object per
# line (step 3.3), so Insights finds the fields (level, context, path, status, durationMs, ...) by itself.
# The time range is chosen in the console, not saved with the query: "in the last hour" means setting it to 1h.
locals {
  queries = {
    backend_errors = join("\n", [
      "fields @timestamp, level, context, message, requestId, path, status",
      "| filter level = 'error' or level = 'fatal'",
      "| sort @timestamp desc",
      "| limit 50",
    ])

    slowest_requests = join("\n", [
      "fields @timestamp, method, path, status, durationMs, requestId",
      "| filter context = 'http'",
      "| sort durationMs desc",
      "| limit 20",
    ])

    slowest_paths = join("\n", [
      "filter context = 'http'",
      "| stats count(*) as requests, avg(durationMs) as avg_ms, pct(durationMs, 95) as p95_ms, max(durationMs) as max_ms by path",
      "| sort p95_ms desc",
      "| limit 20",
    ])

    failed_paths = join("\n", [
      "filter context = 'http' and status >= 400",
      "| stats count(*) as requests by path, status",
      "| sort requests desc",
      "| limit 20",
    ])

    server_errors_by_path = join("\n", [
      "filter context = 'http' and status >= 500",
      "| stats count(*) as failures by path, status",
      "| sort failures desc",
    ])

    failed_app_logins = join("\n", [
      "fields @timestamp, requestId, status, durationMs",
      "| filter context = 'http' and path = '/api/auth/login' and status >= 400",
      "| sort @timestamp desc",
      "| limit 50",
    ])

    # auth.log is the host's log (PAM, sudo, sshd if it ever runs), not the application's. There is no SSH here
    # (access is through SSM), so what this finds is failed authentication on the host, not failed SSH logins.
    auth_failures = join("\n", [
      "fields @timestamp, @message",
      "| filter @message like /(?i)(failed|failure|invalid user|denied|not in sudoers)/",
      "| sort @timestamp desc",
      "| limit 50",
    ])
  }

  saved_queries = {
    "Backend errors"                               = { group = "backend", query = local.queries.backend_errors }
    "Slowest requests"                             = { group = "backend", query = local.queries.slowest_requests }
    "Slowest paths (p95)"                          = { group = "backend", query = local.queries.slowest_paths }
    "Failed requests by path (4xx and 5xx)"        = { group = "backend", query = local.queries.failed_paths }
    "5xx by path"                                  = { group = "backend", query = local.queries.server_errors_by_path }
    "Failed application logins"                    = { group = "backend", query = local.queries.failed_app_logins }
    "Failed authentication on the host (auth.log)" = { group = "auth", query = local.queries.auth_failures }
  }
}

resource "aws_cloudwatch_query_definition" "saved" {
  for_each        = local.saved_queries
  name            = "${var.name_prefix}/${each.key}"
  log_group_names = [var.log_group_names[each.value.group]]
  query_string    = each.value.query
}
