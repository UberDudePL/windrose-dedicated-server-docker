# syntax=docker/dockerfile:1.7
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV USER=steam
ENV HOME=/home/steam
ENV STEAMCMDDIR=/opt/steamcmd
ENV DISPLAY=:99
ENV WINEPREFIX=/home/steam/.wine
ENV WINEARCH=win64
ENV WINEDLLOVERRIDES=mscoree,mshtml=
ENV WINEDEBUG=-all
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    set -eux; \
    retry_apt_update() { \
      attempt=1; \
      while [ "$attempt" -le 5 ]; do \
        rm -rf /var/lib/apt/lists/*; \
        if apt-get update -o Acquire::Retries=5 -o Acquire::By-Hash=force -o Acquire::http::No-Cache=true; then \
          return 0; \
        fi; \
        echo "apt-get update failed on attempt $attempt, retrying..."; \
        apt-get clean; \
        attempt=$((attempt + 1)); \
        sleep 15; \
      done; \
      return 1; \
    }; \
    dpkg --add-architecture i386; \
    if [ -f /etc/apt/sources.list ]; then \
      sed -i 's|http://archive.ubuntu.com/ubuntu|mirror://mirrors.ubuntu.com/mirrors.txt|g' /etc/apt/sources.list; \
      sed -i 's|http://security.ubuntu.com/ubuntu|mirror://mirrors.ubuntu.com/mirrors.txt|g' /etc/apt/sources.list; \
    fi; \
    mkdir -pm755 /etc/apt/keyrings; \
    retry_apt_update; \
    apt-get install -y --no-install-recommends \
      wget gpg ca-certificates curl \
      xvfb xauth \
      winbind \
      lib32gcc-s1 lib32stdc++6 \
      libc6:i386 libstdc++6:i386 \
      libncurses6:i386 libtinfo6:i386 \
      locales \
      jq \
      procps; \
    wget -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key; \
    wget -NP /etc/apt/sources.list.d/ https://dl.winehq.org/wine-builds/ubuntu/dists/jammy/winehq-jammy.sources; \
    retry_apt_update; \
    apt-get install -y --install-recommends winehq-stable; \
    rm -rf /var/lib/apt/lists/*

RUN sed -i 's/^# \(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen && locale-gen

RUN mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix

RUN useradd -u 1000 -m -s /bin/bash steam

RUN mkdir -p /opt/steamcmd && \
    curl -sSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
    | tar -xz -C /opt/steamcmd && \
  chown -R steam:steam /opt/steamcmd /home/steam

RUN set -eux; \
    Xvfb :99 -screen 0 1024x768x16 -nolisten tcp >/tmp/windrose-build-xvfb.log 2>&1 & \
    xvfb_pid=$!; \
    trap 'kill "$xvfb_pid" 2>/dev/null || true' EXIT; \
    sleep 2; \
    su -m -s /bin/bash steam -c "timeout 180 bash -c 'winecfg -v win10 >/tmp/windrose-build-wine.log 2>&1 || true; wineboot --init >>/tmp/windrose-build-wine.log 2>&1 || true; wineserver -w >/dev/null 2>&1 || true'"; \
    kill "$xvfb_pid" 2>/dev/null || true; \
    wait "$xvfb_pid" 2>/dev/null || true; \
    trap - EXIT

COPY entrypoint.sh /entrypoint.sh
COPY healthcheck.sh /healthcheck.sh
RUN chmod +x /entrypoint.sh /healthcheck.sh

# Keep the container entrypoint running as root so it can adjust mounted
# volume ownership and then launch the server process as the steam user.
WORKDIR /home/steam

ENTRYPOINT ["/entrypoint.sh"]
