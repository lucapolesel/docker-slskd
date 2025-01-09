# syntax=docker/dockerfile:1-labs
FROM public.ecr.aws/docker/library/alpine:3.20 AS base
ENV TZ=UTC
WORKDIR /src

# source stage =================================================================
FROM base AS source

# get and extract source from git
ARG VERSION
ADD https://github.com/slskd/slskd.git#$VERSION ./

# frontend stage ===============================================================
FROM base AS build-frontend

# dependencies
RUN apk add --update npm

# node_modules
COPY --from=source /src/src/web/ ./
RUN npm ci

# frontend source and build
RUN npm run build && \
    mv ./build /build

# normalize arch ===============================================================
FROM base AS base-arm64
ENV RUNTIME=linux-musl-arm64
FROM base AS base-amd64
ENV RUNTIME=linux-musl-x64

# backend stage ================================================================
FROM base-$TARGETARCH AS build-backend

# dependencies
RUN apk add --no-cache dotnet8-sdk

# dotnet source
COPY --from=source /src/ ./src

# build backend
ARG BRANCH
ARG VERSION
RUN mkdir /build && \
    dotnet publish ./src/slskd.sln \
        -p:RuntimeIdentifiers=$RUNTIME \
        -p:Configuration=Release \
        -p:PublishDir=/build/bin

# versioning (runtime)
ARG COMMIT=$VERSION
COPY <<EOF /build/package_info
PackageAuthor=[lucapolesel](https://github.com/lucapolesel/docker-slskd)
UpdateMethod=Docker
Branch=$BRANCH
PackageVersion=$COMMIT
EOF

# runtime stage ================================================================
FROM base

ARG VERSION
ENV S6_VERBOSITY=0 S6_BEHAVIOUR_IF_STAGE2_FAILS=2 PUID=65534 PGID=65534 UMASK=002
ENV SLSKD_UMASK=$UMASK \
    SLSKD_HTTP_PORT=5030 \
    SLSKD_HTTPS_PORT=5031 \
    SLSKD_SLSK_LISTEN_PORT=50300 \
    SLSKD_DOCKER_VERSION=$VERSION
WORKDIR /config
VOLUME /config
EXPOSE 5030

# copy files
COPY --from=build-backend /build /app
COPY --from=build-frontend /build /app/bin/wwwroot
COPY ./rootfs/. /

# runtime dependencies
RUN apk add --no-cache tzdata s6-overlay aspnetcore8-runtime sqlite-libs curl

# run using s6-overlay
ENTRYPOINT ["/init"]
