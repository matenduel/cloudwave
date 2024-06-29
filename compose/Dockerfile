# TODO Multi Stage?
# https://hub.docker.com/r/linuxserver/code-server
#FROM ubuntu:22.04
#FROM lscr.io/linuxserver/code-server:latest
FROM linuxserver/code-server:4.90.3

RUN apt-get update && apt-get -y upgrade

RUN apt install -y ca-certificates curl gnupg software-properties-common wget unzip apt-transport-https

# Docker CLI
RUN install -m 0755 -d /etc/apt/keyrings  \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg  \
    && chmod a+r /etc/apt/keyrings/docker.gpg

RUN echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg]  \
    https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable"  \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null

RUN apt-get update && apt-get install -y docker-ce docker-ce-cli

# Terraform
RUN wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor | tee /usr/share/keyrings/hashicorp-archive-keyring.gpg  \
    && gpg --no-default-keyring --keyring /usr/share/keyrings/hashicorp-archive-keyring.gpg --fingerprint  \
    && echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/hashicorp.list

RUN apt update && apt-get install -y terraform=1.6.6-1

# Install AWS CLI
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"  \
    && unzip awscliv2.zip  \
    && ./aws/install

# Kubectl
RUN curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg  \
    && echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' | tee /etc/apt/sources.list.d/kubernetes.list

RUN apt-get update && apt-get install -y kubectl

# Kubectx & Kubens
RUN git clone https://github.com/ahmetb/kubectx /opt/kubectx  \
    && ln -s /opt/kubectx/kubectx /usr/local/bin/kubectx  \
    && ln -s /opt/kubectx/kubens /usr/local/bin/kubens

# Install Code-server (VSCode)
ENV TZ="Asia/Seoul"
ENV PUID=1000
ENV PGID=1000
