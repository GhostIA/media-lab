# 1Password reference only (never a real value). stack/deploy.sh resolves it on the VM with
# `op inject` into sonarr/secrets.env (mode 600). The resolved file never goes into the repo.
SONARR__AUTH__APIKEY=op://xmjfgnsondcvlqa6bovelwdztm/media-stack/sonarr_api_key
