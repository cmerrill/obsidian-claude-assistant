# Debian, not Alpine: Claude Code ships a glibc-linked ripgrep.
# Since Supervisor 2026.04.0 the BUILD_FROM arg is no longer supplied, so the
# base image is named explicitly.
FROM ghcr.io/home-assistant/base-debian:bookworm

# Pin both tools so a rebuild is a deliberate act, not a surprise.
ARG CLAUDE_CODE_VERSION=latest
ARG OBSIDIAN_HEADLESS_VERSION=latest
ARG NODE_MAJOR=22

ENV LANG=C.UTF-8 \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_FUND=false

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg git openssh-client jq inotify-tools; \
    mkdir -p /etc/apt/keyrings; \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg; \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends nodejs; \
    npm install -g \
        "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
        "obsidian-headless@${OBSIDIAN_HEADLESS_VERSION}"; \
    npm cache clean --force; \
    apt-get purge -y gnupg; \
    apt-get autoremove -y; \
    rm -rf /var/lib/apt/lists/*

# Claude Code refuses --dangerously-skip-permissions when running as root, and
# add-ons start as root. The three long-running services drop to this user.
RUN useradd --uid 1000 --create-home --shell /bin/bash app

COPY rootfs /

RUN set -eux; \
    chmod a+x \
        /usr/bin/triage.sh \
        /usr/bin/triage-loop.sh \
        /usr/bin/obsidian-sync.sh \
        /usr/bin/notify.sh \
        /usr/bin/geocode.sh \
        /usr/bin/inbox-done.sh \
        /usr/bin/vault-git.sh; \
    find /etc/s6-overlay/s6-rc.d -name run -exec chmod a+x {} \; ; \
    find /etc/s6-overlay/s6-rc.d -name up -exec chmod a+x {} \;

LABEL io.hass.name="Obsidian Claude Assistant" \
      io.hass.description="Headless Obsidian Sync plus Claude Code inbox triage" \
      io.hass.type="addon" \
      io.hass.version="0.3.0"
