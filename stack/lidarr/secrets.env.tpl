# 1Password references only. deploy.sh resolves this with `op inject` straight into
# /opt/media-stack/stack/lidarr/secrets.env (mode 600) on the VM; never commit the result.
LIDARR__AUTH__APIKEY=op://xmjfgnsondcvlqa6bovelwdztm/media-stack/lidarr_api_key
