# syntax=docker/dockerfile:1
# Cisco Packet Tracer 9.0.1 in Docker, UI over TCP: noVNC 6080, native VNC 5900
# Requires the official NetAcad .deb in ./deb/ before building
# 9.0.1 installs /opt/pt/packettracer.AppImage (Qt6 + Chromium 130) for native NetAcad login

# Global ARG: usable in FROM lines and inherited by every stage that re-declares it
ARG PT_DEB=CiscoPacketTracer_901_Ubuntu_64bit.deb

# Fetch stage: picks the requested .deb out of deb/ and fails with a readable
# message when the file name does not match PT_DEB. Its layers are discarded,
# so the final image only carries the selected .deb.
FROM ubuntu:22.04 AS fetch
ARG PT_DEB
COPY deb/ /tmp/debs/
RUN set -eu; \
    src="/tmp/debs/${PT_DEB}"; \
    if [ ! -f "$src" ]; then \
        echo "ERROR: deb/${PT_DEB} not found." >&2; \
        echo "       .deb files present in deb/:" >&2; \
        (cd /tmp/debs && ls -1 *.deb 2>/dev/null) | sed 's|^|         deb/|' >&2 || echo "         (none)" >&2; \
        echo "       Fix: set PT_DEB in compose.yml to match the file name." >&2; \
        exit 1; \
    fi; \
    mv "$src" /tmp/pt.deb; \
    rm -rf /tmp/debs

FROM ubuntu:22.04

ARG PUID=1001
ARG PGID=1001
ARG PT_DEB=CiscoPacketTracer_901_Ubuntu_64bit.deb

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# 1) Packet Tracer deps (Qt6/Chromium 130) + VNC/noVNC/Fluxbox stack, from ldd on clean ubuntu:22.04
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    tzdata \
    sudo \
    dialog \
    xdg-utils \
    xauth \
    xterm \
    x11-utils \
    libgl1 \
    libegl1 \
    libglu1-mesa \
    libx11-6 \
    libxext6 \
    libxcomposite1 \
    libxdamage1 \
    libxfixes3 \
    libxrandr2 \
    libxtst6 \
    libxss1 \
    libxcb1 \
    libxcb-dri3-0 \
    libxcb-icccm4 \
    libxcb-image0 \
    libxcb-keysyms1 \
    libxcb-randr0 \
    libxcb-render-util0 \
    libxcb-shm0 \
    libxcb-xinerama0 \
    libxcb-xfixes0 \
    libxcb-cursor0 \
    libxkbcommon0 \
    libxkbcommon-x11-0 \
    libxkbfile1 \
    libdrm2 \
    libegl-mesa0 \
    libglib2.0-0 \
    libdbus-1-3 \
    libexpat1 \
    libfontconfig1 \
    libharfbuzz0b \
    libpng16-16 \
    libbrotli1 \
    libnspr4 \
    libnss3 \
    libasound2 \
    libpulse0 \
    libfuse2 \
    wget \
    xz-utils \
    libgtk-3-0 \
    libdbus-glib-1-2 \
    libxt6 \
    libstartup-notification0 \
    libcanberra-gtk3-module \
    aspell-en \
    tigervnc-standalone-server \
    novnc \
    websockify \
    fluxbox \
    feh \
    dbus-x11 \
    fonts-liberation \
    fonts-dejavu-core \
    && ln -fs /usr/share/zoneinfo/$TZ /etc/localtime \
    && dpkg-reconfigure --frontend noninteractive tzdata \
    && rm -rf /var/lib/apt/lists/*

# 2) "pt" user with the host uid/gid so the bind mounts stay compatible
RUN groupadd -g ${PGID} pt \
    && useradd -m -u ${PUID} -g ${PGID} -s /bin/bash pt \
    && mkdir -p /home/pt/saves /home/pt/storage \
    && chown -R ${PUID}:${PGID} /home/pt

# 3) Repack the .deb without preinst/postinst (EULA prompt, --pt-activate) and extract the AppImage once, so no FUSE at runtime
COPY --from=fetch /tmp/pt.deb /tmp/pt.deb
RUN echo "sha256 of the .deb:" && sha256sum /tmp/pt.deb \
    && mkdir -p /tmp/ptpkg/DEBIAN \
    && dpkg-deb -x /tmp/pt.deb /tmp/ptpkg/ \
    && dpkg-deb -e /tmp/pt.deb /tmp/ptpkg/DEBIAN/ \
    && rm -f /tmp/ptpkg/DEBIAN/preinst /tmp/ptpkg/DEBIAN/postinst \
    && dpkg-deb -Z xz -b /tmp/ptpkg /tmp/pt-repacked.deb \
    && dpkg -i /tmp/pt-repacked.deb; \
    dpkg --configure -a; \
    apt-get update \
    && apt-get -f install -y --no-install-recommends; \
    dpkg --configure -a; \
    ln -sf /opt/pt/packettracer.AppImage /usr/local/bin/packettracer \
    && cd /opt/pt && ./packettracer.AppImage --appimage-extract >/dev/null \
    && rm -f /tmp/pt.deb /tmp/pt-repacked.deb \
    && rm -rf /tmp/ptpkg /var/lib/apt/lists/* \
    && chown -R ${PUID}:${PGID} /opt/pt

# 4) Firefox for the PT 9 xdg-open OAuth login; official tarball because apt firefox is a snap stub on 22.04
RUN wget -q "https://download.mozilla.org/?product=firefox-latest&os=linux64&lang=en-US" \
        -O /tmp/firefox.tar.xz \
    && tar -xJf /tmp/firefox.tar.xz -C /opt \
    && ln -sf /opt/firefox/firefox /usr/local/bin/firefox \
    && rm -f /tmp/firefox.tar.xz \
    && chown -R ${PUID}:${PGID} /opt/firefox

# 5) Entrypoint
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER pt
ENV HOME=/home/pt
ENV DISPLAY=:1

# Firefox as the default browser for xdg-open (PT 9 NetAcad login)
RUN mkdir -p ~/.local/share/applications && \
    printf '%s\n' \
      '[Desktop Entry]' 'Version=1.0' 'Name=Firefox' 'Exec=firefox %u' \
      'Terminal=false' 'Type=Application' \
      'MimeType=text/html;text/plain;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;' \
      > ~/.local/share/applications/firefox.desktop && \
    xdg-mime default firefox.desktop x-scheme-handler/http x-scheme-handler/https text/html

EXPOSE 5900 6080

CMD ["/usr/local/bin/entrypoint.sh"]
