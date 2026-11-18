# Pinned build environment for VideoMail's Windows zip.
#
# Everything is fixed: the base image by digest and every compiler package
# by a snapshot.debian.org date. Building the same source in this image
# gives a byte-identical zip, so anyone can rebuild a release and compare
# its SHA-256 with the published one. See "Verify a download" in README.md.
FROM debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2

ARG SNAPSHOT=20261115T000000Z

# Plain http is fine: apt verifies every package against Debian's signing keys.
RUN rm -f /etc/apt/sources.list.d/debian.sources \
 && printf '%s\n' \
      "deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/${SNAPSHOT} trixie main" \
      "deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/${SNAPSHOT} trixie-updates main" \
      "deb [check-valid-until=no] http://snapshot.debian.org/archive/debian-security/${SNAPSHOT} trixie-security main" \
      > /etc/apt/sources.list \
 && apt-get -o Acquire::Check-Valid-Until=false update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git xz-utils make nasm meson ninja-build cmake pkgconf python3 zip \
      gcc libc6-dev \
      gcc-mingw-w64-x86-64-posix g++-mingw-w64-x86-64-posix \
      binutils-mingw-w64-x86-64 mingw-w64-x86-64-dev \
 && rm -rf /var/lib/apt/lists/*

ENV HOME=/tmp TZ=UTC LC_ALL=C.UTF-8 SOURCE_DATE_EPOCH=1794960000

# Writable by any user, so the build can run as a normal (non-root) user.
RUN mkdir -p /build /build.cache /out && chmod 1777 /build /build.cache /out

COPY reproducible-build.sh /usr/local/bin/reproducible-build.sh
ENTRYPOINT ["bash", "/usr/local/bin/reproducible-build.sh"]
