# See here for image contents: https://github.com/microsoft/vscode-dev-containers/tree/v0.183.0/containers/rust/.devcontainer/base.Dockerfile

FROM mcr.microsoft.com/vscode/devcontainers/rust:0-1

# [Optional] Uncomment this section to install additional packages.
# RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
#     && apt-get -y install --no-install-recommends <your-package-list-here>

ENV SHELL /bin/zsh
RUN groupadd docker
RUN usermod -aG docker vscode

RUN export DEBIAN_FRONTEND=noninteractive && apt-get update && apt-get install -y --no-install-recommends software-properties-common apt-transport-https ca-certificates git-extras

RUN curl -fsSL https://download.docker.com/linux/$(lsb_release -is | tr '[:upper:]' '[:lower:]')/gpg | apt-key add - 2> /dev/null
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | apt-key add - 2> /dev/null

RUN export DEBIAN_FRONTEND=noninteractive && add-apt-repository "deb [arch=$(dpkg --print-architecture)] https://cli.github.com/packages stable main"
RUN export DEBIAN_FRONTEND=noninteractive && add-apt-repository "deb [arch=$(dpkg --print-architecture)] https://download.docker.com/linux/$(lsb_release -is | tr '[:upper:]' '[:lower:]') $(lsb_release -cs) stable"

RUN export DEBIAN_FRONTEND=noninteractive && apt-get update && apt-get install -y --no-install-recommends git-lfs ripgrep docker-ce-cli gh

ADD --chown=vscode:vscode .zshrc /home/vscode
ADD --chown=vscode:vscode .gitalias /home/vscode/.gitalias
ADD --chown=vscode:vscode .gitconfig /home/vscode/.gitconfig
ADD --chown=vscode:vscode .gitignore /home/vscode/.gitignore

RUN mkdir /commandhistory \
    && touch /commandhistory/.zsh_history \
    && chown -R vscode /commandhistory
