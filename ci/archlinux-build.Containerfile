FROM archlinux:latest

RUN printf '\nDisableDownloadTimeout\n' >>/etc/pacman.conf \
    && for attempt in 1 2 3; do pacman -Syu --noconfirm --needed \
      archiso \
      base-devel \
      buf \
      clang \
      cmake \
      git \
      gtk3 \
      jq \
      ninja \
      pkgconf \
      protobuf \
      rust \
      sudo \
      unzip \
      xz \
      zip \
      && break; \
      test "$attempt" -lt 3 || exit 1; \
    done \
    && pacman -Scc --noconfirm \
    && useradd --create-home --uid 1000 builder \
    && printf 'builder ALL=(ALL:ALL) NOPASSWD: ALL\n' >/etc/sudoers.d/builder

# Flutter SDK (Linux desktop target) + Dart protoc plugin for the shell build.
RUN sudo -u builder git clone --depth 1 --branch stable \
      https://github.com/flutter/flutter /home/builder/flutter \
    && sudo -u builder /home/builder/flutter/bin/flutter --disable-analytics \
    && sudo -u builder /home/builder/flutter/bin/flutter precache --linux \
    && sudo -u builder /home/builder/flutter/bin/dart pub global activate protoc_plugin

ENV PATH="/home/builder/flutter/bin:/home/builder/.pub-cache/bin:${PATH}"

WORKDIR /src
