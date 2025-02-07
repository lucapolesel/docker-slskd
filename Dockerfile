# syntax=docker/dockerfile:1-labs
#############################
# Base Image & Common Settings
#############################
FROM public.ecr.aws/docker/library/alpine:3.20 AS base
ENV TZ=UTC
WORKDIR /src

#############################
# Source Stage (for slskd)
#############################
FROM base AS source
ARG VERSION
ADD https://github.com/slskd/slskd.git#$VERSION ./

#############################
# Frontend Stage
#############################
FROM base AS build-frontend
# Install npm for frontend build
RUN apk add --update npm
# Copy frontend source from the slskd repository
COPY --from=source /src/src/web/ ./
RUN npm ci
# Build the frontend and move the output to /build
RUN npm run build && mv ./build /build

#############################
# Backend Stage
#############################
# Set up separate base images for different architectures
FROM base AS base-arm64
ENV RUNTIME=linux-musl-arm64
FROM base AS base-amd64
ENV RUNTIME=linux-musl-x64

FROM base-$TARGETARCH AS build-backend
# Install dotnet build dependencies
RUN apk add --no-cache dotnet8-sdk
# Copy the backend source from the source stage
COPY --from=source /src/ ./src
ARG BRANCH
ARG VERSION
# Build the backend using dotnet publish
RUN mkdir /build && \
    dotnet publish ./src/slskd.sln \
        -p:RuntimeIdentifiers=$RUNTIME \
        -p:Configuration=Release \
        -p:PublishDir=/build/bin
# Add package version info
ARG COMMIT=$VERSION
COPY <<EOF /build/package_info
PackageAuthor=[lucapolesel](https://github.com/lucapolesel/docker-slskd)
UpdateMethod=Docker
Branch=$BRANCH
PackageVersion=$COMMIT
EOF

#############################
# Beets Build Stage (Installed into /beets)
#############################
FROM base AS build-beets
ARG BUILD_DATE
ARG VERSION
ARG BEETS_VERSION
# Install build dependencies and runtime packages for beets
RUN apk add --no-cache --virtual=build-beets-deps \
      build-base \
      cairo-dev \
      cargo \
      cmake \
      ffmpeg-dev \
      fftw-dev \
      git \
      gobject-introspection-dev \
      jpeg-dev \
      libpng-dev \
      mpg123-dev \
      openjpeg-dev \
      python3-dev \
      unzip && \
    apk add --no-cache \
      chromaprint \
      expat \
      ffmpeg \
      fftw \
      flac \
      gdbm \
      gobject-introspection \
      gst-plugins-good \
      gstreamer \
      imagemagick \
      jpeg \
      lame \
      libffi \
      libpng \
      mpg123 \
      nano \
      openjpeg \
      python3 \
      sqlite-libs && \
    echo "**** compile mp3gain ****" && \
    mkdir -p /tmp/mp3gain-src && \
    curl -o /tmp/mp3gain-src/mp3gain.zip -sL https://sourceforge.net/projects/mp3gain/files/mp3gain/1.6.2/mp3gain-1_6_2-src.zip && \
    cd /tmp/mp3gain-src && \
    unzip -qq mp3gain.zip && \
    sed -i "s#/usr/local/bin#/usr/bin#g" Makefile && \
    make && make install && \
    echo "**** compile mp3val ****" && \
    mkdir -p /tmp/mp3val-src && \
    curl -o /tmp/mp3val-src/mp3val.tar.gz -sL https://downloads.sourceforge.net/mp3val/mp3val-0.1.8-src.tar.gz && \
    cd /tmp/mp3val-src && \
    tar xzf mp3val.tar.gz --strip 1 && \
    make -f Makefile.linux && \
    cp -p mp3val /usr/bin && \
    echo "**** install pip packages for beets ****" && \
    if [ -z "${BEETS_VERSION}" ]; then \
      BEETS_VERSION=$(curl -sL https://pypi.python.org/pypi/beets/json | jq -r '.info.version'); \
    fi && \
    # Create a Python virtual environment in /beets and install beets
    python3 -m venv /beets && \
    /beets/bin/pip install -U --no-cache-dir pip wheel && \
    /beets/bin/pip install -U --no-cache-dir --find-links https://wheel-index.linuxserver.io/alpine-3.21/ \
      beautifulsoup4 \
      beets==${BEETS_VERSION} \
      beets-extrafiles \
      beetcamp \
      python3-discogs-client \
      flask \
      PyGObject \
      pyacoustid \
      pylast \
      requests \
      requests_oauthlib \
      typing-extensions \
      unidecode && \
    echo "**** cleanup beets build dependencies ****" && \
    apk del --purge build-beets-deps && \
    rm -rf /tmp/* /root/.cache /root/.cargo
# Set environment variables similar to the original beets image
ENV BEETSDIR="/config" \
    EDITOR="nano" \
    HOME="/config"

#############################
# Final Runtime Stage
#############################
FROM base
ARG VERSION
# Set slskd-related environment variables
ENV S6_VERBOSITY=0 \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    PUID=65534 \
    PGID=65534 \
    UMASK=002 \
    SLSKD_UMASK=$UMASK \
    SLSKD_HTTP_PORT=5030 \
    SLSKD_HTTPS_PORT=5031 \
    SLSKD_SLSK_LISTEN_PORT=50300 \
    SLSKD_DOCKER_VERSION=$VERSION

WORKDIR /config
VOLUME /config
EXPOSE 5030

# Copy slskd backend and frontend artifacts
COPY --from=build-backend /build /app
COPY --from=build-frontend /build /app/bin/wwwroot
COPY ./rootfs/. /

# Install runtime dependencies for slskd and beets
RUN apk add --no-cache \
      tzdata \
      s6-overlay \
      aspnetcore8-runtime \
      sqlite-libs \
      curl \
      python3 \
      ffmpeg \
      fftw \
      flac \
      gdbm \
      gobject-introspection \
      gst-plugins-good \
      gstreamer \
      imagemagick \
      jpeg \
      lame \
      libffi \
      libpng \
      mpg123 \
      nano \
      openjpeg \
      chromaprint \
      expat

# Copy the beets installation (the virtual environment and helper binaries) from build-beets
COPY --from=build-beets /beets /beets
COPY --from=build-beets /usr/bin/mp3gain /usr/bin/mp3gain
COPY --from=build-beets /usr/bin/mp3val /usr/bin/mp3val

# Update PATH so that beets (installed in /beets/bin) is available for terminal use
ENV PATH="/beets/bin:${PATH}"

# Start the container (using s6-overlay as the init system for slskd)
ENTRYPOINT ["/init"]
