#!/usr/bin/env bash
# setup-server.sh - one-shot bootstrap for a fresh Ubuntu 24.04 Azure VM.
# Installs Git + Nginx, creates the 'deploy' user and its GitHub SSH key,
# waits for you to add the key to GitHub, clones the repo and publishes the site.
#
#   curl -fsSL https://raw.githubusercontent.com/bhunnid/cns3205-git-deploy/main/scripts/setup-server.sh -o setup-server.sh
#   sudo REPO=git@github.com:bhunnid/cns3205-git-deploy.git bash setup-server.sh
set -euo pipefail

REPO="${REPO:?Set REPO=git@github.com:bhunnid/cns3205-git-deploy.git}"
APP_DIR=/var/www/cns3205
DEPLOY_USER=deploy

[[ $EUID -eq 0 ]] || { echo "Run with sudo"; exit 1; }
step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

step "Installing git, nginx, curl, python3"
apt-get update -qq
apt-get install -y -qq git nginx curl python3 >/dev/null
git --version

step "Creating user '$DEPLOY_USER'"
id "$DEPLOY_USER" &>/dev/null || adduser --disabled-password --gecos "" "$DEPLOY_USER"

step "Generating the server's GitHub SSH key"
sudo -u "$DEPLOY_USER" bash -c '
  mkdir -p ~/.ssh && chmod 700 ~/.ssh
  [[ -f ~/.ssh/id_ed25519 ]] || ssh-keygen -q -t ed25519 -N "" -C "deploy@$(hostname)" -f ~/.ssh/id_ed25519
  ssh-keyscan -t ed25519 github.com 2>/dev/null >> ~/.ssh/known_hosts
  sort -u -o ~/.ssh/known_hosts ~/.ssh/known_hosts'
echo
echo "Add this PUBLIC key at GitHub -> Settings -> SSH and GPG keys -> New SSH key:"
echo
cat "/home/$DEPLOY_USER/.ssh/id_ed25519.pub"
echo
until sudo -u "$DEPLOY_USER" ssh -T git@github.com 2>&1 | grep -q "successfully authenticated"; do
  read -rp "Press Enter once the key is added to GitHub... "
done
sudo -u "$DEPLOY_USER" ssh -T git@github.com 2>&1 | head -1 || true

step "Cloning $REPO into $APP_DIR"
mkdir -p "$APP_DIR" && chown "$DEPLOY_USER:$DEPLOY_USER" "$APP_DIR"
[[ -d "$APP_DIR/.git" ]] || sudo -u "$DEPLOY_USER" git clone -q "$REPO" "$APP_DIR"
sudo -u "$DEPLOY_USER" git -C "$APP_DIR" log --oneline -3

step "Configuring Nginx"
cp "$APP_DIR/server/nginx-cns3205.conf" /etc/nginx/sites-available/cns3205
ln -sf /etc/nginx/sites-available/cns3205 /etc/nginx/sites-enabled/cns3205
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

step "Installing the auto-deploy timer (fallback to GitHub Actions)"
cp "$APP_DIR"/server/cns3205-autodeploy.{service,timer} /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now cns3205-autodeploy.timer

step "First deployment"
sudo -iu "$DEPLOY_USER" env FORCE=1 bash "$APP_DIR/scripts/deploy.sh"

ip=$(curl -fsS --max-time 5 https://api.ipify.org || hostname -I | awk '{print $1}')
step "Done - open http://$ip"
