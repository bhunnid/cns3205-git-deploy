# cns3205-git-deploy

CNS 3205 Server Administration lab: Git + GitHub on an Azure Ubuntu VM, with automatic
deployment on every push to `main`.

**Team:** Brandon Kiplangat (193310), Ian Muyala (191616), Eric Muhika (191633)

```
git push ──► GitHub ──► Actions: test ──► Actions: deploy ──ssh──► Azure VM: scripts/deploy.sh
                                                                     │  fetch + reset to origin/main
                                                                     │  health check
                                                                     ├─ ok   → live on Nginx :80
                                                                     └─ fail → roll back, run goes red
```

| Path | Purpose |
| --- | --- |
| `site/` | The website Nginx serves (shows the deployed commit and deployment history) |
| `scripts/deploy.sh` | Pulls the latest commit, health-checks it, rolls back on failure |
| `scripts/setup-server.sh` | One-shot bootstrap of a fresh Ubuntu VM |
| `server/nginx-cns3205.conf` | Nginx site config |
| `server/cns3205-autodeploy.{service,timer}` | Polling fallback: runs deploy.sh every 2 minutes |
| `.github/workflows/deploy.yml` | GitHub Actions CI/CD |
| `.gitlab-ci.yml` | Same pipeline for GitLab |

## Quick start

1. Create the VM in Azure (Ubuntu 24.04, ports 22 and 80 open).
2. Push this folder to a new GitHub repo.
3. On the VM:
   ```bash
   sudo REPO=git@github.com:bhunnid/cns3205-git-deploy.git bash setup-server.sh
   ```
4. Add repo secrets `SERVER_HOST`, `SERVER_USER` (= `deploy`), `SSH_PRIVATE_KEY`
   (private half of a key whose public half is in `/home/deploy/.ssh/authorized_keys`).
5. Edit `site/index.html`, commit, push, refresh `http://<SERVER_IP>`.
