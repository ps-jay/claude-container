##==----------------------------------------------------------------------------
FROM ghcr.io/astral-sh/uv:0.13.9 AS uv

##==----------------------------------------------------------------------------
FROM debian:trixie-slim AS curl

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl

##==----------------------------------------------------------------------------
FROM curl AS asdf

ARG ASDF_VERSION=v0.20.2
ARG TARGETARCH=amd64

RUN cd /tmp \
 && curl -fsSLO "https://github.com/asdf-vm/asdf/releases/download/${ASDF_VERSION}/asdf-${ASDF_VERSION}-linux-${TARGETARCH}.tar.gz" \
 && tar -xzf "asdf-${ASDF_VERSION}-linux-${TARGETARCH}.tar.gz" \
 && install -m 0755 asdf /usr/local/bin/asdf

##==----------------------------------------------------------------------------
FROM curl AS gh

ARG GH_VERSION=2.105.0
ARG TARGETARCH=amd64

RUN cd /tmp \
 && curl -fsSLO "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${TARGETARCH}.tar.gz" \
 && curl -fsSLO "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_checksums.txt" \
 && grep "gh_${GH_VERSION}_linux_${TARGETARCH}.tar.gz" "gh_${GH_VERSION}_checksums.txt" | sha256sum -c - \
 && tar -xzf "gh_${GH_VERSION}_linux_${TARGETARCH}.tar.gz" \
 && install -m 0755 "gh_${GH_VERSION}_linux_${TARGETARCH}/bin/gh" /usr/local/bin/gh

##==----------------------------------------------------------------------------
# Throwaway stage: Node is only used here to run the npm package's installer.
# The package ships a native binary, so the final image needs no Node.
FROM node:26-trixie-slim AS claude-code

# Cache-busting barrier
ARG CACHEBUST=1
RUN echo "${CACHEBUST}"
RUN npm install -g @anthropic-ai/claude-code

##==----------------------------------------------------------------------------
FROM debian:trixie-slim AS claude

# node:26 (non-slim) is built on buildpack-deps, so it ships git, ssh, build
# tools etc. A plain base has none of that; list what we actually need.
#   git, openssh-client  Claude Code, and asdf plugin installs (git clone)
#   curl, ca-certificates, xz-utils, gpg  asdf-nodejs download + verification
#   ripgrep              Claude Code's search tool
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      gpg \
      jq \
      less \
      openssh-client \
      procps \
      ripgrep \
      xz-utils \
 && rm -rf /var/lib/apt/lists/*

# The node image provides this user; recreate it so paths match. The uid and gid
# are those of the NAS account phil (phil:users), which the ACLs on the bind mounts allow.
ARG NODE_UID=1031
ARG NODE_GID=100
RUN useradd --create-home --uid "${NODE_UID}" --gid "${NODE_GID}" --shell /bin/bash node \
 && install -d -o "${NODE_UID}" -g "${NODE_GID}" /home/node/work

COPY --from=uv   /uv /uvx            /usr/local/bin/
COPY --from=gh   /usr/local/bin/gh   /usr/local/bin/gh
COPY --from=asdf /usr/local/bin/asdf /usr/local/bin/asdf

# Outside /home/node, so a bind mount over the home directory cannot hide it.
COPY --from=claude-code /usr/local/lib/node_modules/@anthropic-ai/claude-code /opt/claude-code
RUN ln -s /opt/claude-code/bin/claude.exe /usr/local/bin/claude

USER node
WORKDIR /home/node/work

ENV PATH="/home/node/.asdf/shims:${PATH}"

# Runtimes are per project: put a .tool-versions in each project directory and
# run `asdf plugin add <name>` / `asdf install` there. Nothing is baked in.
# Keep the asdf data dir on a volume so installs survive container restarts.

CMD ["claude", "rc"]
