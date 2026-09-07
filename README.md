# AWS 503 Incident Lab

A realistic reproduction of a real freelance job posting's exact incident —
"frontend loads fine, `/api/v1/user/me` returns 503, login and
forgot-password are broken" — built end-to-end (EC2 + ALB + Target Group +
Cloudflare), then deliberately broken four different ways to practice the
real diagnostic playbook the job posting describes, instead of just reading
about it.

## Architecture

```
Browser → Cloudflare (proxied) → ALB → Target Group → EC2 (Flask app, systemd)
```
![image alt](https://github.com/gkoufie1/sre-503-incident-lab/blob/028af756efc01fa7affb4667653cfd4dcebec027/Arch.png)

- **EC2** — Amazon Linux 2023, `t3.micro`, running a small Flask app
  (`app/app.py`) as a systemd service, with `/health`, `/api/v1/user/me`,
  `/login`, and `/forgot-password`.
- **Application Load Balancer + Target Group** — health check on `/health`,
  instance-type target.
- **Cloudflare** — proxies a subdomain of `georgekoufie.xyz` to the ALB's
  DNS name.
- **Security groups** — ALB accepts 80 from anywhere; the instance only
  accepts 8080 from the ALB's security group, and SSH only from one IP.

Everything is in `terraform/`, using the default VPC (no NAT Gateway, so no
lingering cost between apply/destroy cycles).

## Cost

Real, small, and non-zero while running: an ALB (~$0.0225/hr + LCU charges)
and a `t3.micro` (~$0.01/hr, often free-tier eligible). This was applied,
tested, and destroyed the same session — not left running.

## The four break-scenarios, with real results

### 1. Deregistered target (simulates a crashed/stopped instance)

Stopped the backend service, then explicitly deregistered the target.

- **With the service just stopped** (target still registered, health check
  failing): the ALB returned **`502 Bad Gateway`**, and CloudWatch's
  `TargetConnectionErrorCount` confirmed a real TCP connection failure —
  the ALB tried to reach the target and the connection was refused.
- **With the target fully deregistered** (zero targets in the group): the
  ALB returned **`503 Service Temporarily Unavailable`**, `Server:
  awselb/2.0` — an exact match to the real job posting's described symptom.
  Target Group state: `draining`, reason `Target.DeregistrationInProgress`.

**The real lesson:** `502` and `503` are not interchangeable — `502` means
the ALB has a target and the connection/response to it failed; `503` means
the ALB has no target at all to route to. A real `503` like the one in the
job posting points toward "zero available capacity," not "one instance
crashed."

**Fix:** re-registered the target, restarted the service, verified `200`.

### 2. Misconfigured health check path

Changed the Target Group's health check path to `/nonexistent-health`
(which 404s).

**Real, counter-intuitive result:** the Target Group correctly reported
`unhealthy` (reason `Target.ResponseCodeMismatch`, health checks failing
with `404`) — but real requests to `/api/v1/user/me` kept returning `200`.
With only one target registered (flagged unhealthy, not deregistered), the
ALB kept routing real traffic to it rather than failing every request. This
is a genuine, easy-to-get-wrong distinction: a failing health check is
immediately visible as an operational red flag in the console/CLI, but in
this single-target topology it isn't automatically a customer-facing outage
the way full deregistration (Scenario 1) is.

**Fix:** restored the correct `/health` path, verified the target returned
to `healthy`.
![image alt](https://github.com/gkoufie1/sre-503-incident-lab/blob/6e29edd788cd05634de2c54a1fa49396a7f0ccef/alb.png)

### 3. Security group blocking the health check port

Revoked the ALB security group's ingress rule on port 8080 to the instance.

**Real result:** Target Group reason was `Target.Timeout` ("Request timed
out") — a genuinely different signature from Scenario 1's connection
*refusal*, because a security group silently drops the packet instead of
rejecting it. Real customer traffic got **`504 Gateway Timeout`**, a third
distinct status code from this set of scenarios.

**Fix:** restored the ingress rule, verified recovery to `200`.
![image alt](https://github.com/gkoufie1/sre-503-incident-lab/blob/510248ebdb656d120e512546d8ce021823ab90ac/ec2server.png)

### 4. Real application-level bug (matches the job posting's exact symptom)

Deployed a version of the app with a typo'd variable name in a helper
function shared by both `/login` and `/forgot-password`.

**Real result:** `/health` and `/api/v1/user/me` kept returning `200` the
entire time — the Target Group never left `healthy`, because the ALB has no
visibility into application-level logic, only the health check endpoint.
`/login` and `/forgot-password` both returned real `500`s. The exact error,
read from `journalctl -u backend` on the instance:

```
File "/opt/app/app.py", line 18, in _log_auth_event
    print(f"[auth] {event_typo}: {request_body}")
NameError: name 'event_typo' is not defined
```

**This is the scenario that most precisely matches the real job posting** —
"frontend loading normally," specific auth-related endpoints broken, while
general API health looks fine. It's also the one where checking the Target
Group and CloudWatch metrics alone would tell you nothing — the actual
service logs are the only place the real cause shows up.

**Fix:** redeployed the correct code, verified both endpoints returned real
success responses.

## The diagnostic pattern across all four

| Scenario | Target Group reason | Customer sees |
|---|---|---|
| Deregistered target | `Target.DeregistrationInProgress` | `503` |
| Service stopped (still registered) | `Target.FailedHealthChecks` (connection refused) | `502` |
| Broken health check path | `Target.ResponseCodeMismatch` | `200` (traffic still flows) |
| SG blocking the port | `Target.Timeout` | `504` |
| App-level bug | *(none — stays healthy)* | `500` on the broken routes only |

No single check catches all five states. The real playbook is: check Target
Group health and its stated *reason* first, check CloudWatch metrics to
confirm what kind of failure it is (connection error vs. timeout vs.
nothing), and if the Target Group looks healthy but specific functionality
is broken, the answer is in the application's own logs, not the
infrastructure layer at all.
![image alt](https://github.com/gkoufie1/sre-503-incident-lab/blob/671e4f3c4684fec6d5dcaed7281a92c345260727/target.png)

## Repository structure

```
terraform/
  main.tf, variables.tf, outputs.tf, versions.tf
  templates/user_data.sh.tftpl
app/
  app.py            # the correct version
  app_broken.py      # Scenario 4's deliberately broken version, kept for reference
```

## How to run it

```bash
cd terraform
terraform init
terraform apply
# Point a Cloudflare-proxied CNAME at the alb_dns_name output
```

## Teardown

```bash
cd terraform
terraform destroy
```
