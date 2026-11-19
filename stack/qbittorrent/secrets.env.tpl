# 1Password reference only; resolved by `op inject` at deploy time into secrets.env (mode 600, never committed).
# Consumed by configure.sh (sets the WebUI password); not passed to the container.
QBT_PASSWORD=op://xmjfgnsondcvlqa6bovelwdztm/media-stack/qbittorrent_password
