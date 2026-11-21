# 1Password references only. playbooks/media-stack.yml resolves this with `op inject` straight into
# /opt/media-stack/stack/aurral/secrets.env (mode 600) on the VM; never commit the result.
AURRAL_API_KEY=op://xmjfgnsondcvlqa6bovelwdztm/media-stack/aurral_api_key
