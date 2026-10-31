# Parley's rspamd settings, put here by parley-servers-setup when rspamd is installed.
# The mail servers ask the scanner over HTTP (POST /checkv2), so it listens on this machine only.
bind_socket = "127.0.0.1:11333";
