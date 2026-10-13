# Trial results

One row per day of the trial (task 5.1), taken with:

- `lgtm-data` size: `docker system df -v` (row `backend_lgtm-data`)
- LGTM memory: `docker stats --no-stream backend-lgtm-1`
- Active testers: installations with a prod `session.start` in the last 24 h,
  `count(count by (app_installation_id) (count_over_time({service_name="my_team", deployment_environment_name="prod"} | event_name="session.start" [24h])))`
  in Loki

| Date | `lgtm-data` | LGTM memory | Active testers | Notes |
|---|---|---|---|---|
| 2026-10-14 (baseline) | 617.8 MB | 550 MiB of 3.8 GiB | 1 (owner's iPhone) | Before handing out builds; includes simulator and example-app data since 2026-10-12 |
