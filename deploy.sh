#!/usr/bin/env bash
# deploy.sh – развёртывание music‑, music‑tgbot‑ и registry‑сервисов + Ingress
# Usage: ./deploy.sh dev|prod

set -euo pipefail
IFS=$'\n\t'

###############################################################################
# 0. Пауза перед закрытием окна (работает и при ошибках)                      #
###############################################################################
pause_on_exit() {
  local rc=$?
  echo
  if [[ $rc -eq 0 ]]; then
    echo "✅  Script finished successfully."
  else
    echo "❌  Script aborted with exit code $rc."
  fi
  read -n1 -rsp $'\nPress any key to close this window…'
}
trap pause_on_exit EXIT

###############################################################################
# 1. Проверяем аргументы                                                      #
###############################################################################
usage() { echo "Usage: $0 dev|prod" >&2; exit 1; }
[[ $# -eq 1 ]] || usage
[[ "$1" == "dev" || "$1" == "prod" ]] || usage
ENV="$1"

###############################################################################
# 2. Переходим в корень репозитория                                           #
###############################################################################
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

echo "▶️  Environment: $ENV"
echo "▶️  Kube‑context: $(kubectl config current-context)"

###############################################################################
# 3. Применяем ConfigMaps / Secrets                                           #
###############################################################################
echo "▶️  Applying ConfigMaps and Secrets…"
kubectl apply -R -f ./k3s/envs/

###############################################################################
# 4. (Re)создаём Secret с YouTube cookies                                     #
###############################################################################
echo "▶️  (Re)creating Secret 'youtube-cookies'…"
kubectl create secret generic youtube-cookies \
  --from-file=youtube_cookies.txt=$SCRIPT_DIR/volumes/www.youtube.com_cookies.txt \
  --dry-run=client -o yaml | kubectl apply -f -

###############################################################################
# 5. Ingress‑манифесты                                                        #
###############################################################################
echo "▶️  Applying Ingress manifests…"
kubectl apply -R -f ./k3s/ingress/

###############################################################################
# 6‑A. Docker‑registry (общий для dev и prod)                                 #
###############################################################################
echo "▶️  Deploying local Docker registry…"
kubectl apply -f ./k3s/services/registry/registry.yaml
# Ingress‑правило уже находится в файле server‑ingress.yaml, который применён выше

###############################################################################
# 6‑B. Сервисы music / music‑tgbot                                            #
###############################################################################
echo "▶️  Applying '$ENV' overlay for music‑service…"
kubectl apply -k "./k3s/services/music/${ENV}"

echo "▶️  Applying '$ENV' overlay for music‑tgbot‑service…"
kubectl apply -k "./k3s/services/music-tgbot/${ENV}"

###############################################################################
# 7. Minikube‑специфичные действия                                            #
###############################################################################
if [[ "$ENV" == "dev" && "$(kubectl config current-context)" =~ ^minikube$ ]]; then
  echo "▶️  Enabling Minikube ingress addon…"
  if ! minikube addons list | grep -qE '^ingress\s*Enabled'; then
    minikube addons enable ingress
  else
    echo "ℹ️  ingress addon already enabled"
  fi

  echo "⏳  Waiting for ingress‑nginx controller to become ready…"
  kubectl wait --namespace ingress-nginx \
    --for=condition=Available deployment/ingress-nginx-controller \
    --timeout=120s

  echo "🚇  Ensuring 'minikube tunnel' is running…"
  if ! pgrep -f "minikube tunnel" >/dev/null 2>&1; then
    nohup minikube tunnel --cleanup >/dev/null 2>&1 &
    disown
    echo "ℹ️  Tunnel started"
  else
    echo "ℹ️  Tunnel already running"
  fi
fi

if [[ $ENV == dev ]]; then
  echo -e "\nℹ️  Push example:"
  echo "   docker build -t registry.local/music-tgbot:dev ."
  echo "   docker push    registry.local/music-tgbot:dev"
else
  echo -e "\nℹ️  Push example (prod):"
  echo "   docker login   registry.distrbyt.com"
  echo "   docker build -t registry.distrbyt.com/music-tgbot:latest ."
  echo "   docker push    registry.distrbyt.com/music-tgbot:latest"
fi

echo "✅  $ENV deployment complete!"
