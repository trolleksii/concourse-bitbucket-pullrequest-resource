FROM alpine
ADD scripts/install_git_lfs.sh install_git_lfs.sh
RUN apk --update add \
  bash \
  ca-certificates \
  coreutils \
  curl \
  git \
  jq \
  openssh-client && \
  rm -rf /var/cache/apk && \
  ./install_git_lfs.sh
ADD assets/ /opt/resource/
